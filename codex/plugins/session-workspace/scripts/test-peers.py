#!/usr/bin/env python3
"""Schema-6 peer orchestrators: config loading, validation and plan. Synthetic
data only; no paid calls, agent launches or user stores (every subprocess gets
its own XDG_STATE_HOME)."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = Path(os.environ.get('WORKSPACE_TEST_SCRIPTS', Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import tmux_sandbox  # noqa: E402  (test infrastructure, always from this directory)
FIXTURES = Path(__file__).resolve().parent / 'fixtures'
ENV = {k: v for k, v in os.environ.items()
       if not k.startswith(('SESSION_', 'KNOWLEDGE_')) and k not in ('TMUX', 'TMUX_PANE', 'XDG_STATE_HOME')}
# Every default run is pinned to a private tmux server and a decoy HOME, so no
# test here reads or writes the user's server or its tmux-resurrect saves.
# Allocated by the test run only (setUpModule), never on import.
DEFAULT_BOX = None


def setUpModule():
    global DEFAULT_BOX, ENV
    if tmux_sandbox.real_tmux():
        DEFAULT_BOX = tmux_sandbox.Sandbox()
        ENV = DEFAULT_BOX.env(ENV)


def tearDownModule():
    if DEFAULT_BOX:
        DEFAULT_BOX.teardown()


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    m = importlib.util.module_from_spec(spec)
    sys.modules[name] = m
    spec.loader.exec_module(m)
    return m


def peers_config():
    return json.loads((FIXTURES / 'valid/peers-v6.json').read_text())


def order(plan):
    return [(s['id'], [p['name'] for p in s['panes']]) for s in plan['sessions']]


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='wp6-', dir='/tmp')
        self.root = Path(self.tmp.name).resolve()
        self.state = self.root / 'state'
        for d in ['component-a', 'component-b', '.agent-workspace', '.tmp/scheduler/tasks', '.tmp/messages', 'state']:
            (self.root / d).mkdir(parents=True)
        self.env = dict(ENV, XDG_STATE_HOME=str(self.state))
        self.cfg = peers_config()
        self.path = self.root / '.agent-workspace/workspace.json'
        self.write()

    def tearDown(self):
        self.tmp.cleanup()

    def write(self):
        self.path.write_text(json.dumps(self.cfg))

    def run_script(self, name, *args, env=None, config=True):
        argv = ['bash', str(HERE / (name + '.sh')), *args]
        if config:
            argv += ['--config', str(self.path)]
        return subprocess.run(argv, env=env or self.env, capture_output=True, text=True, timeout=60)

    def plan(self, *args):
        r = self.run_script('workspace-plan', '--json', *args)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)

    def validate(self):
        r = self.run_script('validate-config')
        return r.returncode, r.stdout + r.stderr

    def assert_valid(self):
        rc, out = self.validate()
        self.assertEqual(rc, 0, out)

    def instances_path(self):
        return self.state / 'session-workspace/sample/instances.json'

    def write_instances(self, data):
        path = self.instances_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data if isinstance(data, str) else json.dumps(data))

    def exports(self, pane, env=None):
        r = subprocess.run(['bash', str(HERE / 'adapters.sh'), 'env-exports', '--config', str(self.path), '--pane', pane],
                           env=env or self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout


def worker(checkout, role, owner, label='', visible=False):
    return {'checkout': checkout, 'role': role, 'label': label, 'owner': owner, 'visible': visible}


FLEET = {
    'orchestrators': [{'index': 3}, {'index': 2}, {'index': 2}],
    'workers': [
        worker('web', 'executor', 'sample-master'),
        worker('web', 'reviewer', 'sample-master', visible=True),
        worker('vue3', 'executor', 'sample-master', 'v'),
        worker('web', 'executor', 'sample-master-2', 'b'),
        worker('web', 'reviewer', 'sample-master-2', 'b'),
        worker('vue3', 'reviewer', 'sample-master-3'),
    ],
}


class Peers(Base):
    # -- 2 -------------------------------------------------------------
    def test_fixture_validates_and_plans(self):
        self.assert_valid()
        plan = self.plan()
        self.assertEqual(plan['schema_version'], 6)
        self.assertEqual(plan['peers'], {'session': 'development', 'limits': {}})
        self.assertEqual(plan['workers'], [])
        dev = plan['sessions'][0]
        self.assertEqual(dev['instance'], {'of': 'development', 'index': 1})
        self.assertNotIn('instance', plan['sessions'][1])
        pane = dev['panes'][0]
        self.assertEqual(pane['scope_identity'], {'environment': None, 'peer': 'sample-master'})
        self.assertIsInstance(pane['scope'], dict)
        self.assertEqual(pane['scope']['peer'], 'sample-master')
        self.assertEqual([e['id'] for e in pane['scope']['environments']], ['web', 'vue3'])
        self.assertIn('XDG_STATE_HOME', pane['env_names'])
        # A service pane keeps today's formula, without a root orchestrator.
        service = plan['sessions'][1]['panes'][0]
        self.assertEqual(service['scope_identity']['environment'], 'web')
        self.assertIsNone(service['scope_identity']['root_orchestrator'])
        self.cfg['peers']['limits'] = {'orchestrators': 2, 'workers_per_orchestrator': 3}
        self.write()
        self.assertEqual(self.plan()['peers']['limits'], {'orchestrators': 2, 'workers_per_orchestrator': 3})

    # -- 3 -------------------------------------------------------------
    def test_expansion(self):
        self.write_instances(dict(FLEET, version=1))
        self.assert_valid()
        plan = self.plan()
        self.assertEqual(order(plan), [
            ('development', ['sample-master', 'sample-web-executor', 'sample-web-reviewer', 'sample-vue3-executor-v']),
            ('development-2', ['sample-master-2', 'sample-web-executor-b', 'sample-web-reviewer-b']),
            ('development-3', ['sample-master-3', 'sample-vue3-reviewer']),
            ('web-services', ['sample-web-server']),
            ('vue3-services', ['sample-vue3-server'])])
        self.assertEqual([s['name'] for s in plan['sessions']][:3], ['sample-development', 'sample-development-2', 'sample-development-3'])
        self.assertEqual([s.get('instance') for s in plan['sessions']][:4], [
            {'of': 'development', 'index': 1}, {'of': 'development', 'index': 2}, {'of': 'development', 'index': 3}, None])
        panes = {p['name']: p for s in plan['sessions'] for p in s['panes']}
        w = panes['sample-web-reviewer']
        self.assertEqual((w['role'], w['launch'], w['cwd']), ('reviewer', 'on_demand', str(self.root / 'component-a')))
        self.assertEqual(w['worker'], worker('web', 'reviewer', 'sample-master', visible=True))
        self.assertEqual(panes['sample-vue3-executor-v']['cwd'], str(self.root / 'component-b'))
        self.assertEqual(panes['sample-master-2']['launch'], 'always')
        self.assertNotIn('worker', panes['sample-master'])
        self.assertEqual(panes['sample-master-3']['scope_identity'], {'environment': None, 'peer': 'sample-master-3'})
        self.assertEqual(panes['sample-web-executor-b']['scope_identity'], {
            'environment': 'web', 'owner': 'sample-master-2', 'own': plan['environments'][0]})
        self.assertEqual(plan['environments'][0]['development'], [])
        self.assertEqual([(x['name'], x['role'], x['checkout'], x['owner'], x['visible'], x['running'], x['session']) for x in plan['workers']], [
            ('sample-web-executor', 'executor', 'web', 'sample-master', False, None, 'development'),
            ('sample-web-reviewer', 'reviewer', 'web', 'sample-master', True, None, 'development'),
            ('sample-vue3-executor-v', 'executor', 'vue3', 'sample-master', False, None, 'development'),
            ('sample-web-executor-b', 'executor', 'web', 'sample-master-2', False, None, 'development-2'),
            ('sample-web-reviewer-b', 'reviewer', 'web', 'sample-master-2', False, None, 'development-2'),
            ('sample-vue3-reviewer', 'reviewer', 'vue3', 'sample-master-3', False, None, 'development-3')])
        # --running finds a worker in any window of its owner's tmux session: a
        # hidden worker lives in a window of its own.
        if shutil.which('tmux'):
            box = tmux_sandbox.Sandbox()
            env = box.env(self.env)
            try:
                running = json.loads(self.run_script('workspace-plan', '--json', '--running', env=env).stdout)
                self.assertEqual({x['running'] for x in running['workers']}, {False})
                subprocess.run(['tmux', 'new-session', '-d', '-s', 'sample-development-2', '-x', '120', '-y', '40'], env=env, check=True)
                subprocess.run(['tmux', 'new-window', '-d', '-t', 'sample-development-2:'], env=env, check=True)
                target = subprocess.run(['tmux', 'list-panes', '-s', '-t', 'sample-development-2', '-F', '#{window_index}.#{pane_index}'],
                                        env=env, capture_output=True, text=True, check=True).stdout.split()[-1]
                for option, value in [('@session_workspace_project', 'sample'), ('@session_workspace_pane', 'sample-web-executor-b'),
                                      ('@session_workspace_launched', '1')]:
                    subprocess.run(['tmux', 'set-option', '-p', '-t', 'sample-development-2:' + target, option, value], env=env, check=True)
                running = json.loads(self.run_script('workspace-plan', '--json', '--running', env=env).stdout)
                self.assertEqual({x['name']: x['running'] for x in running['workers']}, {
                    'sample-web-executor': False, 'sample-web-reviewer': False, 'sample-vue3-executor-v': False,
                    'sample-web-executor-b': True, 'sample-web-reviewer-b': False, 'sample-vue3-reviewer': False})
                one = json.loads(self.run_script('workspace-plan', 'development-2', '--json', '--running', env=env).stdout)
                self.assertEqual([x['name'] for x in one['workers']], ['sample-web-executor-b', 'sample-web-reviewer-b'])
            finally:
                box.teardown()
        text = self.run_script('workspace-plan').stdout
        self.assertIn('peers: session=development', text)
        self.assertIn('worker: checkout=web owner=sample-master shown', text)
        self.assertIn('worker: checkout=web owner=sample-master-2 hidden', text)

    def test_four_declarations_refused_before_now_validate(self):
        # One orchestrator with workers on several checkouts; two orchestrators
        # with workers on one checkout; two executor/reviewer pairs on one
        # checkout; and a second orchestrator session.
        self.write_instances({'orchestrators': [{'index': 2}], 'workers': [
            worker('web', 'executor', 'sample-master'), worker('web', 'reviewer', 'sample-master'),
            worker('vue3', 'executor', 'sample-master'), worker('vue3', 'reviewer', 'sample-master'),
            worker('web', 'executor', 'sample-master-2', 'two'), worker('web', 'reviewer', 'sample-master-2', 'two')]})
        self.assert_valid()
        plan = self.plan()
        self.assertEqual(len(plan['workers']), 6)
        # Two pairs on one checkout under one orchestrator.
        self.write_instances({'orchestrators': [], 'workers': [
            worker('web', 'executor', 'sample-master'), worker('web', 'reviewer', 'sample-master'),
            worker('web', 'executor', 'sample-master', 'two'), worker('web', 'reviewer', 'sample-master', 'two')]})
        self.assert_valid()

    # -- 4 -------------------------------------------------------------
    def snapshot(self):
        plan = self.plan()
        out = {}
        for s in plan['sessions']:
            for p in s['panes']:
                out[p['name']] = (json.dumps(p['scope_identity'], sort_keys=True), p['role'], p['cwd'], json.dumps(p['read_paths']),
                                  self.exports(p['name']))
        return out

    def test_no_drift_when_the_fleet_changes(self):
        self.write_instances(FLEET)
        before = self.snapshot()
        self.assertIn('sample-web-executor-b', before)
        grown = copy.deepcopy(FLEET)
        grown['orchestrators'].append({'index': 4})
        grown['workers'] += [worker('web', 'executor', 'sample-master-4'), worker('vue3', 'executor', 'sample-master', 'z')]
        self.write_instances(grown)
        after = self.snapshot()
        self.assertIn('sample-master-4', after)
        for name, values in before.items():
            self.assertEqual(after[name], values, name)
        shrunk = {'orchestrators': [{'index': 2}], 'workers': [w for w in FLEET['workers'] if w['owner'] != 'sample-master-3'][:3]
                  + [w for w in FLEET['workers'] if w['owner'] == 'sample-master-2'][:1]}
        self.write_instances(shrunk)
        after = self.snapshot()
        self.assertNotIn('sample-master-3', after)
        self.assertNotIn('sample-vue3-reviewer', after)
        for name, values in after.items():
            self.assertEqual(before[name], values, name)
        self.assertGreater(len(after), 6)
        # Control: a change to the checkout's own entry does change its
        # workers' pinned scope, and nobody else's.
        self.write_instances(FLEET)
        self.cfg['environments'][0]['executors'] = 'one'
        self.write()
        changed = self.snapshot()
        for name in ('sample-web-executor', 'sample-web-reviewer', 'sample-web-executor-b'):
            self.assertNotEqual(changed[name][0], before[name][0], name)
        for name in ('sample-master', 'sample-master-2', 'sample-vue3-executor-v', 'sample-vue3-reviewer'):
            self.assertEqual(changed[name][0], before[name][0], name)

    # -- 5 -------------------------------------------------------------
    def test_dropped_records(self):
        base = {'orchestrators': [{'index': 2}], 'workers': [worker('web', 'executor', 'sample-master-2')]}
        self.write_instances(base)
        reference = self.plan()
        self.assertEqual(len(reference['workers']), 1)
        good = worker('web', 'reviewer', 'sample-master-2')
        self.write_instances(dict(base, workers=base['workers'] + [good]))
        control = self.plan()
        self.assertNotEqual(control, reference)  # the control: a valid record does change the plan
        self.assertEqual(len(control['workers']), 2)
        bad_workers = {
            'bad label': worker('web', 'reviewer', 'sample-master-2', 'Bad Label'),
            'long label': worker('web', 'reviewer', 'sample-master-2', 'x' * 25),
            'unknown checkout': worker('nope', 'reviewer', 'sample-master-2'),
            'orchestrator role': worker('web', 'orchestrator', 'sample-master-2'),
            'unknown owner': worker('web', 'reviewer', 'ghost'),
            'a worker is not an owner': worker('web', 'reviewer', 'sample-web-executor'),
            'duplicate triple': worker('web', 'executor', 'sample-master-2'),
            'duplicate triple, other owner': worker('web', 'executor', 'sample-master'),
            'visible not boolean': dict(worker('web', 'reviewer', 'sample-master-2'), visible='yes'),
            'label not string': dict(worker('web', 'reviewer', 'sample-master-2'), label=3),
            'owner not string': dict(worker('web', 'reviewer', 'sample-master-2'), owner=['sample-master-2']),
            'missing label': {k: v for k, v in worker('web', 'reviewer', 'sample-master-2').items() if k != 'label'},
            'not an object': 'sample-web-reviewer',
        }
        for label, record in bad_workers.items():
            self.write_instances(dict(base, workers=base['workers'] + [record]))
            self.assert_valid()
            self.assertEqual(self.plan(), reference, label)
        for label, record in {'index as string': {'index': '3'}, 'index 1': {'index': 1}, 'index 1000': {'index': 1000},
                              'fractional index': {'index': 2.5}, 'no index': {}, 'not an object': 4}.items():
            self.write_instances(dict(base, orchestrators=base['orchestrators'] + [record]))
            self.assertEqual(self.plan(), reference, label)
        # Extra keys are dropped from an otherwise valid record, never passed on.
        self.write_instances(dict(base, workers=base['workers'] + [dict(good, evil='$(touch /tmp/x)', extra={'a': 1})],
                                  orchestrators=base['orchestrators'] + [{'index': 3, 'evil': 'x'}]))
        plan = self.plan()
        self.assertEqual([w['name'] for w in plan['workers']], ['sample-web-executor', 'sample-web-reviewer'])
        self.assertNotIn('evil', json.dumps(plan))
        self.assertEqual(len(plan['sessions']), 5)
        # A candidate passed to the loader (the engine checks one before it
        # writes it) is filtered by the same shape rules as the stored file.
        loader = 'source "$1/config.sh"; load_workspace_config_raw "$2" "" "$3"'
        for label in ('UPPER', 'x' * 25):
            candidate = json.dumps(dict(base, workers=base['workers'] + [worker('web', 'reviewer', 'sample-master-2', label)]))
            r = subprocess.run(['bash', '-c', loader, 'loader', str(HERE), str(self.path), candidate], env=self.env, capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual([p['name'] for s in json.loads(r.stdout)['sessions'] for p in s['panes'] if 'worker' in p], ['sample-web-executor'], label)
        candidate = json.dumps(dict(base, workers=base['workers'] + [worker('web', 'reviewer', 'sample-master-2', 'ok')]))
        r = subprocess.run(['bash', '-c', loader, 'loader', str(HERE), str(self.path), candidate], env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual([p['name'] for s in json.loads(r.stdout)['sessions'] for p in s['panes'] if 'worker' in p],
                         ['sample-web-executor', 'sample-web-reviewer-ok'])
        # A file that is not an object, or is a symlink, is ignored whole.
        self.instances_path().unlink()
        empty = self.plan()
        self.assertEqual(empty['workers'], [])
        self.write_instances('[{"index": 2}]')
        self.assertEqual(self.plan(), empty)
        self.write_instances('{not json')
        self.assertEqual(self.plan(), empty)
        real = self.state / 'valid-instances.json'
        real.write_text(json.dumps(base))
        self.instances_path().unlink()
        self.instances_path().symlink_to(real)
        self.assertEqual(self.plan(), empty)
        # Control: the same content in place of the symlink is used.
        self.instances_path().unlink()
        shutil.copy(real, self.instances_path())
        self.assertEqual(self.plan(), reference)

    # -- 6 -------------------------------------------------------------
    def test_engine_fields_in_the_raw_config_fail_to_load(self):
        message = 'sessions[].instance and panes[].worker are engine state; remove them from the config'
        self.assert_valid()
        raw = copy.deepcopy(self.cfg)
        raw['sessions'][0]['panes'].append({'name': 'sample-web-executor', 'role': 'executor', 'cwd': 'component-a',
                                            'launch': 'on_demand', 'worker': worker('web', 'executor', 'sample-master')})
        self.cfg = raw
        self.write()
        for script in ('validate-config', 'workspace-plan'):
            r = self.run_script(script)
            self.assertNotEqual(r.returncode, 0, script)
            self.assertIn(message, r.stdout + r.stderr, script)
        self.cfg = peers_config()
        self.cfg['sessions'][0]['instance'] = {'of': 'development', 'index': 1}
        self.write()
        r = self.run_script('validate-config')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(message, r.stdout + r.stderr)
        # The same holds for a schema-6 config without peers.
        del self.cfg['peers']
        self.write()
        self.assertIn(message, self.run_script('validate-config').stderr)
        self.cfg = peers_config()
        self.write()
        self.assert_valid()

    # -- 7 -------------------------------------------------------------
    def refused(self, mutate, expect, instances=None):
        cfg = peers_config()
        mutate(cfg)
        self.cfg = cfg
        self.write()
        if instances is not None:
            self.write_instances(instances)
        rc, out = self.validate()
        self.assertNotEqual(rc, 0, expect)
        self.assertIn(expect, out)
        # The control: the valid fixture passes with the same fleet.
        self.cfg = peers_config()
        self.write()
        self.assert_valid()

    def test_invalid_shapes_are_refused(self):
        def session(cfg, sid='development'):
            return next(s for s in cfg['sessions'] if s['id'] == sid)

        def set_(path, value):
            def go(cfg):
                node = cfg
                for key in path[:-1]:
                    node = node[key]
                node[path[-1]] = value
            return go

        def extra_session(pane, sid='extra'):
            def go(cfg):
                cfg['sessions'].append({'id': sid, 'name': 'sample-' + sid, 'panes': [pane]})
            return go

        cases = [
            ('peers is not an object', set_(['peers'], 'development'), 'expected an object at peers'),
            ('unknown peers key', set_(['peers', 'extra'], 1), 'unknown key in peers: extra'),
            ('missing peers.session', lambda c: c['peers'].pop('session'), 'missing required key in peers: session'),
            ('unknown session', set_(['peers', 'session'], 'nowhere'), 'peers.session must name a declared session'),
            ('limits zero', set_(['peers', 'limits'], {'orchestrators': 0}), 'peers.limits.orchestrators must be an integer >= 1'),
            ('limits string', set_(['peers', 'limits'], {'workers_per_orchestrator': '2'}), 'peers.limits.workers_per_orchestrator must be an integer >= 1'),
            ('limits unknown key', set_(['peers', 'limits'], {'orchestrator': 2}), 'unknown key in peers.limits: orchestrator'),
            ('harness off', set_(['harness'], {'enabled': False}), 'peers requires harness.enabled=true'),
            ('no environments', lambda c: c.pop('environments'), 'peers requires a non-empty environments array'),
            ('empty environments', set_(['environments'], []), 'peers requires a non-empty environments array'),
            ('second declared pane', lambda c: session(c)['panes'].append({'name': 'sample-master-b', 'role': 'master', 'cwd': '.'}),
             'must declare exactly one pane'),
            ('declared pane is not the orchestrator', set_(['sessions', 0, 'panes', 0, 'role'], 'service'),
             'must declare exactly one pane, with the orchestrator role'),
            ('orchestrator below the root', set_(['sessions', 0, 'panes', 0, 'cwd'], 'component-a'), 'must run at the workspace root'),
            ('optional orchestrator', set_(['sessions', 0, 'panes', 0, 'optional'], True), 'must not be optional'),
            ('orchestrator with launch', set_(['sessions', 0, 'panes', 0, 'launch'], 'always'), 'must not be optional and must not set launch'),
            ('split_tree layout', set_(['sessions', 0, 'layout'], {'kind': 'split_tree', 'nodes': [{'id': 'a'}], 'pane_order': ['sample-master']}),
             'must use the standard layout'),
            ('retain_layout', set_(['sessions', 0, 'retain_layout'], True), 'must not set retain_layout'),
            ('hand-declared second orchestrator', extra_session({'name': 'sample-master-two', 'role': 'master', 'cwd': '.'}),
             'must be the pane of the peers session development'),
            ('hand-declared executor', extra_session({'name': 'sample-web-executor', 'role': 'executor', 'cwd': 'component-a'}),
             'is not an engine-started worker of a configured environment'),
            ('hand-declared reviewer', extra_session({'name': 'sample-web-reviewer', 'role': 'reviewer', 'cwd': 'component-a'}),
             'is not an engine-started worker of a configured environment'),
            ('reserved session id', extra_session({'name': 'sample-extra', 'role': 'service', 'cwd': '.'}, 'development-2'),
             'reserved for peer orchestrator sessions'),
            ('environment orchestrator', set_(['environments', 0, 'orchestrator'], 'sample-master'), 'environments[].orchestrator is not allowed with peers'),
            ('shared_sessions', set_(['environments', 0, 'shared_sessions'], []), 'environments[].shared_sessions is not allowed with peers'),
            ('development not empty', set_(['environments', 0, 'development'], ['development']), 'environments[].development must be empty or absent'),
            ('executors value', set_(['environments', 0, 'executors'], 'two'), 'environments[].executors must be "one" or "many"'),
            ('unsafe branch', set_(['environments', 0, 'branch'], 'bad branch'), 'environment branch must be a safe literal branch name'),
            ('env group sets XDG_STATE_HOME', set_(['env', 'groups', 'dev', 'values'], {'XDG_STATE_HOME': '/tmp/x'}),
             'must not set XDG_STATE_HOME'),
        ]
        for label, mutate, expect in cases:
            with self.subTest(label):
                self.refused(mutate, expect)

        def target(cwd, work='main'):
            return {'id': 't', 'cwd': cwd, 'remote': 'origin', 'work_branch': work, 'release_branch': 'production', 'deploy': {'strategy': 'merge-no-ff-v1'}}

        def orchestration(*targets):
            return {'enabled': True, 'profile': 'reviewed-git-v1', 'targets': list(targets)}

        with self.subTest('orchestration target outside the environments'):
            self.refused(set_(['orchestration'], orchestration(target('component-c'))), 'orchestration targets must exactly bind an environment cwd')
        with self.subTest('branch rule still applies'):
            def lane(cfg):
                cfg['environments'][0]['branch'] = 'lane-a'
                cfg['orchestration'] = orchestration(target('component-a', 'main'))
            self.refused(lane, 'must use it as work_branch')
        # A fleet that no longer fits lowered limits still validates.
        with self.subTest('limits are not enforced on a running fleet'):
            self.cfg = peers_config()
            self.cfg['peers']['limits'] = {'orchestrators': 1, 'workers_per_orchestrator': 1}
            self.write()
            self.write_instances(FLEET)
            self.assert_valid()

    # -- 8 -------------------------------------------------------------
    def test_orchestration_targets(self):
        self.cfg['orchestration'] = {'enabled': True, 'profile': 'reviewed-git-v1', 'targets': [
            {'id': 'web', 'cwd': 'component-a', 'remote': 'origin', 'work_branch': 'main', 'release_branch': 'production', 'deploy': {'strategy': 'merge-no-ff-v1'}},
            {'id': 'vue3', 'cwd': 'component-b', 'remote': 'origin', 'work_branch': 'main', 'release_branch': 'production', 'deploy': {'strategy': 'merge-no-ff-v1'}}]}
        self.write()
        self.assert_valid()
        expected = [('web', 'web', str(self.root / 'component-a')), ('vue3', 'vue3', str(self.root / 'component-b'))]
        for instances in (None, FLEET):
            if instances:
                self.write_instances(instances)
            targets = self.plan()['orchestration']['targets']
            self.assertEqual([(t['id'], t['environment'], t['cwd']) for t in targets], expected)
            for t in targets:
                self.assertIsNone(t['executor'])
                self.assertIsNone(t['reviewer'])
                self.assertIsNone(t['orchestrator'])
                self.assertEqual(t['work_branch'], 'main')
        self.assertTrue(self.plan()['orchestration']['active'])

    # -- 9 -------------------------------------------------------------
    def labelled_config(self):
        envtests = module('envtests_for_peers', 'test-environments.py')
        cfg = envtests.config()
        for session in cfg['sessions']:
            if session['id'] == 'dev-web':
                for pane in session['panes']:
                    if pane['role'] in ('executor', 'reviewer'):
                        del pane['name']
        return cfg

    def test_label_is_refused_with_peers(self):
        r = self.run_script('workspace-label', 'web', 'auth')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('give the label when you start a worker, with --label', r.stderr)
        self.assertFalse((self.state / 'session-workspace/sample/labels.json').exists())
        # Controls: the same verb works on v5 and on v6 without peers.
        for version in (5, 6):
            self.cfg = self.labelled_config()
            self.cfg['schema_version'] = version
            for d in ['control-web', 'control-vue3']:
                (self.root / d).mkdir(exist_ok=True)
            self.write()
            r = self.run_script('workspace-label', 'web', 'auth', '--json')
            self.assertEqual(r.returncode, 0, (version, r.stderr))
            self.assertEqual(json.loads(r.stdout)['workers'],
                             ['harness-sample-web-executor-auth', 'harness-sample-web-reviewer-auth'])
            (self.state / 'session-workspace/harness-sample/labels.json').unlink()

    # -- 10 ------------------------------------------------------------
    def test_state_home_is_pinned_under_peers(self):
        self.assertIn('export XDG_STATE_HOME=%s; ' % self.state, self.exports('sample-master'))
        self.write_instances(FLEET)
        self.assertIn('export XDG_STATE_HOME=%s; ' % self.state, self.exports('sample-web-executor-b'))
        # With no XDG_STATE_HOME in the launcher, the default under HOME.
        home = self.root / 'home'
        env = dict(ENV, HOME=str(home))
        self.assertIn('export XDG_STATE_HOME=%s; ' % (home / '.local/state'), self.exports('sample-master', env=env))
        # A relative value is ignored, so panes in different cwds agree.
        env = dict(ENV, HOME=str(home), XDG_STATE_HOME='relative/state')
        self.assertIn('export XDG_STATE_HOME=%s; ' % (home / '.local/state'), self.exports('sample-master', env=env))
        # No alias can override it.
        self.cfg['env']['pane_name_aliases'] = ['XDG_STATE_HOME']
        self.write()
        out = self.exports('sample-master')
        self.assertEqual(out.count('export XDG_STATE_HOME='), 1)
        self.assertIn('export XDG_STATE_HOME=%s; ' % self.state, out)
        # A config value is refused (see test_invalid_shapes_are_refused); without
        # peers nothing is exported (see Differential).


class Differential(Base):
    """A schema-6 config without peers behaves as the same config at 5."""

    def setUp(self):
        super().setUp()
        for d in ['control-web', 'control-vue3']:
            (self.root / d).mkdir(exist_ok=True)

    def configs(self):
        envtests = module('envtests_for_peers', 'test-environments.py')
        shared = json.loads((FIXTURES / 'valid/shared-root-orchestrators-v5.json').read_text())
        synthetic = envtests.config()
        # Turn every guard pack on, so the guard scripts have something to say.
        synthetic['schema_version'] = 5
        synthetic['harness']['guards'] = json.loads((FIXTURES / 'valid/harness-v3.json').read_text())['harness']['guards']
        # A reviewer read grant, so reviewer-read-paths.py and the export run.
        (self.root / 'docs').mkdir(exist_ok=True)
        for s in synthetic['sessions']:
            for p in s['panes']:
                if p['name'] == 'web-reviewer':
                    p['read_paths'] = ['docs']
        # A dirty git root, so the root-health guard has something to report.
        subprocess.run(['git', 'init', '-q', str(self.root)], env=self.env, check=True)
        (self.root / 'untracked.txt').write_text('x\n')
        return [('shared-root', shared), ('synthetic', synthetic)]

    def identity(self, plan, pane):
        env = dict(self.env, SESSION_WORKSPACE_CONFIG=str(self.path), SESSION_WORKSPACE_HARNESS_MODE='enforce',
                   SESSION_WORKSPACE_PANE_NAME=pane['name'], SESSION_CHAT_PANE_NAME=pane['name'], KNOWLEDGE_PANE_NAME=pane['name'],
                   SESSION_WORKSPACE_ROLE=pane['role'], SESSION_WORKSPACE_PROJECT_ROOT=str(self.root),
                   SESSION_WORKSPACE_PANE_CWD=pane['cwd'],
                   SESSION_WORKSPACE_SCOPE_JSON=json.dumps(pane['scope_identity'], sort_keys=True, separators=(',', ':')))
        if plan['harness'].get('guards'):
            env['SESSION_WORKSPACE_GUARDS_JSON'] = json.dumps(plan['harness']['guards'], sort_keys=True, separators=(',', ':'))
        return env

    def capture(self):
        out = {}
        rc, text = self.validate()
        out['validate'] = (rc, text.replace('schema_version 5', 'schema_version N').replace('schema_version 6', 'schema_version N'))
        plan = self.plan()
        plan.pop('schema_version')
        out['plan'] = plan
        roles = plan['harness']['roles']
        panes = [p for s in plan['sessions'] for p in s['panes']]
        picked = {}
        for role in ('orchestrator', 'executor', 'reviewer'):
            picked[role] = next(p for p in panes if p['role'] == roles[role])
        for pane in panes:
            out['exports ' + pane['name']] = self.exports(pane['name'])
        hooks = {'allowed': {'tool_name': 'Bash', 'tool_input': {'command': 'git status'}},
                 'denied': {'tool_name': 'Bash', 'tool_input': {'command': 'git push origin main'}},
                 'denied-write': {'tool_name': 'Edit', 'tool_input': {'file_path': str(self.root / '.env'), 'old_string': 'a', 'new_string': 'b'}},
                 'unknown-tool': {'tool_name': 'Frobnicate', 'tool_input': {}}}
        decisions = set()
        for role, pane in picked.items():
            # The hook's own gate when the launcher set no mode.
            env = self.identity(plan, pane)
            del env['SESSION_WORKSPACE_HARNESS_MODE']
            r = subprocess.run(['bash', str(HERE / 'harness-hook.sh')], input=json.dumps(hooks['denied']), env=env, capture_output=True, text=True, timeout=60)
            out['hook %s no-mode' % role] = (r.returncode, r.stdout, r.stderr)
            env = self.identity(plan, pane)
            for label, payload in hooks.items():
                r = subprocess.run(['bash', str(HERE / 'harness-hook.sh')], input=json.dumps(payload), env=env, capture_output=True, text=True, timeout=60)
                out['hook %s %s' % (role, label)] = (r.returncode, r.stdout, r.stderr)
                decisions.add(r.returncode)
            for event in ('session', 'prompt'):
                r = subprocess.run(['bash', str(HERE / 'guard-lifecycle.sh'), '--event', event], env=env, capture_output=True, text=True, timeout=60)
                out['lifecycle %s %s' % (role, event)] = (r.returncode, r.stdout, r.stderr)
            r = subprocess.run(['bash', str(HERE / 'guard-health.sh')], input='{}', env=env, capture_output=True, text=True, timeout=60)
            out['health ' + role] = (r.returncode, r.stdout, r.stderr)
            r = subprocess.run(['bash', str(HERE / 'harness-status.sh'), '--config', str(self.path), '--json', '--probe'],
                               env=env, capture_output=True, text=True, timeout=120)
            status = json.loads(r.stdout) if r.stdout.strip().startswith('{') else r.stdout
            if isinstance(status, dict):
                status.pop('schema_version', None)
            out['status ' + role] = (r.returncode, status, r.stderr)
        out['_decisions'] = decisions
        return out

    def test_schema_6_without_peers_is_schema_5(self):
        for label, cfg in self.configs():
            captures = []
            for version in (5, 6):
                self.cfg = copy.deepcopy(cfg)
                self.cfg['schema_version'] = version
                self.write()
                captures.append(self.capture())
            five, six = captures
            # The captures are not vacuous: the config validates, the hook both
            # allows and refuses, and the guards speak.
            self.assertEqual(five['validate'][0], 0, (label, five['validate']))
            self.assertGreater(len(five['_decisions']), 1, label)
            self.assertNotEqual(five['hook orchestrator no-mode'][0], 0, label)
            if label == 'synthetic':
                self.assertTrue(all(v[1] for k, v in five.items() if k.startswith('lifecycle ')), label)
                self.assertIn('uncommitted', five['health orchestrator'][1])
                self.assertIn('SESSION_WORKSPACE_READ_PATHS_JSON=', five['exports web-reviewer'])
                self.assertIn('docs', five['exports web-reviewer'].split('SESSION_WORKSPACE_READ_PATHS_JSON=')[1].split(';')[0])
            self.assertEqual(sorted(five), sorted(six), label)
            for key in five:
                self.assertEqual(five[key], six[key], '%s: %s' % (label, key))
            self.assertFalse(any('XDG_STATE_HOME' in v for k, v in six.items() if k.startswith('exports ')), label)


if __name__ == '__main__':
    unittest.main()
