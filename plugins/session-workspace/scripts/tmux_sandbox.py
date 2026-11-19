"""Private tmux servers for the session-workspace test suites (Python 3.9).

tmux falls back to its default server (/tmp/tmux-UID/default) when
TMUX_TMPDIR names a directory that does not exist. A test isolated by
TMUX_TMPDIR alone therefore fails open: once its directory is gone, its
teardown and any engine stop it runs reach the developer's real server.

A Sandbox pins every tmux call to one socket instead:

* a wrapper named `tmux`, first on PATH, adds `-S SOCKET` to every call, the
  engine scripts' calls included;
* the socket lives in a short directory under /tmp with the fixed prefix
  `swtmux-` (macOS caps socket paths at 104 bytes), so a server left by an
  interrupted run can be recognized;
* every server starts with `-f /dev/null`, so the user's tmux config and its
  plugins (tmux-resurrect, tmux-continuum) never load into a test server;
* env() gives every process a decoy HOME and XDG config/data/cache homes under
  the sandbox, so a stop's tmux-resurrect save (looked up under $HOME) and any
  other per-user file never reach the user's own;
* teardown addresses only that socket with `-S`, only while the socket file
  exists inside the sandbox directory, and kills the server before it removes
  the directory. A server it cannot confirm stopped, or a socket it refuses,
  keeps the directory and raises.

Never call `tmux kill-server` without `-S` in a test.
"""
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time

PREFIX = 'swtmux-'
SOCKET_ROOT = Path('/tmp').resolve()

# A `tmux` wrapper that pins every call to OWN and refuses a call whose global
# options (those before the command) name another server. The engine adds its
# own `-N -S SOCKET`, which must be this sandbox's socket. Options after the
# command, such as capture-pane -S -120, are the command's and pass through.
PIN_WRAPPER = r"""#!/bin/sh
# Pins every tmux call to one private server (tmux_sandbox.py).
own=%(own)s
skip=
for a do
  if [ -n "$skip" ]; then
    if [ "$skip" = S ] && [ "$a" != "$own" ]; then echo "tmux sandbox: refusing a call for another server ($a)" >&2; exit 99; fi
    skip=
    continue
  fi
  case "$a" in
    -S) skip=S ;;
    -L|-L*|-S*) echo "tmux sandbox: refusing a call for another server ($a)" >&2; exit 99 ;;
    -f|-c|-T) skip=x ;;
    --) break ;;
    -*) ;;
    *) break ;;
  esac
done
exec %(real)s -f %(conf)s -S "$own" "$@"
"""


def pin_wrapper(real, own, conf='/dev/null'):
    return PIN_WRAPPER % {'own': shlex.quote(str(own)), 'real': shlex.quote(str(real)), 'conf': shlex.quote(str(conf))}


def real_tmux():
    """The tmux binary itself, never another sandbox's wrapper."""
    dirs = [d for d in os.environ.get('PATH', '').split(os.pathsep) if d and PREFIX not in str(Path(d).resolve())]
    return shutil.which('tmux', path=os.pathsep.join(dirs))


class Sandbox:
    """One private tmux server. Use env() for every subprocess that may run
    tmux, tmux() for the test's own calls, and teardown() in cleanup."""

    def __init__(self, agent_stubs=False, tmux_binary=None):
        # tmux_binary: a test double beneath both the wrapper and tmux().
        self.real = tmux_binary or real_tmux()
        if not self.real:
            raise RuntimeError('tmux is not installed')
        self.root = Path(tempfile.mkdtemp(prefix=PREFIX, dir=str(SOCKET_ROOT))).resolve()
        self.socket = self.root / 'sock'
        self.tmpdir = self.root / 'tmp'
        self.tmpdir.mkdir(mode=0o700)
        self.home = self.root / 'home'
        for sub in ('.config', '.local/share', '.cache'):
            (self.home / sub).mkdir(parents=True)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        wrapper = self.bin / 'tmux'
        wrapper.write_text(pin_wrapper(self.real, self.socket))
        wrapper.chmod(0o700)
        if agent_stubs:
            # Agent runtimes are never launched for real inside a sandbox.
            for name in ('claude', 'codex'):
                stub = self.bin / name
                stub.write_text('#!/bin/sh\nexec sleep 3600\n')
                stub.chmod(0o700)

    def env(self, base=None):
        """BASE (default os.environ) with TMUX and TMUX_PANE removed, the
        wrapper first on PATH, TMUX_TMPDIR set to an existing directory, and
        a decoy HOME with its own XDG config/data/cache homes. A caller may
        still override any of these afterwards (for example HOME)."""
        env = {k: v for k, v in (os.environ if base is None else base).items() if k not in ('TMUX', 'TMUX_PANE')}
        env['PATH'] = str(self.bin) + os.pathsep + env.get('PATH', '')
        env['TMUX_TMPDIR'] = str(self.tmpdir)
        # The engine binds this socket (lib.sh), so its own -S matches the wrapper's.
        env['SESSION_WORKSPACE_TMUX_SOCKET'] = str(self.socket)
        env.update(HOME=str(self.home), XDG_CONFIG_HOME=str(self.home / '.config'),
                   XDG_DATA_HOME=str(self.home / '.local/share'), XDG_CACHE_HOME=str(self.home / '.cache'))
        return env

    def tmux(self, *args, **kwargs):
        """Run tmux against this sandbox's socket only."""
        kwargs.setdefault('capture_output', True)
        kwargs.setdefault('text', True)
        env = {k: v for k, v in kwargs.pop('env', os.environ).items() if k not in ('TMUX', 'TMUX_PANE')}
        env.update(HOME=str(self.home), XDG_CONFIG_HOME=str(self.home / '.config'),
                   XDG_DATA_HOME=str(self.home / '.local/share'), XDG_CACHE_HOME=str(self.home / '.cache'))
        return subprocess.run([self.real, '-f', '/dev/null', '-S', str(self.socket), *args], env=env, **kwargs)

    def owns(self, socket):
        """True only for a socket file inside this sandbox's own directory."""
        try:
            path = Path(socket)
            resolved = path.resolve()
            return (self.root.parent == SOCKET_ROOT and self.root.name.startswith(PREFIX)
                    and resolved.parent == self.root and path.exists() and stat.S_ISSOCK(path.lstat().st_mode))
        except OSError:
            return False

    # tmux's own messages for "nothing is listening on this socket".
    ABSENT = ('no server running on ', '(No such file or directory)', '(Connection refused)')

    def state(self):
        """'running', 'absent' (tmux itself says no server listens on this
        socket) or 'unknown' (any other failure, which proves nothing)."""
        r = self.tmux('list-sessions')
        if r.returncode == 0:
            return 'running'
        if r.returncode == 1 and any(m in (r.stderr or '') for m in self.ABSENT):
            return 'absent'
        return 'unknown'

    def running(self):
        """True while a server answers on this sandbox's own socket."""
        return self.owns(self.socket) and self.state() == 'running'

    def kill_server(self):
        """End this sandbox's server, if it is running, and confirm it is gone.
        Fails closed: a socket that is missing or outside the sandbox is left
        alone (returns False). Raises unless tmux confirms no server listens."""
        if not self.owns(self.socket):
            return False
        self.tmux('kill-server')
        for _ in range(40):
            current = self.state()
            if current == 'absent':
                return True
            if current == 'unknown':
                break
            time.sleep(0.05)
        raise RuntimeError('tmux_sandbox: could not confirm the server on %s stopped; %s kept' % (self.socket, self.root))

    def teardown(self):
        """Kill the server, then remove the directory, in that order. A socket
        it refuses, or a server it cannot stop, keeps the directory and raises."""
        if os.path.lexists(str(self.socket)) and not self.owns(self.socket):
            raise RuntimeError('tmux_sandbox: refusing to tear down %s; %s kept' % (self.socket, self.root))
        if self.root.exists():
            self.kill_server()
        shutil.rmtree(str(self.root), ignore_errors=True)
