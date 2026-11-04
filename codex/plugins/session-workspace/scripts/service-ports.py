#!/usr/bin/env python3
"""Bounded loopback port observations for service panes.

Subcommands (stdlib only, runs on the stock macOS python3 3.9):

  probe PORT            print listening | not-listening (loopback connect)
  clients PORT          print the number of ESTABLISHED inbound TCP
                        connections whose LOCAL port is PORT, or "unknown"
                        when this host offers no way to count them
  activity PORT         print what the idle watcher sees on PORT as JSON:
                        {"mode": "traffic", "clients": N, "bytes_in": {...}},
                        {"mode": "connections", "clients": N}, or null when
                        nothing can be observed
  holders PORT          print one "PID<TAB>COMMAND" line per process holding
                        a LISTEN socket on PORT (best effort; may be empty)
  TARGET [PANE...]      preflight, reading a workspace plan on stdin: refuse
                        (exit 1) when a selected service pane's port is
                        already bound by something other than that pane's own
                        live managed launch, and name the holding PID

Observations are never proof of ownership. A managed, live, launched pane is
kept by the idempotent lifecycle, so the preflight skips it; anything else
answering on the port is a conflict that would make the pane's command fail
(EADDRINUSE) or, worse, silently move to another port.

Connection counting reads /proc/net/tcp{,6} on Linux and falls back to lsof
(always present on macOS). On Linux the same table also shows server-side
TIME_WAIT sockets (connections the server closed in the last 60 seconds),
which the idle watcher counts as recent use; lsof never lists TIME_WAIT. Holder lookup tries lsof first and then the Linux
/proc socket table. Only processes this user may inspect can be named.

Client traffic (the bytes each inbound connection has RECEIVED from its
client) is read from the kernel's per-socket TCP info: on Linux through a
NETLINK_SOCK_DIAG dump (the source of `ss -ti`, no tool needed), on macOS from
`nettop`. Where neither answers, activity falls back to the connection count.
"""
import json
import os
import shutil
import socket
import struct
import subprocess
import sys

LISTEN_STATE = '0A'
ESTABLISHED_STATE = '01'
TIME_WAIT_STATE = '06'


def listening(port):
    for family, host in ((socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')):
        try:
            with socket.socket(family, socket.SOCK_STREAM) as sock:
                sock.settimeout(.25)
                sock.connect((host, port))
                return True
        except OSError:
            continue
    return False


def _proc_rows(state):
    """(local_port, inode) for every /proc/net/tcp{,6} row in STATE, or None
    when the table is unavailable (not Linux)."""
    found = False
    rows = []
    for path in ('/proc/net/tcp', '/proc/net/tcp6'):
        try:
            with open(path, encoding='ascii') as handle:
                lines = handle.read().splitlines()[1:]
        except OSError:
            continue
        found = True
        for line in lines:
            parts = line.split()
            if len(parts) < 10 or parts[3] != state:
                continue
            try:
                rows.append((int(parts[1].rsplit(':', 1)[1], 16), parts[9]))
            except (IndexError, ValueError):
                continue
    return rows if found else None


def _lsof():
    return shutil.which('lsof') or ('/usr/sbin/lsof' if os.path.exists('/usr/sbin/lsof') else None)


def _run(argv):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return None


def established_clients(port):
    """Count accepted (server-side) ESTABLISHED sockets on PORT, or None."""
    rows = _proc_rows(ESTABLISHED_STATE)
    if rows is not None:
        return sum(1 for local, _ in rows if local == port)
    lsof = _lsof()
    if not lsof:
        return None
    out = _run([lsof, '-nP', '-iTCP:%d' % port, '-sTCP:ESTABLISHED', '-Fn'])
    if out is None:
        return None
    count = 0
    for line in out.splitlines():
        # n127.0.0.1:9326->127.0.0.1:53422 : the LOCAL side is left of "->".
        if line.startswith('n') and '->' in line:
            if line[1:].split('->', 1)[0].rsplit(':', 1)[-1] == str(port):
                count += 1
    return count


def time_wait_clients(port):
    """Count server-side TIME_WAIT sockets on PORT: connections whose LOCAL port
    is PORT and that this side closed first, which Linux keeps for 60 seconds.
    A dev server that answers every request with "Connection: close" leaves
    one per request. None without a /proc socket table (macOS)."""
    rows = _proc_rows(TIME_WAIT_STATE)
    if rows is None:
        return None
    return sum(1 for local, _ in rows if local == port)


# Linux NETLINK_SOCK_DIAG (linux/sock_diag.h, linux/inet_diag.h).
_NETLINK_SOCK_DIAG = 4
_SOCK_DIAG_BY_FAMILY = 20
_NLM_F_REQUEST, _NLM_F_DUMP = 0x1, 0x300
_NLMSG_ERROR, _NLMSG_DONE = 2, 3
_INET_DIAG_INFO = 2
_TCP_ESTABLISHED = 1
_TCPI_BYTES_RECEIVED = 128  # offset of tcpi_bytes_received (u64) in struct tcp_info, Linux 4.1+


def _sock_diag_bytes_in(port):
    """{socket inode: bytes received} for each ESTABLISHED TCP socket whose
    LOCAL port is PORT, or None when sock_diag or the counter is unavailable."""
    if not hasattr(socket, 'AF_NETLINK'):
        return None
    found = {}
    try:
        for family in (socket.AF_INET, socket.AF_INET6):
            # inet_diag_req_v2 + an all-wildcard inet_diag_sockid (filtered below).
            req = struct.pack('=BBBBI', family, socket.IPPROTO_TCP, 1 << (_INET_DIAG_INFO - 1), 0,
                              1 << _TCP_ESTABLISHED) + bytes(48)
            msg = struct.pack('=IHHII', 16 + len(req), _SOCK_DIAG_BY_FAMILY, _NLM_F_REQUEST | _NLM_F_DUMP, 1, 0) + req
            with socket.socket(socket.AF_NETLINK, socket.SOCK_DGRAM, _NETLINK_SOCK_DIAG) as sock:
                sock.settimeout(5)
                sock.sendto(msg, (0, 0))
                done = False
                while not done:
                    data = sock.recv(1 << 16)
                    if not data:
                        break
                    offset = 0
                    while offset + 16 <= len(data):
                        length, kind = struct.unpack_from('=IH', data, offset)
                        if length < 16 or kind == _NLMSG_DONE:
                            done = True
                            break
                        if kind == _NLMSG_ERROR:
                            return None
                        body = data[offset + 16:offset + length]
                        offset += (length + 3) & ~3
                        # inet_diag_msg is 72 bytes: family, state, timer,
                        # retrans, the socket id (sport/dport big-endian at 4),
                        # then expires, rqueue, wqueue, uid, inode (at 68).
                        if len(body) < 72 or body[1] != _TCP_ESTABLISHED:
                            continue
                        if struct.unpack_from('>H', body, 4)[0] != port:
                            continue
                        attrs, received = body[72:], None
                        cursor = 0
                        while cursor + 4 <= len(attrs):
                            alen, atype = struct.unpack_from('=HH', attrs, cursor)
                            if alen < 4:
                                break
                            if atype == _INET_DIAG_INFO and alen - 4 >= _TCPI_BYTES_RECEIVED + 8:
                                received = struct.unpack_from('=Q', attrs, cursor + 4 + _TCPI_BYTES_RECEIVED)[0]
                            cursor += (alen + 3) & ~3
                        if received is None:
                            return None  # kernel without the counter: traffic is not observable
                        found['inode:%d' % struct.unpack_from('=I', body, 68)[0]] = received
    except (OSError, struct.error):
        return None
    return found


def _nettop_bytes_in(port):
    """{connection: bytes received} for each TCP connection whose LOCAL port is
    PORT, from macOS nettop; None when nettop is missing or its output has no
    per-connection byte column."""
    nettop = shutil.which('nettop') or ('/usr/bin/nettop' if os.path.exists('/usr/bin/nettop') else None)
    if not nettop:
        return None
    out = _run([nettop, '-m', 'tcp', '-L', '1', '-n', '-x', '-J', 'bytes_in'])
    return parse_nettop(out, port) if out else None


def parse_nettop(text, port):
    """Parse `nettop -L 1 -J bytes_in` CSV. Connection rows name the endpoints
    as "tcp4 127.0.0.1:9326<->127.0.0.1:53422" (IPv6 may use "." before the
    port); process rows carry no "<->" and are skipped."""
    column = None
    rows = {}
    for line in text.splitlines():
        fields = [field.strip() for field in line.split(',')]
        if column is None:
            if 'bytes_in' in fields:
                column = fields.index('bytes_in')
            continue
        name = next((field for field in fields if '<->' in field), None)
        if name is None or len(fields) <= column:
            continue
        local = name.split('<->', 1)[0].split()[-1]
        digits = ''
        for char in reversed(local):
            if not char.isdigit():
                break
            digits = char + digits
        if digits != str(port) or not fields[column].isdigit():
            continue
        rows[name] = int(fields[column])
    return rows if column is not None else None


def activity(port):
    """What the idle watcher can see of PORT's clients right now:
      {"mode": "traffic", "clients": N, "bytes_in": {conn: bytes}}
          cumulative bytes each inbound connection has received (Linux
          sock_diag, keyed by socket inode; macOS nettop, keyed by endpoints)
      {"mode": "connections", "clients": N}
          only the connection count is observable
    or None when not even connections can be counted."""
    received = _sock_diag_bytes_in(port)
    if received is not None:
        return {'mode': 'traffic', 'clients': len(received), 'bytes_in': received}
    received = _nettop_bytes_in(port)
    clients = established_clients(port)
    if received is not None and (clients is None or len(received) >= clients):
        return {'mode': 'traffic', 'clients': len(received), 'bytes_in': received}
    if clients is None:
        return None
    return {'mode': 'connections', 'clients': clients}


def _comm(pid):
    try:
        with open('/proc/%s/comm' % pid, encoding='utf-8', errors='replace') as handle:
            return handle.read().strip()
    except OSError:
        out = _run(['ps', '-o', 'comm=', '-p', str(pid)])
        return os.path.basename(out.strip()) if out else ''


def holders(port):
    """[(pid, command)] holding a LISTEN socket on PORT (best effort)."""
    found = {}
    lsof = _lsof()
    if lsof:
        out = _run([lsof, '-nP', '-iTCP:%d' % port, '-sTCP:LISTEN', '-Fpc']) or ''
        pid = None
        for line in out.splitlines():
            if line.startswith('p'):
                pid = line[1:]
            elif line.startswith('c') and pid:
                found[pid] = line[1:]
    if not found:
        rows = _proc_rows(LISTEN_STATE) or []
        inodes = {inode for local, inode in rows if local == port and inode != '0'}
        if inodes:
            for pid in (p for p in os.listdir('/proc') if p.isdigit()):
                try:
                    fds = os.listdir('/proc/%s/fd' % pid)
                except OSError:
                    continue
                for fd in fds:
                    try:
                        link = os.readlink('/proc/%s/fd/%s' % (pid, fd))
                    except OSError:
                        continue
                    if link.startswith('socket:[') and link[8:-1] in inodes:
                        found[pid] = _comm(pid)
                        break
    return sorted(((int(pid), comm) for pid, comm in found.items()), key=lambda item: item[0])


def bound(port):
    return listening(port) or bool(holders(port))


def describe_holders(port):
    held = holders(port)
    if not held:
        return 'a process this user cannot inspect (try: lsof -nP -iTCP:%d -sTCP:LISTEN)' % port
    return ', '.join('pid %d (%s)' % (pid, comm or 'unknown') for pid, comm in held)


def preflight(plan, target, selected=()):
    for session in plan['sessions']:
        if target not in ('all', session['id']):
            continue
        for pane in session['panes']:
            if selected and pane['name'] not in selected:
                continue
            if pane['browser'] or not pane['port'] or not pane['command'] or pane['skip_unresolved']:
                continue
            if not bound(pane['port']):
                continue
            # A managed live pane is kept by the idempotent lifecycle. This is
            # only a conflict preflight, not proof it owns the listening socket.
            proc = subprocess.run(['tmux', 'list-panes', '-t', '=' + session['name'], '-F', '#{@session_workspace_project}\t#{@session_workspace_pane}\t#{pane_dead}\t#{@session_workspace_launched}'], capture_output=True, text=True)
            expected = [plan['project']['id'], pane['name'], '0', pane['runtime']['name']]
            if not any(line.split('\t') == expected for line in proc.stdout.splitlines()):
                print('ERROR: service port occupied before launch: %d (%s) is held by %s; nothing was started for it.'
                      % (pane['port'], pane['name'], describe_holders(pane['port'])), file=sys.stderr)
                print('       Stop that process or free the port, then start the pane again.', file=sys.stderr)
                return 1
    return 0


def main(argv):
    if len(argv) < 2:
        print('usage: service-ports.py probe|clients|activity|holders PORT | TARGET [PANE...]', file=sys.stderr)
        return 2
    if argv[1] in ('probe', 'clients', 'activity', 'holders'):
        if len(argv) != 3 or not argv[2].isdigit() or not 0 < int(argv[2]) < 65536:
            print('ERROR: %s requires one TCP port' % argv[1], file=sys.stderr)
            return 2
        port = int(argv[2])
        if argv[1] == 'probe':
            print('listening' if listening(port) else 'not-listening')
        elif argv[1] == 'clients':
            count = established_clients(port)
            print('unknown' if count is None else count)
        elif argv[1] == 'activity':
            print(json.dumps(activity(port), sort_keys=True))
        else:
            for pid, comm in holders(port):
                print('%d\t%s' % (pid, comm))
        return 0
    return preflight(json.load(sys.stdin), argv[1], set(argv[2:]))


if __name__ == '__main__':
    sys.exit(main(sys.argv))
