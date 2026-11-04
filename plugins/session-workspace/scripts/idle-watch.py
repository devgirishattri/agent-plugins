#!/usr/bin/env python3
"""Idle-stop watcher for one service pane (session-workspace).

lifecycle.sh starts one watcher right after it launches a pane whose config
sets ``idle_stop_minutes``. The watcher samples the pane's port and stops the
pane through ``workspace-stop.sh SESSION --pane NAME`` once nothing has used
it for the whole idle window.

Idle, per kind, for the whole window:
  browser  no CDP commands: no client sent the DevTools port more than
           keepalive traffic. chrome-devtools-mcp holds one websocket open
           for its whole session and pings on it (6 bytes about every 30 s),
           so an open connection alone is not use; its cheapest tool call
           sends about 150 bytes. It reconnects on its next call once the
           pane is started again.
  service  no inbound connection to the dev server's port at any sample (an
           open HMR or keep-alive connection is use). On Linux a server-side
           TIME_WAIT socket on the port also counts: the server closed that
           connection within the last 60 seconds, which is how a dev server
           that answers every request with "Connection: close" looks between
           samples.

A service pane can select its signals with ``--activity`` (the pane's
``idle_activity``): "connections" (the default, above), "output", or both.
"output" fingerprints what the pane has printed through tmux at each sample
(``#{history_size}`` plus a hash of the joined screen and the last
OUTPUT_TAIL_LINES lines of history); a change since the previous sample is
use, and the fingerprint taken when the watcher arms is the baseline. A sample
at which the pane's size changed (a resize, a sibling pane started or closed,
a client attaching at another size) only takes a new baseline: rewrapped text
is not output. Use is the OR of the selected signals, so a dev server that
logs each request stays up while it is used even when no connection is open
at any sample. Any periodic output keeps the pane up too, which is why
"output" is opt-in. The browser pane never selects it: Chrome writes to its
pane on its own.

Browser traffic is read per socket from the kernel (service-ports.py
``activity``: Linux sock_diag, macOS nettop). A sample counts as use when the
open connections together received more than KEEPALIVE_BYTES plus one byte
per second since the previous sample. Where per-socket traffic is not
available, the browser falls back to counting connections like a service.
A sample that cannot be taken at all (no socket table, no lsof) counts as
activity, so a host that cannot observe never stops a pane.

Ownership is one tmux pane option, ``@session_workspace_idle_watcher``, set to
the watcher's pid. A newer watcher for the same pane overwrites it and the
older one exits on its next sample, so a relaunch never leaves two watchers
and no lock is needed. The watcher also exits when its pane closes or stops
carrying the managed markers it was started for. It never runs inside the
pane (it is double-forked away from the caller and holds no inherited file
descriptor), so a stop that kills the pane cannot kill the watcher mid-step.

The record of what happened lives in ``<state-dir>/<pane>.json`` (written by
atomic rename): pane id, port, kind, window, last activity, client count, and
the selected signals, and once the pane is stopped, when and why.
``workspace-status`` reads it.

Tuning (environment, inherited from the start that armed the watcher):
  SESSION_WORKSPACE_IDLE_SAMPLE_SECONDS      seconds between samples (30)
  SESSION_WORKSPACE_IDLE_SECONDS_PER_MINUTE  length of one configured idle
                                             minute in seconds (60); tests
                                             shrink it to exercise the window
  SESSION_WORKSPACE_IDLE_OBSERVE             "connections" makes the browser
                                             count connections even where
                                             traffic is observable

Runs on the stock macOS python3 (3.9): stdlib only.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
WATCH_OPTION = '@session_workspace_idle_watcher'
MARKER_PROJECT = '@session_workspace_project'
MARKER_PANE = '@session_workspace_pane'
KEEPALIVE_BYTES = 32
SIGNALS = ('connections', 'output')  # canonical order, also of the reported mode
OUTPUT_TAIL_LINES = 50


def _ports_module():
    spec = importlib.util.spec_from_file_location('session_workspace_service_ports', str(HERE / 'service-ports.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def iso(ts):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(ts))


def positive_env(name, default):
    try:
        value = float(os.environ.get(name, ''))
    except ValueError:
        return default
    return value if value > 0 else default


def tmux(*args):
    try:
        run = subprocess.run(['tmux'] + list(args), capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return run.stdout.rstrip('\n') if run.returncode == 0 else None


def output_fingerprint(pane_id):
    """What pane PANE_ID shows right now, as (geometry, content): geometry is
    the pane's WIDTHxHEIGHT, content is tmux's history line count plus a hash
    of the joined visible screen and the last OUTPUT_TAIL_LINES lines of
    history. The count alone can repeat (tmux trims a full history in
    chunks); the hash alone misses output that scrolls identical text. A
    resize changes content without any output, which is why the caller
    compares content only at an unchanged geometry. None when tmux cannot read
    the pane. Bytes, not text: a pane may print anything."""
    shape = tmux('display-message', '-p', '-t', pane_id, '#{pane_width}x#{pane_height} #{history_size}')
    if shape is None or len(shape.split()) != 2:
        return None
    geometry, history = shape.split()
    try:
        run = subprocess.run(['tmux', 'capture-pane', '-p', '-J', '-t', pane_id, '-S', '-%d' % OUTPUT_TAIL_LINES],
                             capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    if run.returncode != 0:
        return None
    return geometry, '%s:%s' % (history, hashlib.sha256(run.stdout).hexdigest())


def pane_option(pane_id, option):
    value = tmux('show-options', '-p', '-t', pane_id, '-v', option)
    return value if value is not None else ''


def read_record(path):
    try:
        with open(path, encoding='utf-8') as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def write_record(path, record):
    tmp = '%s.%d.tmp' % (path, os.getpid())
    with open(tmp, 'w', encoding='utf-8') as handle:
        json.dump(record, handle, sort_keys=True)
        handle.write('\n')
    os.replace(tmp, path)


def idle_reason(kind, mode, signals, port, minutes):
    unit = 'minute' if minutes == 1 else 'minutes'
    if kind == 'browser' and mode == 'traffic':
        return 'idle: no CDP commands to 127.0.0.1:%d for %d %s' % (port, minutes, unit)
    if kind == 'browser':
        return 'idle: no CDP client connections to 127.0.0.1:%d for %d %s' % (port, minutes, unit)
    parts = []
    if 'connections' in signals:
        parts.append('no inbound connections to port %d' % port)
    if 'output' in signals:
        parts.append('no new pane output')
    return 'idle: %s for %d %s' % (' and '.join(parts), minutes, unit)


def observe(ports, port, use_traffic, previous, elapsed, count_closed):
    """One connections sample: (clients, mode, active, bytes_in|None, closed).
    mode is "traffic", "connections" or None (unobservable, which counts as
    active). closed is the number of server-side TIME_WAIT sockets on PORT
    (connections the server closed in the last 60 seconds) when COUNT_CLOSED
    and the host has a /proc socket table, else None; any counts as use."""
    seen = ports.activity(port) if use_traffic else None
    if seen is None or seen['mode'] != 'traffic':
        count = seen['clients'] if seen else ports.established_clients(port)
        if count is None:
            return None, None, True, None, None
        closed = ports.time_wait_clients(port) if count_closed else None
        return count, 'connections', count > 0 or bool(closed), None, closed
    received = seen['bytes_in']
    # A connection opened since the last sample counts from zero; one that
    # closed contributes nothing (its bytes were seen while it was open).
    moved = sum(max(count - previous.get(name, 0), 0) for name, count in received.items())
    return seen['clients'], 'traffic', moved > KEEPALIVE_BYTES + int(elapsed), received, None


def watch(args, ready_fd=None):
    own = str(os.getpid())
    state_path = os.path.join(args.state_dir, args.pane + '.json')
    scale = positive_env('SESSION_WORKSPACE_IDLE_SECONDS_PER_MINUTE', 60.0)
    window = args.minutes * scale
    sample = min(positive_env('SESSION_WORKSPACE_IDLE_SAMPLE_SECONDS', 30.0), window)
    use_traffic = args.kind == 'browser' and os.environ.get('SESSION_WORKSPACE_IDLE_OBSERVE', '') != 'connections'
    signals = args.activity
    watch_connections = 'connections' in signals
    watch_output = 'output' in signals
    ports = _ports_module()

    os.makedirs(args.state_dir, mode=0o700, exist_ok=True)
    previous = read_record(state_path)
    started = time.time()
    record = {
        'pane': args.pane,
        'session': args.session,
        'pane_id': args.pane_id,
        'kind': args.kind,
        'port': args.port,
        'idle_stop_minutes': args.minutes,
        'idle_window_seconds': window,
        'sample_seconds': sample,
        'watcher_pid': int(own),
        'state': 'watching',
        'started_at': iso(started),
        'last_active_at': iso(started),
        'last_active_epoch': int(started),
        'last_sample_at': None,
        'clients': None,
        'observing': None,
    }
    if args.kind == 'service':
        record['idle_activity'] = list(signals)
    if previous.get('stopped_at'):
        record['last_stop'] = {'at': previous['stopped_at'], 'reason': previous.get('stop_reason', '')}
    elif previous.get('last_stop'):
        record['last_stop'] = previous['last_stop']

    if tmux('set-option', '-p', '-t', args.pane_id, WATCH_OPTION, own) is None:
        record.update(state='not-armed', stop_reason='could not register the watcher on pane %s' % args.pane_id)
        write_record(state_path, record)
        return 1
    # The arm-time fingerprint is the baseline: only output printed after the
    # watcher armed counts as use.
    fingerprint = output_fingerprint(args.pane_id) if watch_output else None
    write_record(state_path, record)
    if ready_fd is not None:
        os.write(ready_fd, own.encode('ascii'))
        os.close(ready_fd)

    last_active = started
    last_sample = started
    received = {}
    mode = None
    while True:
        time.sleep(sample)
        dead = tmux('display-message', '-p', '-t', args.pane_id, '#{pane_dead}')
        if dead is None or dead == '1':
            latest = read_record(state_path)
            if latest.get('watcher_pid') == int(own) and latest.get('state') != 'stopped':
                latest.update(state='exited', stop_reason='pane closed by something other than its idle watcher (for example a whole-session stop)', stopped_at=iso(time.time()))
                write_record(state_path, latest)
            return 0
        if pane_option(args.pane_id, WATCH_OPTION) != own:
            return 0  # superseded by a newer watcher, which owns the record now
        if pane_option(args.pane_id, MARKER_PANE) != args.pane or pane_option(args.pane_id, MARKER_PROJECT) != args.project:
            return 0  # the pane id no longer carries the pane this watcher was armed for

        now = time.time()
        clients, conn_mode, active, seen_bytes, closed = None, None, False, None, None
        notes = []
        if watch_connections:
            clients, conn_mode, active, seen_bytes, closed = observe(
                ports, args.port, use_traffic, received, now - last_sample, args.kind == 'service')
            if conn_mode is None:
                notes.append('unavailable: no socket table and no lsof; the pane is never stopped for idleness')
            elif conn_mode == 'connections' and use_traffic:
                notes.append('connections only: CDP traffic is not observable here, so an open chrome-devtools connection keeps the pane up')
        out_mode = None
        if watch_output:
            current = output_fingerprint(args.pane_id)
            if current is None:
                # An unreadable pane counts as use, like an unobservable port.
                active = True
                notes.append('pane output unavailable: tmux could not read the pane, so it is not stopped for idleness while this lasts')
            else:
                out_mode = 'output'
                # A changed size only takes a new baseline: rewrapped or
                # reflowed text is not output.
                if fingerprint is None or (current[0] == fingerprint[0] and current[1] != fingerprint[1]):
                    active = True
            fingerprint = current
        seen_mode = '+'.join(m for m in (conn_mode, out_mode) if m) or None
        last_sample = now
        received = seen_bytes if seen_bytes is not None else {}
        if active:
            last_active = now
        if conn_mode is not None:
            mode = conn_mode
        record.update(clients=clients, observing=seen_mode, last_sample_at=iso(now),
                      last_active_at=iso(last_active), last_active_epoch=int(last_active))
        if closed is not None:
            record['recently_closed'] = closed
        else:
            record.pop('recently_closed', None)
        if notes:
            record['observation'] = '; '.join(notes)
        else:
            record.pop('observation', None)

        if now - last_active < window:
            write_record(state_path, record)
            continue

        reason = idle_reason(args.kind, mode, signals, args.port, args.minutes)
        record.update(state='stopping', stop_reason=reason)
        write_record(state_path, record)
        env = dict(os.environ, SESSION_WORKSPACE_STOP_REASON=reason)
        try:
            run = subprocess.run(
                ['bash', str(HERE / 'workspace-stop.sh'), args.session, '--pane', args.pane,
                 '--confirmed', '--config', args.config, '--expect-pane-id', args.pane_id],
                capture_output=True, text=True, env=env, timeout=300)
            rc, detail = run.returncode, (run.stderr or run.stdout).strip()
        except (OSError, subprocess.SubprocessError) as exc:
            rc, detail = 1, str(exc)
        if rc == 0:
            return 0  # workspace-stop.sh recorded stopped_at and the reason
        latest = read_record(state_path) or record
        latest.update(state='watching', stop_error=(detail.splitlines() or ['workspace-stop failed'])[-1])
        record = latest
        write_record(state_path, record)


def spawn(args):
    """Detach a watcher and print its pid once it has registered itself."""
    read_fd, write_fd = os.pipe()
    child = os.fork()
    if child > 0:
        os.close(write_fd)
        os.waitpid(child, 0)  # the intermediate exits right after its own fork
        chunks = []
        deadline = time.time() + 10
        os.set_blocking(read_fd, False)
        while time.time() < deadline:
            try:
                chunk = os.read(read_fd, 64)
            except BlockingIOError:
                time.sleep(0.05)
                continue
            if not chunk:
                break
            chunks.append(chunk)
        os.close(read_fd)
        pid = b''.join(chunks).decode('ascii', 'replace').strip()
        if not pid.isdigit():
            print('ERROR: idle watcher for %s did not start' % args.pane, file=sys.stderr)
            return 1
        print(pid)
        return 0
    os.close(read_fd)
    os.setsid()
    if os.fork() > 0:
        os._exit(0)
    os.chdir('/')
    os.umask(0o077)
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    for fd in range(3, 256):
        if fd != write_fd:
            try:
                os.close(fd)
            except OSError:
                pass
    try:
        code = watch(args, ready_fd=write_fd)
    except Exception:  # never let a watcher traceback reach anyone's terminal
        code = 1
    os._exit(code)


def main(argv):
    parser = argparse.ArgumentParser(description='session-workspace idle-stop watcher')
    parser.add_argument('mode', choices=['spawn', 'watch'])
    parser.add_argument('--config', required=True)
    parser.add_argument('--project', required=True)
    parser.add_argument('--session', required=True)
    parser.add_argument('--pane', required=True)
    parser.add_argument('--pane-id', required=True)
    parser.add_argument('--port', required=True, type=int)
    parser.add_argument('--kind', required=True, choices=['browser', 'service'])
    parser.add_argument('--minutes', required=True, type=int)
    parser.add_argument('--state-dir', required=True)
    parser.add_argument('--activity', default='connections',
                        help='comma-separated signals that count as use: connections, output (default: connections)')
    args = parser.parse_args(argv)
    if not 0 < args.port < 65536 or args.minutes < 1 or not args.pane_id.startswith('%'):
        parser.error('invalid port, minutes, or pane id')
    chosen = args.activity.split(',')
    if not chosen or any(s not in SIGNALS for s in chosen) or len(set(chosen)) != len(chosen):
        parser.error('--activity takes unique values from: %s' % ', '.join(SIGNALS))
    if args.kind == 'browser' and chosen != ['connections']:
        parser.error('the browser pane is watched for CDP use only (--activity connections)')
    args.activity = tuple(s for s in SIGNALS if s in chosen)
    if args.mode == 'spawn':
        return spawn(args)
    return watch(args)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
