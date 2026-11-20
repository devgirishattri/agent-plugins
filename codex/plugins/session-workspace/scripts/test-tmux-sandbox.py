#!/usr/bin/env python3
"""Regression: test tmux isolation never reaches the user's server or files.

tmux uses /tmp/tmux-UID/default when TMUX_TMPDIR names a missing directory.
These tests stand a sentinel server, on its own -S socket, in for that real
server: a stand-in `tmux` on PATH sends any call that would fall back to the
default to the sentinel instead. The real default socket is never addressed.

A stop also runs the tmux-resurrect save found under $HOME. Every process here
gets a decoy HOME, and one test proves a sandboxed stop saves into the
sandbox's HOME, never the caller's.
"""
import atexit
import importlib.util
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest
import unittest.mock

HERE = Path(os.environ.get('WORKSPACE_TEST_SCRIPTS', Path(__file__).resolve().parent))
FIXTURE = Path(__file__).resolve().parent / 'fixtures/valid/project-d.json'
spec = importlib.util.spec_from_file_location('tmux_sandbox', HERE / 'tmux_sandbox.py')
tmux_sandbox = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tmux_sandbox)
# Nothing in this file runs with the user's HOME: tmux would load the user's
# config and plugins, and a stop would run the user's tmux-resurrect save.
DECOY_HOME = Path(tempfile.mkdtemp(prefix='swhome-', dir='/tmp')).resolve()
atexit.register(shutil.rmtree, str(DECOY_HOME), True)
BASE = {k: v for k, v in os.environ.items()
        if not k.startswith(('SESSION_', 'KNOWLEDGE_', 'XDG_')) and k not in ('TMUX', 'TMUX_PANE', 'TMUX_TMPDIR')}
BASE.update(HOME=str(DECOY_HOME), XDG_CONFIG_HOME=str(DECOY_HOME / '.config'),
            XDG_DATA_HOME=str(DECOY_HOME / '.local/share'), XDG_CACHE_HOME=str(DECOY_HOME / '.cache'))
# A `tmux` first on BASE's PATH that refuses and records every call, so a
# process that loses a sandbox's wrapper fails here instead of reaching a real
# server. The tests' own calls use the tmux binary by absolute path.
REJECT_LOG = DECOY_HOME / 'rejected.log'
(DECOY_HOME / 'reject-bin').mkdir()
(DECOY_HOME / 'reject-bin/tmux').write_text('#!/bin/sh\necho "$*" >> %s\nexit 98\n' % shlex.quote(str(REJECT_LOG)))
(DECOY_HOME / 'reject-bin/tmux').chmod(0o700)
BASE['PATH'] = str(DECOY_HOME / 'reject-bin') + os.pathsep + BASE.get('PATH', '')
SAVE_HOOK = '.tmux/plugins/tmux-resurrect/scripts/save.sh'


def recording_save_hook(home):
    """A stand-in tmux-resurrect save under HOME that records each run."""
    hook = Path(home) / SAVE_HOOK
    hook.parent.mkdir(parents=True, exist_ok=True)
    hook.write_text('#!/bin/sh\necho "$HOME" >> %s\n' % shlex.quote(str(Path(home) / 'saved')))
    hook.chmod(0o700)
    return Path(home) / 'saved'


@unittest.skipUnless(tmux_sandbox.real_tmux(), 'tmux required')
class FallbackSentinel(unittest.TestCase):
    def setUp(self):
        self.real = tmux_sandbox.real_tmux()
        # The sentinel's own short directory, with the fixed prefix.
        self.box = tmux_sandbox.Sandbox()
        self.sentinel = self.box.root / 'sentinel'
        self.missing = self.box.root / 'removed-tmux-tmpdir'
        self.other = self.box.root / 'other'
        # Emulate tmux's fallback without touching the real default socket:
        # a missing TMUX_TMPDIR goes to the sentinel ("the default server").
        self.emu = self.box.root / 'emu'
        self.emu.mkdir()
        (self.emu / 'tmux').write_text(
            '#!/bin/sh\nif [ -n "$TMUX_TMPDIR" ] && [ ! -d "$TMUX_TMPDIR" ]; then sock=%s; else sock=%s; fi\n'
            'exec %s -f /dev/null -S "$sock" "$@"\n' % (shlex.quote(str(self.sentinel)), shlex.quote(str(self.other)), shlex.quote(self.real)))
        (self.emu / 'tmux').chmod(0o700)
        # A strict double for a Sandbox's own tmux binary: it passes through
        # only calls pinned (-f /dev/null -S) to a socket in a swtmux- directory
        # and refuses and records anything else, so a broken pin fails the test
        # instead of reaching a real server.
        self.strict_log = self.box.root / 'unpinned.log'
        self.strict = self.box.root / 'strict-tmux'
        self.strict.write_text(
            '#!/bin/sh\nif [ "$1" = -f ] && [ "$2" = /dev/null ] && [ "$3" = -S ]; then\n'
            '  case "$4" in %s/%s*/sock) exec %s "$@" ;; esac\nfi\n'
            'echo "$*" >> %s\nexit 97\n' % (shlex.quote(str(tmux_sandbox.SOCKET_ROOT)), tmux_sandbox.PREFIX,
                                            shlex.quote(self.real), shlex.quote(str(self.strict_log))))
        self.strict.chmod(0o700)
        self.start_sentinel()
        self.state = Path(tempfile.mkdtemp(prefix='swst-', dir='/tmp'))

    def tearDown(self):
        rejected = REJECT_LOG.read_text() if REJECT_LOG.exists() else ''
        if REJECT_LOG.exists():
            REJECT_LOG.unlink()
        for sock in (self.sentinel, self.other):
            if self.box.owns(sock):
                self.sent('kill-server', sock=sock)
        self.box.teardown()
        shutil.rmtree(str(self.state), ignore_errors=True)
        self.assertEqual(rejected, '', 'a tmux call lost its sandbox wrapper')

    def sent(self, *args, sock=None):
        """The test's own call to the sentinel (or another of its sockets)."""
        return subprocess.run([self.real, '-f', '/dev/null', '-S', str(sock or self.sentinel), *args],
                              capture_output=True, text=True, env=BASE)

    def start_sentinel(self):
        self.assertEqual(self.sent('new-session', '-d', '-s', 'project-d-development', 'sleep 600').returncode, 0)
        # Marked as this project's session, so a stop that reached it would kill it.
        self.assertEqual(self.sent('set-option', '-t', 'project-d-development', '@session_workspace_project', 'project-d').returncode, 0)

    def sentinel_alive(self):
        return self.sent('has-session', '-t', '=project-d-development').returncode == 0

    def unpinned_calls(self):
        return self.strict_log.read_text() if self.strict_log.exists() else ''

    def emu_env(self, **extra):
        return dict(BASE, PATH=str(self.emu) + os.pathsep + BASE['PATH'], TMUX_TMPDIR=str(self.missing),
                    XDG_STATE_HOME=str(self.state), SESSION_WORKSPACE_STOP_GRACE_SECONDS='0', **extra)

    def test_control_a_bare_kill_server_reaches_the_fallback(self):
        # The pattern this regression replaces: TMUX_TMPDIR alone, bare kill-server.
        self.assertTrue(self.sentinel_alive())
        subprocess.run(['tmux', 'kill-server'], env=self.emu_env(), capture_output=True)
        self.assertFalse(self.sentinel_alive())

    def test_control_a_call_without_the_wrapper_is_rejected(self):
        # Losing the sandbox's PATH prefix leaves BASE's rejecting tmux in front.
        r = subprocess.run(['tmux', 'new-session', '-d', '-s', 'lost', 'sleep 600'], env=BASE, capture_output=True)
        self.assertEqual(r.returncode, 98)
        self.assertIn('new-session', REJECT_LOG.read_text())
        REJECT_LOG.unlink()
        self.assertTrue(self.sentinel_alive())

    def test_control_the_strict_double_refuses_an_unpinned_call(self):
        r = subprocess.run([str(self.strict), 'kill-server'], capture_output=True, env=BASE)
        self.assertEqual(r.returncode, 97)
        self.assertIn('kill-server', self.unpinned_calls())
        self.assertTrue(self.sentinel_alive())

    def test_sandbox_teardown_after_its_directory_is_gone(self):
        box = tmux_sandbox.Sandbox(tmux_binary=str(self.strict))
        r = box.tmux('new-session', '-d', '-s', 'inner', 'sleep 600')
        self.assertEqual(r.returncode, 0, r.stderr)
        socket = box.socket
        self.assertTrue(box.kill_server())
        self.assertFalse(box.running())
        shutil.rmtree(str(box.root))
        env = self.emu_env()
        with unittest.mock.patch.dict(os.environ, env, clear=True):
            box.teardown()
            self.assertFalse(box.kill_server())
        self.assertTrue(self.sentinel_alive())
        self.assertFalse(socket.exists())
        self.assertEqual(self.unpinned_calls(), '')

    def test_sandbox_refuses_a_socket_outside_its_directory(self):
        self.assertFalse(self.box.owns(self.sentinel.parent.parent / 'not-ours'))
        self.assertFalse(self.box.owns('/tmp/tmux-%d/default' % os.getuid()))
        self.assertTrue(self.box.owns(self.sentinel))

    def test_teardown_keeps_a_sandbox_whose_socket_it_refuses(self):
        box = tmux_sandbox.Sandbox(tmux_binary=str(self.strict))
        box.socket.symlink_to(self.sentinel)  # not a socket of its own
        with self.assertRaises(RuntimeError):
            box.teardown()
        self.assertTrue(box.root.exists())
        self.assertTrue(self.sentinel_alive())
        box.socket.unlink()
        box.teardown()
        self.assertFalse(box.root.exists())

    def test_wrapper_pins_the_socket_even_with_a_missing_tmux_tmpdir(self):
        box = tmux_sandbox.Sandbox(tmux_binary=str(self.strict))
        try:
            env = box.env(BASE)
            env['TMUX_TMPDIR'] = str(self.missing)  # gone, as after an early cleanup
            r = subprocess.run(['tmux', 'new-session', '-d', '-s', 'pinned', 'sleep 600'], env=env, capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(box.tmux('has-session', '-t', '=pinned').returncode, 0)
            self.assertTrue(self.sentinel_alive())
            self.assertEqual(self.unpinned_calls(), '')
        finally:
            box.teardown()

    def test_engine_refuses_a_missing_tmux_tmpdir(self):
        cfg = ['--config', str(FIXTURE)]
        for argv in [('workspace-stop.sh', 'all', '--confirmed'), ('workspace-stop.sh', 'development', '--pane', 'x', '--confirmed'),
                     ('workspace-restart.sh', 'development'), ('workspace-reconcile.sh', 'development', '--apply'),
                     ('workspace-start.sh', 'development', '--no-attach'), ('workspace-show.sh', 'x'), ('workspace-hide.sh', 'x')]:
            r = subprocess.run(['bash', str(HERE / argv[0]), *argv[1:], *cfg], env=self.emu_env(), capture_output=True, text=True, timeout=120)
            self.assertNotEqual(r.returncode, 0, (argv, r.stdout, r.stderr))
            self.assertIn('TMUX_TMPDIR', r.stderr, argv)
            self.assertTrue(self.sentinel_alive(), argv)
        # Control: the same stop with a usable TMUX_TMPDIR that the stand-in routes
        # to the sentinel kills it, so the refusal above is what kept it alive.
        reach = self.box.root / 'reach'
        reach.mkdir()
        (reach / 'tmux').write_text('#!/bin/sh\nexec %s -f /dev/null -S %s "$@"\n' % (shlex.quote(self.real), shlex.quote(str(self.sentinel))))
        (reach / 'tmux').chmod(0o700)
        env = dict(self.emu_env(), PATH=str(reach) + os.pathsep + BASE['PATH'], TMUX_TMPDIR=str(self.box.tmpdir),
                   SESSION_WORKSPACE_TMUX_SOCKET=str(self.sentinel))
        r = subprocess.run(['bash', str(HERE / 'workspace-stop.sh'), 'development', '--confirmed', *cfg], env=env,
                           capture_output=True, text=True, timeout=120)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse(self.sentinel_alive())

    def test_a_sandboxed_stop_saves_into_the_sandbox_home_only(self):
        # The caller's HOME (standing in for the user's) has a tmux-resurrect
        # save that records each run; so does the sandbox's decoy HOME.
        caller_home = self.box.root / 'caller-home'
        caller_saved = recording_save_hook(caller_home)
        box = tmux_sandbox.Sandbox(agent_stubs=True, tmux_binary=str(self.strict))
        try:
            box_saved = recording_save_hook(box.home)
            self.assertEqual(box.tmux('new-session', '-d', '-s', 'project-d-development', 'sleep 600').returncode, 0)
            box.tmux('set-option', '-t', 'project-d-development', '@session_workspace_project', 'project-d')
            env = box.env(dict(BASE, HOME=str(caller_home), XDG_STATE_HOME=str(self.state), SESSION_WORKSPACE_STOP_GRACE_SECONDS='0'))
            r = subprocess.run(['bash', str(HERE / 'workspace-stop.sh'), 'development', '--confirmed', '--config', str(FIXTURE)],
                               env=env, capture_output=True, text=True, timeout=120)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertNotEqual(box.tmux('has-session', '-t', '=project-d-development').returncode, 0)
            # Control: the stop did save (save_before_stop is on in the fixture) ...
            self.assertTrue(box_saved.exists(), r.stdout + r.stderr)
            # ... and only into the sandbox's HOME.
            self.assertFalse(caller_saved.exists())
            self.assertEqual(self.unpinned_calls(), '')
        finally:
            box.teardown()

    def test_teardown_keeps_a_sandbox_when_tmux_cannot_confirm_the_stop(self):
        # A tmux that answers with an unrelated error proves nothing: the
        # directory (and the route to the server) must stay.
        box = tmux_sandbox.Sandbox(tmux_binary=str(self.strict))
        self.assertEqual(box.tmux('new-session', '-d', '-s', 'kept', 'sleep 600').returncode, 0)
        flaky = box.root / 'flaky-tmux'
        flaky.write_text('#!/bin/sh\nfor a; do [ "$a" = list-sessions ] && { echo "lost server" >&2; exit 97; }; done\nexec %s "$@"\n'
                         % shlex.quote(str(self.strict)))
        flaky.chmod(0o700)
        box.real = str(flaky)
        with self.assertRaises(RuntimeError):
            box.teardown()
        self.assertTrue(box.root.exists())
        box.real = str(self.strict)
        # The kill itself went through: tmux reports no server once it has exited.
        for _ in range(100):
            if box.state() == 'absent':
                break
            time.sleep(0.05)
        self.assertEqual(box.state(), 'absent', box.last_error)
        box.teardown()
        self.assertFalse(box.root.exists())


def recording_tmux(directory, log, then=None):
    """A `tmux` in DIRECTORY that appends its argv (and whether it saw the
    binding variable) to LOG, then execs THEN, or says no server runs."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    # Without THEN: the verbs named in $RECORD_OK succeed, every other call
    # finds no server.
    tail = 'exec %s "$@"\n' % shlex.quote(str(then)) if then else (
        'skip=; for a do if [ -n "$skip" ]; then skip=; continue; fi\n'
        'case "$a" in -S|-L|-f|-c|-T) skip=1 ;; -*) ;; *) verb=$a; break ;; esac; done\n'
        'case " $RECORD_OK " in *" $verb "*) exit 0 ;; esac\n'
        'echo "no server running on x" >&2\nexit 1\n')
    (directory / 'tmux').write_text('#!/bin/sh\nprintf "%%s|%%s\\n" "${SESSION_WORKSPACE_TMUX_SOCKET:+bound-env}" "$*" >> %s\n%s'
                                    % (shlex.quote(str(log)), tail))
    (directory / 'tmux').chmod(0o700)
    return directory


@unittest.skipUnless(tmux_sandbox.real_tmux(), 'tmux required')
class Binding(unittest.TestCase):
    """One server per engine operation (lib.sh sw_tmux_bind / tmux())."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='swbind-', dir='/tmp')).resolve()
        self.addCleanup(shutil.rmtree, str(self.root), True)
        self.log = self.root / 'calls.log'
        self.bin = recording_tmux(self.root / 'bin', self.log)
        self.tmpdir = self.root / 'tt'
        self.tmpdir.mkdir()

    def lib(self, script, **env):
        e = dict(BASE, PATH=str(self.bin) + os.pathsep + BASE['PATH'], TMUX_TMPDIR=str(self.tmpdir), TMPDIR=str(self.tmpdir))
        e.update(env)
        return subprocess.run(['bash', '-c', 'source "$1"; ' + script, 'probe', str(HERE / 'lib.sh')],
                              env=e, capture_output=True, text=True, timeout=30)

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_outside_tmux_binds_the_tmux_tmpdir_default_and_never_starts(self):
        r = self.lib('sw_tmux_bind; tmux list-sessions; tmux new-session -d -s x; true')
        self.assertEqual(r.returncode, 0, r.stderr)
        sock = '%s/tmux-%d/default' % (self.tmpdir, os.getuid())
        self.assertEqual(self.calls(), ['|-N -S %s list-sessions' % sock, '|-N -S %s new-session -d -s x' % sock])

    def test_start_may_create_the_server_once_with_new_session_only(self):
        # No server at bind: the first new-session may start one (it runs in a
        # command substitution, as the engine's do); every later call is -N.
        r = self.lib('sw_tmux_bind --may-start; x="$(tmux new-session -d -s x)"; tmux new-session -d -s y; tmux list-sessions; true',
                     RECORD_OK='new-session')
        self.assertEqual(r.returncode, 0, r.stderr)
        sock = '%s/tmux-%d/default' % (self.tmpdir, os.getuid())
        self.assertEqual(self.calls(), ['|-N -S %s list-sessions' % sock, '|-S %s new-session -d -s x' % sock,
                                        '|-N -S %s new-session -d -s y' % sock, '|-N -S %s list-sessions' % sock])
        parent = Path(sock).parent
        self.assertTrue(parent.is_dir())
        self.assertEqual(parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(list(self.tmpdir.glob('sw-tmux-bootstrap.*')), [])

    def test_start_on_a_running_server_never_starts_one(self):
        r = self.lib('sw_tmux_bind --may-start; tmux new-session -d -s x; true', RECORD_OK='list-sessions new-session')
        self.assertEqual(r.returncode, 0, r.stderr)
        sock = '%s/tmux-%d/default' % (self.tmpdir, os.getuid())
        self.assertEqual(self.calls(), ['|-N -S %s list-sessions' % sock, '|-N -S %s new-session -d -s x' % sock])

    def test_start_refuses_when_it_cannot_tell_whether_a_server_runs(self):
        # Only tmux's own "no server" may open the bootstrap; another failure stops start.
        (self.bin / 'tmux').write_text('#!/bin/sh\nprintf "%%s|%%s\\n" "" "$*" >> %s\necho "lost server" >&2\nexit 1\n'
                                       % shlex.quote(str(self.log)))
        r = self.lib('sw_tmux_bind --may-start; tmux new-session -d -s x')
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn('cannot tell whether a tmux server runs', r.stderr)
        self.assertEqual([c for c in self.calls() if 'new-session' in c], [])
        self.assertEqual(list(self.tmpdir.glob('sw-tmux-bootstrap.*')), [])

    def test_a_start_that_never_creates_a_session_leaves_no_bootstrap_file(self):
        r = self.lib('sw_tmux_bind --may-start; exit 3')
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertEqual(list(self.tmpdir.glob('sw-tmux-bootstrap.*')), [])

    def test_inside_tmux_binds_the_socket_of_tmux(self):
        r = self.lib('sw_tmux_bind; tmux list-panes; true', TMUX='/tmp/elsewhere/sock,123,0')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.calls(), ['|-N -S /tmp/elsewhere/sock list-panes'])

    def test_an_explicit_socket_is_used_and_must_agree_with_tmux(self):
        r = self.lib('sw_tmux_bind; tmux list-panes; true', SESSION_WORKSPACE_TMUX_SOCKET=str(self.root / 'a.sock'))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.calls(), ['|-N -S %s list-panes' % (self.root / 'a.sock')])
        for bad in ({'SESSION_WORKSPACE_TMUX_SOCKET': str(self.root / 'a.sock'), 'TMUX': str(self.root / 'b.sock') + ',1,0'},
                    {'SESSION_WORKSPACE_TMUX_SOCKET': 'relative/sock'}):
            self.log.unlink(missing_ok=True)
            r = self.lib('sw_tmux_bind; tmux list-panes', **bad)
            self.assertEqual(r.returncode, 1, bad)
            self.assertIn('Nothing was changed', r.stderr)
            self.assertEqual(self.calls(), [], bad)

    def test_the_tmux_client_never_carries_the_binding(self):
        # So a server it starts never passes the binding on to user panes.
        r = self.lib('sw_tmux_bind --may-start; [ -n "$SESSION_WORKSPACE_TMUX_SOCKET" ] && tmux new-session -d -s x; true')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.calls()), 2)  # the liveness probe and the new-session
        self.assertTrue(all(c.startswith('|') for c in self.calls()), self.calls())

    def test_every_engine_tmux_call_is_pinned_to_the_bound_server(self):
        # Start, show, reconcile, restart and stop on a private server through a
        # recording layer: every call names the bound socket before its command.
        box = tmux_sandbox.Sandbox(agent_stubs=True)
        self.addCleanup(box.teardown)
        layer = recording_tmux(self.root / 'layer', self.log, then=box.bin / 'tmux')
        env = box.env(dict(BASE, XDG_STATE_HOME=str(self.root / 'state'), SESSION_WORKSPACE_STOP_GRACE_SECONDS='0'))
        env['PATH'] = str(layer) + os.pathsep + env['PATH']
        cfg = ['--config', str(FIXTURE)]
        for argv in [('workspace-start.sh', 'development', '--no-attach'), ('workspace-status.sh',),
                     ('workspace-reconcile.sh', 'development', '--apply'), ('workspace-restart.sh', 'development', '--no-attach', '--no-save'),
                     ('workspace-stop.sh', 'development', '--confirmed')]:
            r = subprocess.run(['bash', str(HERE / argv[0]), *argv[1:], *cfg], env=env, capture_output=True, text=True, timeout=120)
            self.assertEqual(r.returncode, 0, (argv, r.stdout, r.stderr))
        calls = self.calls()
        self.assertGreater(len(calls), 10)
        sock = str(box.socket)
        unpinned = [c for c in calls if not (c.startswith('|-N -S %s ' % sock) or c.startswith('|-S %s new-session ' % sock))]
        self.assertEqual(unpinned, [])
        # Control: the stop did reach the bound server.
        self.assertNotEqual(box.tmux('has-session', '-t', '=project-d-development').returncode, 0)

    def test_idle_watcher_claims_no_pane_of_another_project(self):
        box = tmux_sandbox.Sandbox()
        self.addCleanup(box.teardown)
        self.assertEqual(box.tmux('new-session', '-d', '-s', 'other-development', 'sleep 600').returncode, 0)
        pane = box.tmux('display-message', '-p', '-t', 'other-development', '#{pane_id}').stdout.strip()
        box.tmux('set-option', '-p', '-t', pane, '@session_workspace_project', 'other-project')
        box.tmux('set-option', '-p', '-t', pane, '@session_workspace_pane', 'project-d-svc')
        state = self.root / 'idle'
        state.mkdir()
        argv = ['python3', str(HERE / 'idle-watch.py'), 'watch', '--config', str(FIXTURE), '--project', 'project-d',
                '--session', 'development', '--pane', 'project-d-svc', '--pane-id', pane, '--port', '1', '--kind', 'service',
                '--minutes', '1', '--state-dir', str(state)]
        env = box.env(BASE)
        r = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn('not armed', r.stderr)
        self.assertEqual(box.tmux('show-options', '-p', '-t', pane, '-v', '@session_workspace_idle_watcher').stdout.strip(), '')
        self.assertEqual([p for p in state.rglob('*') if p.is_file()], [])
        # Control: with this project's markers the same watcher arms (claims the pane).
        box.tmux('set-option', '-p', '-t', pane, '@session_workspace_project', 'project-d')
        watcher = subprocess.Popen(argv, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            claimed = ''
            for _ in range(100):
                claimed = box.tmux('show-options', '-p', '-t', pane, '-v', '@session_workspace_idle_watcher').stdout.strip()
                if claimed:
                    break
                time.sleep(0.1)
            self.assertEqual(claimed, str(watcher.pid))
        finally:
            watcher.kill()
            watcher.wait()


if __name__ == '__main__':
    unittest.main(verbosity=2)
