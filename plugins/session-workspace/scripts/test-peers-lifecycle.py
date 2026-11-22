#!/usr/bin/env python3
"""Schema-6 peer orchestrators: engine lifecycle (instances.json, start/stop of
orchestrator copies and workers, show/hide, ownership, stale records).

Everything runs on a private tmux server (tmux_sandbox.py: every tmux call
pinned to one -S socket under /tmp/swtmux-*), with a
stand-in `codex` that only draws an input line, and a temporary XDG_STATE_HOME
and HOME. The engine scripts are driven as subprocesses, so no test depends on
the policy hook. Synthetic data only; no paid calls, real agents or user stores.
"""
import json
import os
from pathlib import Path
import runpy
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

HERE = Path(os.environ.get('WORKSPACE_TEST_SCRIPTS', Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import tmux_sandbox  # noqa: E402  (test infrastructure, always from this directory)
FIXTURES = Path(__file__).resolve().parent / 'fixtures'
REPO_ROOT = Path(__file__).resolve().parents[3]
BASE_ENV = {k: v for k, v in os.environ.items()
            if not k.startswith(('SESSION_', 'KNOWLEDGE_')) and k not in ('TMUX', 'TMUX_PANE', 'XDG_STATE_HOME', 'TMUX_TMPDIR')}

AGENT = r'''#!/usr/bin/env bash
# Stand-in agent: draws an input line and stays up.
printf '\033[2J\033[Hstand-in agent\n\n› \n'
while :; do sleep 1; done
'''

HELD = '[held]'


def peers_config():
    return json.loads((FIXTURES / 'valid/peers-v6.json').read_text())


class Base(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='wpl-', dir='/tmp')
        self.root = Path(self.tmp.name).resolve()
        for d in ['component-a', 'component-b', '.agent-workspace', '.tmp/scheduler/tasks', '.tmp/messages', 'state', 'bin', 'home']:
            (self.root / d).mkdir(parents=True)
        agent = self.root / 'bin/codex'
        agent.write_text(AGENT)
        agent.chmod(agent.stat().st_mode | stat.S_IXUSR)
        self.state = self.root / 'state'
        # Every tmux call, the engine's included, goes to this sandbox's socket.
        self.sandbox = tmux_sandbox.Sandbox()
        self.addCleanup(self.sandbox.teardown)
        boxed = self.sandbox.env(BASE_ENV)
        self.env = dict(boxed, PATH=str(self.root / 'bin') + os.pathsep + boxed['PATH'],
                        XDG_STATE_HOME=str(self.state), HOME=str(self.root / 'home'),
                        SESSION_WORKSPACE_STOP_GRACE_SECONDS='0', SESSION_WORKSPACE_AGENT_READY_TIMEOUT='20',
                        SESSION_WORKSPACE_AGENT_READY_SETTLE_MS='200', SESSION_WORKSPACE_LOCK_TIMEOUT='60',
                        PYTHONDONTWRITEBYTECODE='1')
        self.cfg = peers_config()
        self.path = self.root / '.agent-workspace/workspace.json'
        self.write()

    def tearDown(self):
        # Kill the server first (sandbox teardown runs as a cleanup after this,
        # and is a no-op once the server is gone), then remove the files.
        self.sandbox.kill_server()
        # A detached idle watcher may still be finishing its stop record.
        for _ in range(40):
            try:
                self.tmp.cleanup()
                return
            except OSError:
                time.sleep(0.25)
        self.tmp.cleanup()

    # -- helpers -------------------------------------------------------------
    def write(self):
        self.path.write_text(json.dumps(self.cfg))

    def script(self, name, *args, caller=None, tmux_pane=None, env=None, config=True, timeout=120, bind=True, cwd=None):
        e = dict(env or self.env)
        if caller:
            e['SESSION_WORKSPACE_PANE_NAME'] = caller
            if bind:
                # a real harness launch sets the identity and the config together
                e['SESSION_WORKSPACE_CONFIG'] = str(self.path)
        if tmux_pane:
            e['TMUX_PANE'] = tmux_pane
        argv = ['bash', str(HERE / (name + '.sh')), *args]
        if config:
            argv += ['--config', str(self.path)]
        return subprocess.run(argv, env=e, capture_output=True, text=True, timeout=timeout, cwd=cwd)

    def out(self, r):
        return r.stdout + r.stderr

    def tmux(self, *args, check=True):
        r = subprocess.run(['tmux', *args], env=self.env, capture_output=True, text=True)
        if check and r.returncode != 0:
            raise AssertionError('tmux %s: %s' % (' '.join(args), r.stderr))
        return r.stdout

    def instances_path(self):
        return self.state / 'session-workspace/sample/instances.json'

    def inst_bytes(self):
        p = self.instances_path()
        return p.read_bytes() if p.exists() else None

    def inst(self):
        p = self.instances_path()
        return json.loads(p.read_text()) if p.exists() else {'orchestrators': [], 'workers': []}

    def plan(self, *args):
        r = self.script('workspace-plan', '--json', *args)
        self.assertEqual(r.returncode, 0, self.out(r))
        return json.loads(r.stdout)

    def sessions(self):
        return sorted(self.tmux('list-sessions', '-F', '#{session_name}', check=False).split())

    def panes(self):
        rows = []
        for line in self.tmux('list-panes', '-a', '-F', '#{session_name}\t#{window_index}\t#{pane_id}\t#{@session_workspace_pane}\t#{pane_pid}\t#{window_width}\t#{window_height}\t#{pane_dead}', check=False).splitlines():
            c = line.split('\t')
            rows.append(dict(session=c[0], window=int(c[1]), id=c[2], name=c[3], pid=c[4], cols=int(c[5]), rows=int(c[6]), dead=c[7] == '1'))
        return rows

    def pane(self, name):
        found = [p for p in self.panes() if p['name'] == name]
        return found[0] if found else None

    def start_base(self):
        r = self.script('workspace-start', 'development', '--no-attach')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertIsNotNone(self.pane('sample-master'))

    def start_copy(self, n=2):
        r = self.script('workspace-start', 'development-%d' % n, '--no-attach')
        self.assertEqual(r.returncode, 0, self.out(r))
        return r

    def worker(self, checkout='web', role='executor', label=None, show=False, owner=None, caller=None, **kw):
        args = ['--checkout', checkout, '--role', role, '--no-attach']
        if label:
            args += ['--label', label]
        if show:
            args.append('--show')
        if owner:
            args += ['--owner', owner]
        return self.script('workspace-start', *args, caller=caller, **kw)

    def snapshot(self):
        """Everything a refused call must leave alone."""
        return (self.inst_bytes(), sorted((p['session'], p['window'], p['id'], p['name']) for p in self.panes()))

    def assert_held(self, r, owner, rc=3):
        self.assertEqual(r.returncode, rc, self.out(r))
        line = [l for l in r.stdout.splitlines() if l.startswith('  [held]')]
        self.assertTrue(line, self.out(r))
        self.assertIn('owner ' + owner, line[0])


class Copies(Base):
    def test_01_copy_start_user_vs_orchestrator(self):
        self.start_base()
        before = self.snapshot()
        # an orchestrator caller is refused and creates nothing
        r = self.script('workspace-start', 'development-2', '--no-attach', caller='sample-master')
        self.assertEqual(r.returncode, 1, self.out(r))
        self.assertIn('orchestrator.peer_lifecycle', r.stderr)
        self.assertEqual(self.snapshot(), before)
        self.assertNotIn('sample-development-2', self.sessions())
        # the user creates the session and the record
        self.start_copy(2)
        self.assertIn('sample-development-2', self.sessions())
        self.assertEqual(self.inst()['orchestrators'], [{'index': 2}])
        self.assertIn('development-2', [s['id'] for s in self.plan()['sessions']])
        self.assertIsNotNone(self.pane('sample-master-2'))
        # a second run is idempotent
        after = self.snapshot()
        r = self.script('workspace-start', 'development-2', '--no-attach')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertIn('[kept]', r.stdout)
        self.assertEqual(self.snapshot(), after)

    def test_08_user_stops_a_copy(self):
        self.start_base()
        self.start_copy(2)
        r = self.worker(owner='sample-master', caller=None)
        self.assertEqual(r.returncode, 0, self.out(r))
        r = self.worker(checkout='vue3', owner='sample-master-2')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertEqual(len(self.inst()['workers']), 2)
        r = self.script('workspace-stop', 'development-2', '--confirmed')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertIn('sample-development', self.sessions())
        self.assertNotIn('sample-development-2', self.sessions())
        self.assertIsNotNone(self.pane('sample-master'))
        self.assertIsNotNone(self.pane('sample-web-executor'))
        self.assertIsNone(self.pane('sample-vue3-executor'))
        data = self.inst()
        self.assertEqual(data['orchestrators'], [])
        self.assertEqual([w['owner'] for w in data['workers']], ['sample-master'])

    def test_12_limits(self):
        self.cfg['peers']['limits'] = {'orchestrators': 2, 'workers_per_orchestrator': 1}
        self.write()
        self.start_base()
        self.start_copy(2)  # control: below the limit (declared + one copy = the limit)
        r = self.script('workspace-start', 'development-3', '--no-attach')
        self.assertEqual(r.returncode, 1, self.out(r))
        self.assertIn('[limit]', r.stdout)
        self.assertNotIn('sample-development-3', self.sessions())
        self.assertEqual(self.inst()['orchestrators'], [{'index': 2}])
        # one worker is under the per-orchestrator limit (control), the second is over it
        r = self.worker(owner='sample-master')
        self.assertEqual(r.returncode, 0, self.out(r))
        r = self.worker(checkout='vue3', owner='sample-master')
        self.assertEqual(r.returncode, 1, self.out(r))
        self.assertIn('[limit]', r.stdout)
        self.assertEqual(len(self.inst()['workers']), 1)
        # another owner has its own allowance
        r = self.worker(checkout='vue3', owner='sample-master-2')
        self.assertEqual(r.returncode, 0, self.out(r))

    def test_15_reboot_does_not_resurrect_copies(self):
        self.start_base()
        self.start_copy(2)
        r = self.worker(owner='sample-master-2')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertEqual(len(self.inst()['workers']), 1)
        # a reboot: every tmux session is gone, the state file stays
        self.sandbox.kill_server()
        self.assertEqual(self.sessions(), [])
        self.assertEqual(self.inst()['orchestrators'], [{'index': 2}])
        r = self.script('workspace-start', 'all', '--no-attach', '--no-services')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertEqual(self.sessions(), ['sample-development', 'sample-vue3-services', 'sample-web-services'])
        self.assertEqual(self.inst()['orchestrators'], [])
        self.assertEqual(self.inst()['workers'], [])
        # the same for a bare start (control: the declared session still starts)
        self.assertIsNotNone(self.pane('sample-master'))


class Workers(Base):
    def setUp(self):
        super().setUp()
        self.start_base()
        self.start_copy(2)

    def test_02_hidden_worker(self):
        r = self.worker(caller='sample-master')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertIn('worker: sample-web-executor (checkout web, role executor, owner sample-master, hidden)', r.stdout)
        self.assertIn('[ready] sample-development / sample-web-executor', r.stdout)
        p = self.pane('sample-web-executor')
        master = self.pane('sample-master')
        self.assertEqual(p['session'], 'sample-development')
        self.assertNotEqual(p['window'], master['window'])
        self.assertEqual((p['cols'], p['rows']), (160, 48))
        self.assertEqual(self.inst()['workers'], [{'checkout': 'web', 'role': 'executor', 'label': '', 'owner': 'sample-master', 'visible': False}])
        row = [x for x in json.loads(self.script('workspace-status', '--json').stdout) if x['pane'] == 'sample-web-executor'][0]
        self.assertEqual(row['worker'], {'name': 'sample-web-executor', 'role': 'executor', 'checkout': 'web', 'owner': 'sample-master', 'visible': False, 'running': True})
        self.assertTrue(row['running'])
        plan = self.plan('--running')
        w = [x for x in plan['workers'] if x['name'] == 'sample-web-executor'][0]
        self.assertEqual((w['owner'], w['role'], w['checkout'], w['visible'], w['running']), ('sample-master', 'executor', 'web', False, True))
        human = self.script('workspace-status').stdout
        self.assertIn('worker: checkout web, role executor, owner sample-master, hidden', human)

    def test_02b_hidden_size_variable(self):
        e = dict(self.env, SESSION_WORKSPACE_HIDDEN_SIZE='100x30')
        r = self.worker(owner='sample-master', env=e)
        self.assertEqual(r.returncode, 0, self.out(r))
        p = self.pane('sample-web-executor')
        self.assertEqual((p['cols'], p['rows']), (100, 30))
        # bad values are refused before anything is created (controls: the default works above)
        self.script('workspace-stop', '--worker', 'web-executor', '--confirmed', '--force')
        for bad in ['abc', '160', '30x5', '160x48x2', '0x0', '-5x20', '']:
            before = self.snapshot()
            r = self.worker(checkout='vue3', owner='sample-master', env=dict(self.env, SESSION_WORKSPACE_HIDDEN_SIZE=bad or 'x'))
            self.assertEqual(r.returncode, 1, (bad, self.out(r)))
            self.assertEqual(self.snapshot(), before, bad)

    def test_03_shown_worker(self):
        r = self.worker(show=True, owner='sample-master')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertIn('shown', r.stdout.splitlines()[1] + r.stdout.splitlines()[2] if len(r.stdout.splitlines()) > 2 else r.stdout)
        p, m = self.pane('sample-web-executor'), self.pane('sample-master')
        self.assertEqual((p['session'], p['window']), (m['session'], m['window']))
        self.assertTrue(self.inst()['workers'][0]['visible'])
        self.assertIn('[ready]', r.stdout)

    def test_04_held_by_another_owner(self):
        r = self.worker(owner='sample-master')
        self.assertEqual(r.returncode, 0, self.out(r))
        before = self.snapshot()
        r = self.worker(caller='sample-master-2')
        self.assert_held(r, 'sample-master')
        self.assertEqual(self.snapshot(), before)
        # controls: the owner gets [kept]; a different label on a "many" checkout starts
        r = self.worker(caller='sample-master')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertIn('[kept]', r.stdout)
        r = self.worker(label='auth', caller='sample-master-2')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertIsNotNone(self.pane('sample-web-executor-auth'))
        # a checkout that runs one executor at a time (vue3): held for the other owner and for the same owner
        r = self.worker(checkout='vue3', caller='sample-master')
        self.assertEqual(r.returncode, 0, self.out(r))
        before = self.snapshot()
        r = self.worker(checkout='vue3', caller='sample-master-2')  # the same name: held by its owner
        self.assert_held(r, 'sample-master')
        self.assertEqual(self.snapshot(), before)
        for kwargs in [dict(caller='sample-master-2', label='x'), dict(caller='sample-master', label='x')]:
            r = self.worker(checkout='vue3', **kwargs)
            self.assert_held(r, 'sample-master')
            self.assertIn('vue3 runs one executor at a time: sample-vue3-executor', r.stdout)
            self.assertEqual(self.snapshot(), before)
        # control: a reviewer, with a label, starts beside the executor
        r = self.worker(checkout='vue3', role='reviewer', label='x', caller='sample-master-2')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertIsNotNone(self.pane('sample-vue3-reviewer-x'))

    def test_05_race(self):
        procs = []
        for owner in ('sample-master', 'sample-master-2'):
            e = dict(self.env, SESSION_WORKSPACE_PANE_NAME=owner, SESSION_WORKSPACE_CONFIG=str(self.path))
            procs.append(subprocess.Popen(['bash', str(HERE / 'workspace-start.sh'), '--checkout', 'web', '--role', 'executor', '--no-attach',
                                           '--config', str(self.path)], env=e, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True))
        results = []
        for p in procs:
            output = p.communicate(timeout=120)[0]
            results.append((p.returncode, output))
        self.assertEqual(sorted(rc for rc, _ in results), [0, 3], results)
        loser = [o for rc, o in results if rc == 3][0]
        winner_owner = 'sample-master' if results[0][0] == 0 else 'sample-master-2'
        self.assertIn('owner ' + winner_owner, loser)
        self.assertEqual(len([p for p in self.panes() if p['name'] == 'sample-web-executor']), 1)
        self.assertEqual([w['owner'] for w in self.inst()['workers']], [winner_owner])

    def test_06_stop_show_hide_ownership(self):
        r = self.worker(owner='sample-master')
        self.assertEqual(r.returncode, 0, self.out(r))
        before = self.snapshot()
        pane = self.pane('sample-web-executor')
        for argv in [('workspace-stop', '--worker', 'web-executor', '--confirmed'),
                     ('workspace-stop', 'development', '--pane', 'web-executor', '--confirmed'),
                     ('workspace-show', 'web-executor'), ('workspace-hide', 'web-executor'),
                     ('workspace-start', 'development', '--pane', 'web-executor', '--no-attach')]:
            r = self.script(*argv, caller='sample-master-2')
            self.assert_held(r, 'sample-master')
            self.assertEqual(self.snapshot(), before, argv)
        self.assertEqual(self.pane('sample-web-executor')['id'], pane['id'])
        # controls: the owner shows, hides and stops; the user does too, with --force
        for argv in [('workspace-show', 'web-executor'), ('workspace-hide', 'sample-web-executor')]:
            r = self.script(*argv, caller='sample-master')
            self.assertEqual(r.returncode, 0, self.out(r))
        r = self.script('workspace-stop', '--worker', 'sample-web-executor', '--confirmed', caller='sample-master')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertIsNone(self.pane('sample-web-executor'))
        self.assertEqual(self.inst()['workers'], [])
        r = self.worker(owner='sample-master')
        self.assertEqual(r.returncode, 0, self.out(r))
        for argv in [('workspace-show', 'web-executor'), ('workspace-hide', 'web-executor')]:
            r = self.script(*argv)
            self.assertEqual(r.returncode, 0, self.out(r))
        r = self.script('workspace-stop', '--worker', 'web-executor', '--confirmed', '--force')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertIsNone(self.pane('sample-web-executor'))
        # unknown worker
        r = self.script('workspace-stop', '--worker', 'nothing', '--confirmed')
        self.assertEqual(r.returncode, 1, self.out(r))

    def test_07_caller_refusals(self):
        r = self.worker(owner='sample-master')
        self.assertEqual(r.returncode, 0, self.out(r))
        # (argv, control argv for the user that must succeed)
        cases = [
            (('workspace-stop', '--worker', 'web-executor', '--confirmed', '--force'), 'force'),
            (('workspace-start', '--checkout', 'vue3', '--role', 'reviewer', '--owner', 'sample-master', '--no-attach'), 'owner'),
            (('workspace-stop', 'development-2', '--confirmed'), 'copy'),
            (('workspace-stop', 'development', '--confirmed'), 'declared'),
            (('workspace-restart', 'development-2', '--no-attach'), 'restart'),
            (('workspace-stop', 'all', '--confirmed'), 'all'),
            (('workspace-stop', '--confirmed'), 'bare'),
            (('workspace-stop', 'web-services', '--all', '--confirmed'), 'widen'),
            (('workspace-start', 'development-3', '--no-attach'), 'new copy'),
            (('workspace-start', 'development-2', '--no-attach'), 'registered copy'),
            (('workspace-reconcile', 'development-2', '--apply'), 'reconcile'),
            (('workspace-reconcile', '--apply'), 'reconcile bare'),
            (('workspace-start', '--no-attach'), 'start bare'),
        ]
        for argv, label in cases:
            before = self.snapshot()
            r = self.script(*argv, caller='sample-master')
            self.assertEqual(r.returncode, 1, (label, self.out(r)))
            self.assertIn('orchestrator.peer_lifecycle', r.stderr, label)
            self.assertEqual(self.snapshot(), before, label)
        # worker callers may not run any mutating verb
        for argv in [('workspace-stop', 'web-services', '--confirmed'), ('workspace-start', 'web-services', '--no-attach'),
                     ('workspace-start', '--checkout', 'vue3', '--role', 'reviewer', '--no-attach'),
                     ('workspace-show', 'web-executor'), ('workspace-hide', 'web-executor'),
                     ('workspace-stop', '--worker', 'web-executor', '--confirmed'),
                     ('workspace-restart', 'web-services', '--no-attach'), ('workspace-reconcile', 'web-services', '--apply')]:
            before = self.snapshot()
            r = self.script(*argv, caller='sample-web-executor')
            self.assertEqual(r.returncode, 1, (argv, self.out(r)))
            self.assertIn('worker pane sample-web-executor', r.stderr)
            self.assertEqual(self.snapshot(), before, argv)
        # caller mismatch: the name of another pane with this pane's TMUX_PANE
        master = self.pane('sample-master')
        before = self.snapshot()
        r = self.script('workspace-stop', 'web-services', '--confirmed', caller='sample-master-2', tmux_pane=master['id'])
        self.assertEqual(r.returncode, 1, self.out(r))
        self.assertIn('caller identity does not match this pane', r.stderr)
        self.assertEqual(self.snapshot(), before)
        # controls: the same calls pass for the right caller (a service session, the matching pane) and the user
        r = self.script('workspace-start', 'web-services', '--no-attach', caller='sample-master', tmux_pane=master['id'])
        self.assertEqual(r.returncode, 0, self.out(r))
        r = self.script('workspace-stop', 'web-services', '--confirmed', caller='sample-master')
        self.assertEqual(r.returncode, 0, self.out(r))
        r = self.script('workspace-start', 'development-3', '--no-attach')
        self.assertEqual(r.returncode, 0, self.out(r))
        r = self.script('workspace-restart', 'development-3', '--no-attach')
        self.assertEqual(r.returncode, 0, self.out(r))
        r = self.script('workspace-reconcile', 'development-2', '--apply')
        self.assertEqual(r.returncode, 0, self.out(r))
        r = self.script('workspace-stop', 'development-3', '--confirmed')
        self.assertEqual(r.returncode, 0, self.out(r))

    def test_09_show_hide_round_trip(self):
        r = self.worker(owner='sample-master')
        self.assertEqual(r.returncode, 0, self.out(r))
        p0 = self.pane('sample-web-executor')
        master = self.pane('sample-master')

        def visible():
            rows = json.loads(self.script('workspace-status', '--json').stdout)
            return [x for x in rows if x['pane'] == 'sample-web-executor'][0]['worker']['visible']
        self.assertFalse(visible())
        r = self.script('workspace-hide', 'web-executor')
        self.assertIn('[hidden] sample-development / sample-web-executor (already)', r.stdout)
        self.assertEqual(r.returncode, 0)
        r = self.script('workspace-show', 'web-executor')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertIn('[shown]', r.stdout)
        p1 = self.pane('sample-web-executor')
        self.assertEqual((p1['id'], p1['pid']), (p0['id'], p0['pid']))
        self.assertEqual(p1['window'], master['window'])
        self.assertTrue(visible())
        self.assertTrue(self.inst()['workers'][0]['visible'])
        r = self.script('workspace-show', 'web-executor')
        self.assertIn('[shown] sample-development / sample-web-executor (already)', r.stdout)
        self.assertEqual(r.returncode, 0)
        r = self.script('workspace-hide', 'web-executor')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertIn('[hidden]', r.stdout)
        p2 = self.pane('sample-web-executor')
        self.assertEqual((p2['id'], p2['pid']), (p0['id'], p0['pid']))
        self.assertNotEqual(p2['window'], master['window'])
        self.assertEqual((p2['cols'], p2['rows']), (160, 48))
        self.assertFalse(visible())
        self.assertFalse(self.inst()['workers'][0]['visible'])
        # a worker that is not running
        self.script('workspace-stop', '--worker', 'web-executor', '--confirmed')
        r = self.script('workspace-show', 'web-executor')
        self.assertEqual(r.returncode, 1, self.out(r))

    def test_10_hidden_and_shown_agree(self):
        results = {}
        for show, checkout in [(False, 'web'), (True, 'vue3')]:
            r = self.worker(checkout=checkout, show=show, owner='sample-master')
            self.assertEqual(r.returncode, 0, self.out(r))
            self.assertIn('[ready]', r.stdout)
            name = 'sample-%s-executor' % checkout
            pane = self.pane(name)
            ready = subprocess.run(['python3', '-B', str(HERE / 'agent-pane.py'), 'ready', '--pane-id', pane['id']], env=self.env, capture_output=True, text=True)
            busy = subprocess.run(['python3', '-B', str(HERE / 'agent-pane.py'), 'busy', '--pane-id', pane['id'], '--pane', name], env=self.env, capture_output=True, text=True)
            results[show] = (ready.returncode, busy.returncode)
            self.assertEqual(results[show], (0, 0))
        self.assertEqual(results[False], results[True])
        # an assigned task keeps both busy; --force is the override
        for checkout in ('web', 'vue3'):
            name = 'sample-%s-executor' % checkout
            (self.root / ('.tmp/scheduler/tasks/t-%s.json' % checkout)).write_text(json.dumps({'id': 't-' + checkout, 'status': 'assigned', 'assignee': name, 'assigner': 'sample-master'}))
            r = self.script('workspace-stop', '--worker', name, '--confirmed')
            self.assertEqual(r.returncode, 1, self.out(r))
            self.assertIn('[busy]', r.stdout)
            self.assertIn('t-' + checkout, r.stdout)
            self.assertIsNotNone(self.pane(name))
        for checkout in ('web', 'vue3'):
            (self.root / ('.tmp/scheduler/tasks/t-%s.json' % checkout)).unlink()
            r = self.script('workspace-stop', '--worker', 'sample-%s-executor' % checkout, '--confirmed')
            self.assertEqual(r.returncode, 0, self.out(r))

    def test_10b_session_chat_delivery(self):
        sender = REPO_ROOT / 'plugins/session-chat/scripts/send-message.sh'
        if not sender.is_file():
            self.skipTest('cross-plugin delivery requires the sibling session-chat source tree')
        repo = REPO_ROOT.parent if REPO_ROOT.name == 'codex' else REPO_ROOT
        run_in_pane = runpy.run_path(str(repo / 'scripts/tmux_test_fixtures.py'))['run_in_pane']
        for show, checkout in [(False, 'web'), (True, 'vue3')]:
            r = self.worker(checkout=checkout, show=show, owner='sample-master')
            self.assertEqual(r.returncode, 0, self.out(r))
        master = self.pane('sample-master')['id']
        transport = self.tmux('display-message', '-p', '-t', master, '#{socket_path},#{pid},0').strip()
        messages = self.root / '.tmp/messages'
        env = dict(self.env, TMUX=transport, SESSION_CHAT_PANE_NAME='sample-master',
                   SESSION_CHAT_ALLOW_SHELL_TARGET='1', SESSION_CHAT_TARGET_MESSAGES_DIR=str(messages))
        deliveries = []
        for checkout in ('web', 'vue3'):
            name = 'sample-%s-executor' % checkout
            message = 'hello-%s' % checkout
            result = run_in_pane(self.tmux, master, ['bash', str(sender), name, message], env, self.root, timeout=60)
            self.assertIn(result.returncode, (0, 4), self.out(result))
            sent = (messages / 'sent-log.tsv').read_text().splitlines()[-1].split('\t')
            self.assertEqual(sent[2:5], ['sample-master', name, 'send'])
            self.assertEqual(sent[6], message)
            uid, delivery = sent[1], sent[5]
            self.assertRegex(uid, r'^[0-9a-f]{16}$')
            if delivery == 'live':
                self.assertEqual(result.returncode, 0, self.out(result))
                screen = self.tmux('capture-pane', '-p', '-J', '-t', self.pane(name)['id'])
                self.assertIn('id:%s' % uid, screen)
                self.assertIn(message, screen)
            else:
                self.assertIn(delivery, ('queued', 'unsubmitted'), sent)
                self.assertEqual(result.returncode, 4 if delivery == 'unsubmitted' else 0, self.out(result))
                queue = (messages / 'queue' / (name + '.tsv')).read_text().splitlines()
                self.assertTrue(any(row.split('\t')[:3] == [uid, 'send', 'sample-master']
                                    and row.split('\t')[-1] == message for row in queue), queue)
            deliveries.append(delivery)
        self.assertEqual(deliveries[0], deliveries[1], deliveries)

    def test_11_stale_records(self):
        r = self.worker(owner='sample-master')
        self.assertEqual(r.returncode, 0, self.out(r))
        r = self.worker(checkout='vue3', show=True, owner='sample-master-2')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertEqual(len(self.inst()['workers']), 2)
        # failed scan: tmux answers every other call, but list-panes/list-sessions fail
        real = shutil.which('tmux', path=self.env['PATH'])
        stub_dir = self.root / 'stub'
        stub_dir.mkdir()
        stub = stub_dir / 'tmux'
        # The verb is the first argument after tmux's global options (the engine passes -N -S SOCKET).
        stub.write_text('#!/bin/sh\nverb=; next=; skip=; found=\nfor a do\n'
                        '  if [ -n "$found" ]; then next=$a; break; fi\n'
                        '  if [ -n "$skip" ]; then skip=; continue; fi\n'
                        '  case "$a" in -S|-L|-f|-c|-T) skip=1 ;; -*) ;; *) verb=$a; found=1 ;; esac\ndone\n'
                        'case "$verb" in list-panes|list-sessions) [ "$next" = "-a" -o "$verb" = list-sessions ] && { echo "no server running" >&2; exit 1; };; esac\n'
                        'exec %s "$@"\n' % real)
        stub.chmod(0o755)
        stubbed = dict(self.env, PATH=str(stub_dir) + os.pathsep + self.env['PATH'])
        self.tmux('kill-pane', '-t', self.pane('sample-web-executor')['id'])
        before = self.inst_bytes()
        # vue3 is already shown, so `show` has nothing to record: the stale web record stays, byte for byte
        r = self.script('workspace-show', 'vue3-executor', env=stubbed)
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertIn('(already)', r.stdout)
        self.assertEqual(self.inst_bytes(), before, self.out(r))
        # control: real tmux removes the record of the killed pane at the next mutating verb
        self.assertEqual(len(self.inst()['workers']), 2)
        r = self.script('workspace-show', 'vue3-executor')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertEqual([w['checkout'] for w in self.inst()['workers']], ['vue3'])

    def test_11b_read_only_verbs_never_write(self):
        r = self.worker(owner='sample-master')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.tmux('kill-pane', '-t', self.pane('sample-web-executor')['id'])
        before = self.inst_bytes()
        for argv in [('workspace-plan', '--json'), ('workspace-plan', '--json', '--running'), ('workspace-status',), ('workspace-status', '--json'),
                     ('workspace-doctor',), ('workspace-reconcile',)]:
            self.script(*argv)
            self.assertEqual(self.inst_bytes(), before, argv)
        # control: a mutating verb does remove it
        self.script('workspace-reconcile', '--apply')
        self.assertEqual(self.inst()['workers'], [])

    def test_13_leftover_work(self):
        tasks = self.root / '.tmp/scheduler/tasks'
        queue = self.root / '.tmp/messages/queue'
        queue.mkdir(parents=True, exist_ok=True)
        task = tasks / 't-1.json'
        task.write_text(json.dumps({'id': 't-1', 'status': 'assigned', 'assignee': 'sample-web-executor', 'assigner': 'sample-master'}))
        before = self.snapshot()
        r = self.worker(caller='sample-master-2')
        self.assert_held(r, 'sample-master')
        self.assertIn('t-1', r.stdout)
        self.assertEqual(self.snapshot(), before)
        # control: the same assigner starts it
        r = self.worker(caller='sample-master')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.script('workspace-stop', '--worker', 'web-executor', '--confirmed', '--force')
        task.unlink()
        # a task in review for the reviewer pane
        task.write_text(json.dumps({'id': 't-2', 'status': 'review', 'assignee': 'x', 'reviewer': 'sample-web-reviewer', 'assigner': 'sample-master'}))
        r = self.worker(role='reviewer', caller='sample-master-2')
        self.assert_held(r, 'sample-master')
        task.unlink()
        # unread queue rows from another sender
        rows = queue / 'sample-web-executor.tsv'
        rows.write_text('abc\tmsg\tsample-master\t1\thello\n')
        r = self.worker(caller='sample-master-2')
        self.assert_held(r, 'sample-master')
        self.assertIn('unread', r.stdout)
        self.assertIsNone(self.pane('sample-web-executor'))
        r = self.worker(caller='sample-master')  # control: rows from the new owner
        self.assertEqual(r.returncode, 0, self.out(r))

    def test_14_fixed_identity(self):
        before = self.snapshot()
        bad = [['--checkout', 'web', '--role', 'executor', '--cwd', 'x'], ['--checkout', 'web', '--role', 'executor', '--runtime', 'x'],
               ['--checkout', 'web', '--role', 'executor', '--grant', 'x'], ['--checkout', 'web', '--role', 'orchestrator'],
               ['--checkout', 'web', '--role', 'service'], ['--checkout', 'unknown', '--role', 'executor'],
               ['--checkout', 'web', '--role', 'executor', '--label', 'Bad Label'], ['--checkout', 'web', '--role', 'executor', '--label', '-x'],
               ['--checkout', 'web', '--role', 'executor', 'development'], ['--checkout', 'web', '--role', 'executor', '--pane', 'x'],
               ['--checkout', 'web', '--role', 'executor', '--no-agents'], ['--checkout', 'web', '--role', 'executor', '--adopt', '--confirmed'],
               ['--checkout', 'web', '--role', 'executor', '--owner', 'sample-web-server'], ['--checkout', 'web']]
        for args in bad:
            r = self.script('workspace-start', *args, '--no-attach', caller=None)
            if '--owner' not in args:
                r = self.script('workspace-start', *args, '--no-attach', '--owner', 'sample-master')
            self.assertEqual(r.returncode, 1, (args, self.out(r)))
            self.assertEqual(self.snapshot(), before, args)
        # a record with extra fields gives the same launch as one without
        extra = {'version': 1, 'orchestrators': [], 'workers': [
            {'checkout': 'web', 'role': 'executor', 'label': '', 'owner': 'sample-master', 'visible': True,
             'cwd': '/etc', 'grants': ['secrets'], 'runtime': 'claude'}]}
        clean = {'version': 1, 'orchestrators': [], 'workers': [
            {'checkout': 'web', 'role': 'executor', 'label': '', 'owner': 'sample-master', 'visible': True}]}
        outputs = []
        for data in (extra, clean):
            p = self.instances_path()
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(json.dumps(data))
            res = []
            for sub in ('agent-argv', 'env-exports'):
                r = subprocess.run(['bash', str(HERE / 'adapters.sh'), sub, '--config', str(self.path), '--pane', 'sample-web-executor']
                                   + (['--tmux-pane', '%1'] if sub == 'env-exports' else []), env=self.env, capture_output=True)
                self.assertEqual(r.returncode, 0, r.stderr)
                res.append(r.stdout)
            outputs.append(res)
        self.assertEqual(outputs[0], outputs[1])
        self.assertTrue(outputs[0][0])
        self.assertIn(b'sample-web-executor', outputs[0][1])

    def test_16_reconcile_keeps_hidden_worker(self):
        r = self.worker(owner='sample-master')
        self.assertEqual(r.returncode, 0, self.out(r))
        before = self.snapshot()
        for args in [(), ('--apply',)]:
            r = self.script('workspace-reconcile', 'development', *args)
            self.assertEqual(r.returncode, 0, self.out(r))
            line = [l for l in r.stdout.splitlines() if 'sample-web-executor' in l]
            self.assertTrue(line and ('[would-keep]' in line[0] or '[kept]' in line[0]), self.out(r))
            self.assertNotIn('on-demand', line[0])
            self.assertEqual(self.snapshot(), before)
        r = self.script('workspace-start', 'development', '--no-attach')
        self.assertEqual(r.returncode, 0, self.out(r))
        line = [l for l in r.stdout.splitlines() if 'sample-web-executor' in l]
        self.assertTrue(line and '[kept]' in line[0], self.out(r))
        self.assertEqual(self.snapshot(), before)

    def test_17_doctor_reads_only(self):
        r = self.worker(owner='sample-master')
        self.assertEqual(r.returncode, 0, self.out(r))
        r = self.script('workspace-doctor', '--json')
        data = json.loads(r.stdout)
        check = [c for c in data['checks'] if c['id'] == 'peers.state'][0]
        self.assertEqual(check['status'], 'OK', check)
        self.assertIn('1 worker', check['message'])
        # a record the loader drops: reported, never removed
        raw = self.inst()
        raw['workers'].append({'checkout': 'gone', 'role': 'executor', 'label': '', 'owner': 'sample-master', 'visible': False})
        self.instances_path().write_text(json.dumps(raw))
        before = self.inst_bytes()
        r = self.script('workspace-doctor', '--json')
        check = [c for c in json.loads(r.stdout)['checks'] if c['id'] == 'peers.state'][0]
        self.assertEqual(check['status'], 'WARN', check)
        self.assertEqual(self.inst_bytes(), before)
        self.instances_path().write_text('[not an object')
        r = self.script('workspace-doctor', '--json')
        check = [c for c in json.loads(r.stdout)['checks'] if c['id'] == 'peers.state'][0]
        self.assertEqual(check['status'], 'WARN', check)


class EngineFixes(Base):
    """Fixes from the independent review of the engine layer."""

    def status_row(self, name):
        r = self.script('workspace-status', '--json')
        return [x for x in json.loads(r.stdout) if x['pane'] == name][0]

    # 1. a copy closed from outside is recreated by the next start
    def test_20_retry_of_an_externally_closed_copy(self):
        self.start_base()
        self.start_copy(2)
        self.tmux('kill-session', '-t', '=sample-development-2')
        self.assertNotIn('sample-development-2', self.sessions())
        r = self.script('workspace-start', 'development-2', '--no-attach')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertIn('sample-development-2', self.sessions())
        self.assertEqual(self.inst()['orchestrators'], [{'index': 2}])
        self.assertIsNotNone(self.pane('sample-master-2'))

    # 2. "shown" follows the pane marker, not the configured window index
    def test_21_renumbered_owner_window(self):
        self.start_base()
        r = self.worker(show=True, owner='sample-master')
        self.assertEqual(r.returncode, 0, self.out(r))
        before = self.pane('sample-web-executor')
        self.assertTrue(self.status_row('sample-web-executor')['worker']['visible'])  # control: not renumbered
        self.tmux('move-window', '-s', '=sample-development:0', '-t', '=sample-development:8')
        self.assertEqual(self.pane('sample-master')['window'], 8)
        self.assertTrue(self.status_row('sample-web-executor')['worker']['visible'])
        r = self.script('workspace-show', 'web-executor')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertIn('(already)', r.stdout)
        r = self.script('workspace-hide', 'web-executor')
        self.assertEqual(r.returncode, 0, self.out(r))
        p = self.pane('sample-web-executor')
        self.assertNotEqual(p['window'], 8)
        self.assertFalse(self.status_row('sample-web-executor')['worker']['visible'])
        r = self.script('workspace-show', 'web-executor')
        self.assertEqual(r.returncode, 0, self.out(r))
        p = self.pane('sample-web-executor')
        self.assertEqual(p['window'], 8)
        self.assertEqual((p['id'], p['pid']), (before['id'], before['pid']))
        self.assertTrue(self.status_row('sample-web-executor')['worker']['visible'])
        # a shown worker started now joins the orchestrator's window
        r = self.worker(checkout='vue3', show=True, owner='sample-master')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertEqual(self.pane('sample-vue3-executor')['window'], 8)

    # 3. a harness identity that does not resolve never gets user authority
    def test_22_unresolved_identity_is_refused(self):
        self.start_base()
        r = self.worker(owner='sample-master')
        self.assertEqual(r.returncode, 0, self.out(r))
        msg = 'harness identity %s is not a pane of this workspace; nothing was changed'
        for ghost in ['ghost', 'bad name!']:
            before = self.snapshot()
            for argv in [('workspace-start', '--checkout', 'vue3', '--role', 'executor', '--owner', 'sample-master', '--no-attach'),
                         ('workspace-stop', '--worker', 'web-executor', '--confirmed'),
                         ('workspace-show', 'web-executor'), ('workspace-hide', 'web-executor'),
                         ('workspace-start', 'development-2', '--no-attach')]:
                r = self.script(*argv, caller=ghost)
                self.assertEqual(r.returncode, 1, (argv, self.out(r)))
                self.assertIn(msg % ghost, r.stderr)
                self.assertEqual(self.snapshot(), before, argv)
        # bound through the project root alone
        e = dict(self.env, SESSION_WORKSPACE_PANE_NAME='ghost', SESSION_WORKSPACE_PROJECT_ROOT=str(self.root))
        r = self.script('workspace-start', 'development-2', '--no-attach', env=e)
        self.assertEqual(r.returncode, 1, self.out(r))
        self.assertIn(msg % 'ghost', r.stderr)
        # a worker whose record the cleanup removed is no pane of the workspace
        self.tmux('kill-pane', '-t', self.pane('sample-web-executor')['id'])
        r = self.script('workspace-start', 'development', '--no-attach')
        self.assertEqual(r.returncode, 0, self.out(r))
        self.assertEqual(self.inst()['workers'], [])
        r = self.script('workspace-start', 'development-2', '--no-attach', caller='sample-web-executor')
        self.assertEqual(r.returncode, 1, self.out(r))
        self.assertIn(msg % 'sample-web-executor', r.stderr)
        self.assertNotIn('sample-development-2', self.sessions())
        # controls: no identity is the user; another project's identity is the user; a bound orchestrator works
        other = self.root / 'other.json'
        other.write_text(json.dumps(self.cfg))
        e = dict(self.env, SESSION_WORKSPACE_PANE_NAME='ghost', SESSION_WORKSPACE_CONFIG=str(other))
        r = self.script('workspace-start', 'development-2', '--no-attach', env=e)
        self.assertEqual(r.returncode, 0, self.out(r))
        e = dict(self.env, SESSION_WORKSPACE_PANE_NAME='ghost', SESSION_WORKSPACE_PROJECT_ROOT='/nonexistent-project')
        r = self.script('workspace-start', 'development-3', '--no-attach', env=e)
        self.assertEqual(r.returncode, 0, self.out(r))
        r = self.worker(caller='sample-master')
        self.assertEqual(r.returncode, 0, self.out(r))
        r = self.script('workspace-start', 'development', '--no-attach')
        self.assertEqual(r.returncode, 0, self.out(r))

    # 4. one state home for the lock and the registry
    def test_23_relative_state_home(self):
        self.start_base()
        a = self.root / 'cwd-a'
        b = self.root / 'cwd-b'
        a.mkdir()
        b.mkdir()
        env = dict(self.env, XDG_STATE_HOME='rel-state', SESSION_WORKSPACE_LOCK_TIMEOUT='1')
        real = self.root / 'home/.local/state/session-workspace/sample'
        lock = real / 'lock'
        lock.mkdir(parents=True)
        (lock / 'pid').write_text('%d\n' % os.getpid())
        try:
            for cwd in (a, b):
                r = self.script('workspace-start', 'development-2', '--no-attach', env=env, cwd=cwd)
                self.assertEqual(r.returncode, 1, self.out(r))
                self.assertIn('could not acquire workspace lock', r.stderr)
        finally:
            shutil.rmtree(lock)
        # control: with the lock free both directories work and share one file
        r = self.script('workspace-start', 'development-2', '--no-attach', env=env, cwd=a)
        self.assertEqual(r.returncode, 0, self.out(r))
        r = self.script('workspace-start', '--checkout', 'web', '--role', 'executor', '--owner', 'sample-master', '--no-attach', env=env, cwd=b)
        self.assertEqual(r.returncode, 0, self.out(r))
        data = json.loads((real / 'instances.json').read_text())
        self.assertEqual(data['orchestrators'], [{'index': 2}])
        self.assertEqual(len(data['workers']), 1)
        self.assertFalse((a / 'rel-state').exists() or (b / 'rel-state').exists())

    # 5. failed-start cleanup touches only the window this run made
    def test_24_failed_worker_start_keeps_a_user_window(self):
        self.start_base()
        self.tmux('new-window', '-d', '-t', '=sample-development:', '-n', 'sample-web-executor')
        self.cfg['runtimes']['codex']['program'] = '/nonexistent/codex-program'
        self.write()
        r = self.worker(owner='sample-master')
        self.assertNotEqual(r.returncode, 0, self.out(r))
        self.assertEqual(self.inst()['workers'], [])
        names = self.tmux('list-windows', '-t', '=sample-development', '-F', '#{window_name}').split()
        self.assertIn('sample-web-executor', names)  # the user's own window survived
        # control: a window this run made is removed (only the user's one is left)
        self.assertEqual(names.count('sample-web-executor'), 1)

    def test_25_failed_copy_start_removes_its_record(self):
        self.start_base()
        self.cfg['runtimes']['codex']['program'] = '/nonexistent/codex-program'
        self.write()
        r = self.script('workspace-start', 'development-2', '--no-attach')
        self.assertNotEqual(r.returncode, 0, self.out(r))
        self.assertNotIn('sample-development-2', self.sessions())
        self.assertEqual(self.inst()['orchestrators'], [])
        # control: a working launch keeps the record
        self.cfg['runtimes']['codex']['program'] = 'codex'
        self.write()
        self.start_copy(2)
        self.assertEqual(self.inst()['orchestrators'], [{'index': 2}])


class IdleStop(Base):
    def test_26_idle_service_stops_after_its_starter_exits(self):
        activity = self.root / 'producing-output'
        activity.touch()
        service = next(s for s in self.cfg['sessions'] if s['id'] == 'web-services')['panes'][0]
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            service['port'] = probe.getsockname()[1]
        service.update(idle_stop_minutes=1, idle_activity=['output'],
                       command=['sh', '-c', 'while [ -f "$1" ]; do echo active; sleep 0.2; done; exec sleep 600',
                                'fixture', str(activity)])
        self.write()
        self.start_base()
        self.start_copy(2)
        owner = self.pane('sample-master-2')
        inherited = dict(self.env, SESSION_WORKSPACE_IDLE_SAMPLE_SECONDS='0.25',
                         SESSION_WORKSPACE_IDLE_SECONDS_PER_MINUTE='2',
                         SESSION_CHAT_PANE_NAME=owner['name'], KNOWLEDGE_PANE_NAME=owner['name'])
        started = self.script('workspace-start', 'web-services', '--no-attach', caller=owner['name'],
                              tmux_pane=owner['id'], env=inherited)
        self.assertEqual(started.returncode, 0, self.out(started))
        self.assertIn('idle stop armed', started.stdout)
        pane = self.pane(service['name'])
        self.assertIsNotNone(pane)
        stopped = self.script('workspace-stop', 'development-2', '--confirmed')
        self.assertEqual(stopped.returncode, 0, self.out(stopped))
        self.assertIsNone(self.pane(owner['name']))
        refused = self.script('workspace-stop', 'web-services', '--pane', pane['name'], '--confirmed',
                              '--expect-pane-id', pane['id'], caller=owner['name'], tmux_pane=owner['id'])
        self.assertEqual(refused.returncode, 1, self.out(refused))
        self.assertIn('is not a pane of this workspace', refused.stderr)
        self.assertEqual(self.pane(pane['name'])['id'], pane['id'])

        # Stop producing output. The real detached watcher now makes its guarded stop.
        activity.unlink()
        record = self.state / 'session-workspace/sample/panes' / (pane['name'] + '.json')
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            current = json.loads(record.read_text())
            if current.get('stop_error') or (current.get('state') == 'stopped' and not self.pane(pane['name'])):
                break
            time.sleep(0.25)
        last = json.loads(record.read_text())
        self.assertIsNone(self.pane(pane['name']), last)
        self.assertEqual(last['pane_id'], pane['id'])
        self.assertEqual(last['state'], 'stopped')
        self.assertEqual(last['stop_reason'], 'idle: no new pane output for 1 minute')

    def test_27_callback_preserves_worker_restrictions(self):
        self.start_base()
        owner = self.pane('sample-master')
        started = self.worker(owner=owner['name'])
        self.assertEqual(started.returncode, 0, self.out(started))
        worker = self.pane('sample-web-executor')
        inherited = dict(self.env, SESSION_WORKSPACE_CONFIG=str(self.path),
                         SESSION_WORKSPACE_PANE_NAME=owner['name'], TMUX_PANE=owner['id'],
                         SESSION_CHAT_PANE_NAME=owner['name'], KNOWLEDGE_PANE_NAME=owner['name'])
        stop_env = runpy.run_path(str(HERE / 'idle-watch.py'))['stop_env']
        with patch.dict(os.environ, inherited, clear=True):
            callback = stop_env(worker['name'], worker['id'], 'idle')
        self.assertNotIn('SESSION_CHAT_PANE_NAME', callback)
        self.assertNotIn('KNOWLEDGE_PANE_NAME', callback)
        self.assertEqual(callback['TMUX_PANE'], worker['id'])
        self.assertEqual(callback['SESSION_WORKSPACE_PANE_NAME'], worker['name'])
        stop = ('workspace-stop', 'development', '--pane', worker['name'], '--confirmed',
                '--expect-pane-id', worker['id'])
        refused = self.script(*stop, env=callback)
        self.assertEqual(refused.returncode, 1, self.out(refused))
        self.assertIn('worker pane %s may not stop panes' % worker['name'], refused.stderr)
        self.assertEqual(self.pane(worker['name'])['id'], worker['id'])
        allowed = self.script(*stop, caller=owner['name'], tmux_pane=owner['id'])
        self.assertEqual(allowed.returncode, 0, self.out(allowed))
        self.assertIsNone(self.pane(worker['name']))

    def test_28_status_reads_a_single_pane_run_record(self):
        record = self.state / 'session-workspace/sample/panes/sample-web-server.json'
        record.parent.mkdir(parents=True)
        stopped = {'at': '2026-01-15T12:30:00Z', 'reason': 'idle'}
        valid = json.dumps({'stopped_at': stopped['at'], 'stop_reason': stopped['reason']})
        for contents, expected in ((None, None), ('  \n', None), ('{}\n{}', None), (valid, stopped)):
            with self.subTest(contents=contents):
                if contents is not None:
                    record.write_text(contents)
                result = self.script('workspace-status', 'web-services', '--json')
                self.assertEqual(result.returncode, 0, self.out(result))
                self.assertEqual(result.stderr, '')
                row, = json.loads(result.stdout)
                self.assertEqual(row['pane'], 'sample-web-server')
                self.assertEqual(row['last_stop'], expected)


if __name__ == '__main__':
    unittest.main(verbosity=2)
