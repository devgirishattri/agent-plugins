#!/usr/bin/env python3
"""Synthetic v5 regressions; no paid calls, real agent launches or user stores."""
import copy
import io
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(os.environ.get('WORKSPACE_TEST_SCRIPTS', Path(__file__).resolve().parent))
ENV = {k: v for k, v in os.environ.items() if not k.startswith(('SESSION_', 'KNOWLEDGE_')) and k not in ('TMUX', 'TMUX_PANE')}


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    m = importlib.util.module_from_spec(spec)
    sys.modules[name] = m
    spec.loader.exec_module(m)
    return m


def config():
    cfg = json.loads((HERE / 'fixtures/valid/orchestration-v4.json').read_text())
    cfg['schema_version'] = 5
    cfg['roles']['service'] = {'runtime': 'shell'}
    cfg['roles']['master']['grants'] = ['messages', 'scheduler', 'contexts']
    cfg['sessions'] = [{'id': 'control', 'name': 'test-control', 'panes': [{'name': 'root', 'role': 'master', 'cwd': '.'}]}]
    cfg['environments'] = []
    cfg['orchestration']['targets'] = []
    cfg['behavior']['default_start_target'] = 'control'
    for name, cwd in [('web', 'component-a'), ('vue3', 'component-b')]:
        cfg['sessions'] += [dict(id='dev-'+name, name='test-dev-'+name, panes=[
            dict(name=name+'-master', role='master', cwd='control-'+name),
            dict(name=name+'-executor', role='executor', cwd=cwd),
            dict(name=name+'-reviewer', role='reviewer', cwd=cwd)]),
            dict(id='service-'+name, name='test-service-'+name, panes=[dict(name=name+'-server', role='service', cwd=cwd, command=['sleep', '600'])])]
        cfg['environments'].append(dict(id=name, cwd=cwd, development=['dev-'+name], services=['service-'+name], orchestrator=name+'-master'))
        cfg['orchestration']['targets'].append(dict(id=name, cwd=cwd, remote='origin', work_branch='main', release_branch='production', deploy={'strategy':'merge-no-ff-v1'}))
    return cfg


class Environments(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='wv5-', dir='/tmp')
        self.root = Path(self.tmp.name).resolve()
        for d in ['component-a', 'component-b', 'control-web', 'control-vue3', '.agent-workspace', '.tmp/scheduler/tasks', '.tmp/messages']:
            (self.root/d).mkdir(parents=True)
        self.cfg = config()
        self.path = self.root/'.agent-workspace/workspace.json'
        self.write()

    def tearDown(self):
        self.tmp.cleanup()

    def write(self):
        self.path.write_text(json.dumps(self.cfg))

    def run_script(self, name, *args, env=None):
        return subprocess.run(['bash', str(HERE/(name+'.sh')), *args, '--config', str(self.path)], env=env or ENV, capture_output=True, text=True, timeout=40)

    def plan(self):
        r = self.run_script('workspace-plan', '--json')
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)

    def context(self, name):
        policy = module('policy_v5', 'harness-policy.py')
        plan = self.plan()
        pane = next(p for s in plan['sessions'] for p in s['panes'] if p['name'] == name)
        env = dict(ENV, SESSION_WORKSPACE_CONFIG=str(self.path), SESSION_WORKSPACE_HARNESS_MODE='enforce', SESSION_WORKSPACE_PANE_NAME=name,
                   SESSION_WORKSPACE_ROLE=pane['role'], SESSION_WORKSPACE_PROJECT_ROOT=str(self.root), SESSION_WORKSPACE_PANE_CWD=pane['cwd'],
                   SESSION_WORKSPACE_SCOPE_JSON=json.dumps(pane['scope_identity'], sort_keys=True, separators=(',', ':')),
                   SESSION_WORKSPACE_GUARDS_JSON=json.dumps(plan['harness']['guards'],sort_keys=True,separators=(',', ':')))
        with patch.dict(os.environ, env, clear=True):
            ctx, failure = policy.load_context()
        self.assertIsNone(failure, failure)
        return policy, ctx, env

    def test_plan_and_custom_names(self):
        p = self.plan()
        self.assertEqual(len(p['sessions']), 5)
        self.assertEqual(p['orchestration']['targets'][1]['orchestrator'], 'vue3-master')
        r = self.run_script('workspace', 'plan', '--environment', 'vue3', '--services', '--json')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual([s['id'] for s in json.loads(r.stdout)['sessions']], ['service-vue3'])
        self.assertEqual(len(json.loads(r.stdout)['orchestration']['targets']), 2)

    def test_message_reads_use_full_validated_topology(self):
        for name in ('web-executor', 'web-reviewer'):
            policy, ctx, env = self.context(name)
            self.assertIn('vue3-master', ctx.plan_panes)
            self.assertIn(name, ctx.plan_panes)
            message = self.root / '.tmp/messages' / ('1790000000-123-abcdef12-vue3-master-to-' + name + '.md')
            message.write_text('Complete cross-environment task\n')
            message.chmod(0o600)
            self.assertEqual(policy.validate_bash(ctx, 'cat ' + str(message), {}), 'coordination.message_read')
            peer = self.root / '.tmp/messages/1790000000-123-abcdef12-vue3-master-to-vue3-executor.md'
            peer.write_text('Peer task\n')
            peer.chmod(0o600)
            with self.assertRaises(policy.PolicyFailure):
                policy.validate_bash(ctx, 'cat ' + str(peer), {})
            # Mutable chat identity cannot replace the pane selected by the plan.
            with patch.dict(os.environ, dict(env, SESSION_CHAT_PANE_NAME='vue3-executor'), clear=True):
                loaded, failure = policy.load_context()
            self.assertIsNone(loaded)
            self.assertEqual(failure.rule, 'identity.alias')

    def shared_root(self):
        # Read test data from this test file, even when testing the original engine.
        self.cfg = json.loads((Path(__file__).resolve().parent / 'fixtures/valid/shared-root-orchestrators-v5.json').read_text())
        self.write()

    def test_shared_root_plan_and_runtime(self):
        self.shared_root()
        self.assertEqual(self.run_script('validate-config').returncode, 0)
        for eid, ids, runtime in [('web', ['development', 'services'], 'claude'), ('vue3', ['vue3-development', 'vue3-services'], 'codex')]:
            result = self.run_script('workspace', 'plan', '--environment', eid, '--json')
            self.assertEqual(result.returncode, 0, result.stderr)
            plan = json.loads(result.stdout)
            self.assertEqual([s['id'] for s in plan['sessions']], ids)
            self.assertEqual(plan['sessions'][0]['panes'][0]['runtime']['name'], runtime)
            self.assertEqual(plan['sessions'][0]['panes'][0]['scope']['environment'], eid)
        plan = self.plan()
        self.assertEqual(plan['sessions'][2]['panes'][2]['runtime']['name'], 'claude')
        self.cfg['sessions'][0]['panes'][0].pop('runtime')
        self.write()
        self.assertEqual(self.plan()['sessions'][0]['panes'][0]['runtime']['name'], 'codex')

    def test_shared_root_policy(self):
        self.shared_root()
        p, ctx, env = self.context('sample-vue3-master')
        for target in ['sample-vue3-executor', 'sample-vue3-reviewer', 'sample-master']:
            p.require_route_target(ctx, target)
        for target in ['sample-executor', 'sample-reviewer']:
            with self.assertRaises(p.PolicyFailure): p.require_route_target(ctx, target)
        p.validate_edit(ctx, {'file_path': str(self.root/'notes.md')}, {})
        p.validate_bash(ctx, 'python3 -c pass', {})
        for child in ['component-a', 'component-b']:
            with self.assertRaises(p.PolicyFailure): p.validate_edit(ctx, {'file_path': str(self.root/child/'notes.md')}, {})
            with self.assertRaises(p.PolicyFailure): p.validate_bash(ctx, 'touch '+child+'/notes.md', {})
        with self.assertRaises(p.PolicyFailure): p.validate_bash(ctx, 'git push', {})
        p.validate_helper(ctx, 'session-scheduler', 'task-new.sh', ['Example', '--meta', 'environment=vue3'])
        for args in [['Example'], ['Example', '--meta', 'environment=web'], ['Example', '--meta', 'environment=root']]:
            with self.assertRaises(p.PolicyFailure): p.validate_helper(ctx, 'session-scheduler', 'task-new.sh', args)
        task = self.root/'.tmp/scheduler/tasks/example.json'
        task.write_text(json.dumps({'meta': {'environment': 'vue3'}}))
        p.validate_helper(ctx, 'session-scheduler', 'task-assign.sh', ['sample-vue3-executor', 'example', 'Do work'])
        with self.assertRaises(p.PolicyFailure): p.validate_helper(ctx, 'session-scheduler', 'task-assign.sh', ['sample-executor', 'example', 'Do work'])
        task.write_text(json.dumps({'meta': {'environment': 'web'}}))
        with self.assertRaises(p.PolicyFailure): p.validate_helper(ctx, 'session-scheduler', 'task-assign.sh', ['sample-vue3-executor', 'example', 'Do work'])
        p, worker, _ = self.context('sample-vue3-executor')
        p.require_route_target(worker, 'sample-vue3-master')
        with self.assertRaises(p.PolicyFailure): p.require_route_target(worker, 'sample-master')
        env['SESSION_WORKSPACE_SCOPE_JSON'] = '{}'
        with patch.dict(os.environ, env, clear=True):
            _, failure = p.load_context()
        self.assertEqual(failure.rule, 'identity.scope')

    def test_shared_root_start_and_selection(self):
        self.shared_root()
        # Start the exact topology on a private tmux server, suppressing external
        # agents/services. Runtime argv and browser commands are covered separately.
        with tempfile.TemporaryDirectory(prefix='w7t-', dir='/tmp') as socket_dir:
            env = dict(ENV, TMUX_TMPDIR=socket_dir, XDG_STATE_HOME=str(self.root/'state'), SESSION_WORKSPACE_STOP_GRACE_SECONDS='0')
            try:
                for eid in ['web', 'vue3']:
                    result = self.run_script('workspace', 'start', '--environment', eid, '--no-agents', '--no-services', '--no-attach', env=env)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                def panes():
                    return subprocess.check_output(['tmux', 'list-panes', '-t', '=shared-root-development', '-F', '#{pane_id}:#{pane_pid}'], env=env, text=True)
                before = panes()
                result = self.run_script('workspace', 'stop', '--environment', 'vue3', '--confirmed', env=env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(panes(), before)
            finally:
                subprocess.run(['tmux', 'kill-server'], env=env, capture_output=True)

    def test_shared_root_guards_and_argv(self):
        self.shared_root()
        # Use the same guard shape as existing v3 fixtures.
        guards = json.loads((HERE/'fixtures/valid/harness-v3.json').read_text())['harness']['guards']
        self.cfg['harness']['guards'] = guards
        self.write()
        p, ctx, _ = self.context('sample-vue3-master')
        p.validate_edit(ctx, {'file_path': str(self.root/'notes.md')}, {})
        with self.assertRaises(p.PolicyFailure): p.validate_bash(ctx, 'cd component-a', {})
        with self.assertRaises(p.PolicyFailure): p.validate_edit(ctx, {'file_path': str(self.root/'custom-secret.json')}, {})
        for name, runtime in [('sample-master','claude'), ('sample-vue3-master','codex'), ('sample-vue3-reviewer','claude')]:
            result = self.run_script('adapters', 'agent-argv', '--pane', name)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.split("\0")[0], runtime)

    def test_shared_root_health(self):
        self.shared_root()
        self.cfg['harness']['guards']['workspace_health'] = {'warn_root_dirty': True}
        self.write()
        (self.root/'.git').mkdir()
        plan = self.plan()
        health = module('health_v5', os.environ.get('WORKSPACE_TEST_GUARD_HEALTH', 'guard-health.py'))
        def run(argv, **kwargs):
            if argv[0] == 'bash':
                return subprocess.CompletedProcess(argv, 0, stdout=json.dumps(plan))
            return subprocess.CompletedProcess(argv, 0, stdout=' M notes.md\n')
        for name in ['sample-master', 'sample-vue3-master', 'sample-vue3-reviewer']:
            env = dict(ENV, SESSION_WORKSPACE_CONFIG=str(self.path), SESSION_WORKSPACE_PANE_NAME=name,
                       SESSION_WORKSPACE_GUARDS_JSON=json.dumps(plan['harness']['guards']))
            output = io.StringIO()
            with patch.dict(os.environ, env, clear=True), patch.object(health, 'run', side_effect=run), patch.object(sys, 'stdin', io.StringIO()), patch.object(sys, 'stdout', output):
                self.assertEqual(health.main([]), 0)
            self.assertEqual('uncommitted path' in output.getvalue(), name != 'sample-vue3-reviewer')
        # Existing control-directory coordinators remain silent.
        self.cfg['sessions'][0]['panes'][0]['cwd'] = 'control-web'
        self.write(); plan = self.plan()
        env['SESSION_WORKSPACE_PANE_NAME'] = 'sample-master'
        output = io.StringIO()
        with patch.dict(os.environ, env, clear=True), patch.object(health, 'run', side_effect=run), patch.object(sys, 'stdin', io.StringIO()), patch.object(sys, 'stdout', output):
            self.assertEqual(health.main([]), 0)
        self.assertEqual(output.getvalue(), '')

    def test_shared_root_browser_migration(self):
        self.shared_root()
        # A dedicated HOME ensures doctor cannot inspect the user's browser data.
        home = self.root/'home with space'
        home.mkdir()
        env = dict(ENV, HOME=str(home), XDG_STATE_HOME=str(home/'state'), XDG_CONFIG_HOME=str(home/'config'), XDG_CACHE_HOME=str(home/'cache'))
        result = self.run_script('workspace-plan', '--json', env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        profile = Path(json.loads(result.stdout)['browsers'][0]['profile_dir'])
        legacy = profile.parent.parent
        result = self.run_script('workspace-doctor', '--json', env=env)
        self.assertNotIn('profile_migration', result.stdout)
        legacy.mkdir(parents=True)
        result = self.run_script('workspace-doctor', '--json', env=env)
        self.assertIn('browser.services.profile_migration', result.stdout)
        self.assertIn('rsync -a --exclude=/sessions/', result.stdout)
        self.assertFalse(profile.exists())  # doctor never copies or creates it
        profile.mkdir(parents=True)
        result = self.run_script('workspace-doctor', '--json', env=env)
        self.assertNotIn('browser.services.profile_migration', result.stdout)

    def test_shared_root_invalid_controls(self):
        self.shared_root()
        self.plan()
        original = copy.deepcopy(self.cfg)
        for mutate, message in [
            (lambda c: c['sessions'][0]['panes'][0].update(runtime='missing'), 'unknown runtime'),
            (lambda c: c['sessions'][0]['panes'][1].update(runtime='shell'), 'shell runtime'),
            (lambda c: c['sessions'][1]['panes'][2].update(runtime='claude'), 'shell panes'),
            (lambda c: c['sessions'][0]['panes'][0].update(cwd='component-a'), 'overlap repositories'),
            (lambda c: (c['environments'][0].pop('orchestrator'), c['sessions'][0]['panes'].pop(0)), 'workers require'),
            (lambda c: c['environments'][1].update(orchestrator='sample-master'), 'unique pane'),
            (lambda c: c['sessions'][1]['panes'][0].update(command=['sleep','1']), 'cwd escapes'),
        ]:
            self.cfg = copy.deepcopy(original); mutate(self.cfg); self.write()
            result = self.run_script('validate-config')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stdout + result.stderr)

    def test_missing_structure_diagnostics(self):
        base = json.loads((HERE/'fixtures/valid/project-d.json').read_text())
        for version in range(1, 6):
            self.cfg = copy.deepcopy(base)
            self.cfg['schema_version'] = version
            self.write()
            self.plan()  # Valid control for every schema version.
            for missing, message in [('sessions', 'missing required key in top-level: sessions'), ('panes', 'missing required key in sessions.development: panes')]:
                with self.subTest(version=version, missing=missing):
                    self.cfg = copy.deepcopy(base)
                    self.cfg['schema_version'] = version
                    if missing == 'sessions':
                        del self.cfg['sessions']
                    else:
                        del self.cfg['sessions'][0]['panes']
                    self.write()
                    result = self.run_script('workspace-plan', '--json')
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(message, result.stderr)
                    self.assertNotIn('structural validation crashed', result.stderr)

    def test_scope_ownership_consistency(self):
        self.shared_root()
        policy, _, env = self.context('sample-vue3-master')
        plan = self.plan()
        pane = next(p for s in plan['sessions'] for p in s['panes'] if p['name'] == 'sample-vue3-master')
        def load():
            result = subprocess.CompletedProcess([], 0, stdout=json.dumps(plan), stderr='')
            with patch.dict(os.environ, env, clear=True), patch.object(policy.subprocess, 'run', return_value=result):
                return policy.load_context()
        ctx, failure = load()
        self.assertIsNotNone(ctx)
        self.assertIsNone(failure)
        pane['scope']['environment'] = 'web'
        # Match launch JSON to the deliberately inconsistent plan so the earlier
        # generic scope comparison passes and ownership itself is exercised.
        env['SESSION_WORKSPACE_SCOPE_JSON'] = json.dumps(pane['scope'], sort_keys=True, separators=(',', ':'))
        ctx, failure = load()
        self.assertIsNone(ctx)
        self.assertEqual(failure.rule, 'identity.scope')
        self.assertEqual(failure.reason, 'launcher environment does not match ownership')

    def test_mixed_orchestrator_routing(self):
        self.cfg['sessions'][1]['panes'][0]['cwd'] = '.'
        self.write()
        p, root_scoped, _ = self.context('web-master')
        for target in ['root', 'vue3-master', 'web-executor', 'web-reviewer']:
            p.require_route_target(root_scoped, target)
        with self.assertRaises(p.PolicyFailure): p.require_route_target(root_scoped, 'vue3-executor')
        p, confined, _ = self.context('vue3-master')
        for target in ['root', 'vue3-executor', 'vue3-reviewer']:
            p.require_route_target(confined, target)
        with self.assertRaises(p.PolicyFailure): p.require_route_target(confined, 'web-master')
        p, root, _ = self.context('root')
        for target in ['web-master', 'vue3-master']:
            p.require_route_target(root, target)

    def test_confined_orchestrator_plugin_reads_unchanged(self):
        p, ctx, _ = self.context('web-master')
        self.assertTrue(ctx.confined_orchestrator)
        p.validate_bash(ctx, 'cat README.md', {})
        # Executor selected-plugin reads do not expand local coordinator scope.
        with patch.object(p, 'selected_plugin_readable', return_value=True):
            with self.assertRaises(p.PolicyFailure) as caught:
                p.validate_bash(ctx, 'cat /outside/selected-plugin/SKILL.md', {})
            self.assertEqual(caught.exception.rule, 'executor.containment')

    def test_confined_orchestrator_bare_brace_pair(self):
        # A confined coordinator runs the executor floor, so it decides a bare
        # {} argument like '{}' and refuses a {} that zsh reads as a group.
        p, ctx, _ = self.context('web-master')
        self.assertTrue(ctx.confined_orchestrator)
        for command in ('find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort', "find . -type f -exec shasum -a 256 '{}' +"):
            self.assertIsNone(p.validate_bash(ctx, command, {}), command)
        for command, rule in (('find . -type f -exec shasum -a 256 {}.bak +', 'path.dynamic'),
                              ("if false; then {} else python3 -c 'print(1)'; fi", 'path.dynamic'),
                              ('find ../component-b -type f -exec cat {} +', 'executor.containment'),
                              ("find ../component-b -type f -exec cat '{}' +", 'executor.containment')):
            with self.subTest(command=command), self.assertRaises(p.PolicyFailure) as caught:
                p.validate_bash(ctx, command, {})
            self.assertEqual(caught.exception.rule, rule, command)

    def test_role_floor_probe_for_every_pane(self):
        # Each pane resolves its own floor (confined for control-directory
        # coordinators) and every built-in case is decided as expected.
        expected = {'root': 'orchestrator', 'web-master': 'confined_orchestrator', 'web-executor': 'executor', 'web-reviewer': 'reviewer'}
        for name, key in expected.items():
            p, _, env = self.context(name)
            with patch.dict(os.environ, env, clear=True):
                floor, probe = p.floor_document(), p.probe_document()
            self.assertEqual((floor['current'], probe['floor']), (key, key), name)
            self.assertTrue(probe['ran'] and probe['cases'], name)
            self.assertEqual([c for c in probe['cases'] if not c['ok']], [], name)
        status = self.run_script('harness-status')
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertIn('\n  master (confined) -> containment (', status.stdout)
        self.assertIn('\n  master -> child_write (', status.stdout)

    def test_orchestrator_gh_role_and_file_boundaries(self):
        for name in ('root', 'web-master'):
            p, ctx, env = self.context(name)
            (ctx.pane_cwd / 'body.json').write_text('{}')
            (ctx.pane_cwd / 'outside-gh').symlink_to(self.root / 'component-b', target_is_directory=True)
            commands = [
                ('gh pr list -R sample-org/component-a --json number --jq ".[] | .number?"', 'allow', 'orchestrator.gh_read'),
                ('gh api repositories/123/actions/runs -X GET -F per_page=5', 'allow', 'orchestrator.gh_read'),
                ('gh api repos/sample-org/component-a/issues -X GET --input body.json', 'allow', 'orchestrator.gh_read'),
                ('gh api repos/sample-org/component-a/issues -X GET -F body=@body.json', 'allow', 'orchestrator.gh_read'),
                ('gh api repositories/123/actions/runs -X DELETE', 'deny', 'orchestrator.gh_mutation'),
                ('gh pr merge 1 -R sample-org/component-a', 'deny', 'orchestrator.gh_mutation'),
                ('gh api repositories/123/actions/runs --input body.json', 'deny', 'orchestrator.gh_mutation'),
                ('gh api repositories/123/actions/runs -f per_page=5', 'deny', 'orchestrator.gh_mutation'),
                ('gh pr list -R sample-org/component-a | cat', 'deny', 'orchestrator.gh_unsupported'),
                ('gh alias-name -R sample-org/component-a', 'deny', 'orchestrator.gh_unsupported'),
                ('timeout 5 gh pr merge 1 -R sample-org/component-a', 'deny', 'orchestrator.gh_unsupported'),
                ('nice gh pr merge 1 -R sample-org/component-a', 'deny', 'orchestrator.gh_unsupported'),
                ('find . -maxdepth 0 -exec gh pr merge 1 -R sample-org/component-a \\;', 'deny', 'orchestrator.gh_unsupported'),
                ('echo gh', 'allow', 'allow'),
            ]
            if ctx.confined_orchestrator:
                commands += [
                    ('gh api repositories/123/actions/runs -X GET --input ../component-b/body.json', 'deny', 'executor.containment'),
                    ('gh api repositories/123/actions/runs -X GET -F body=@outside-gh/body.json', 'deny', 'executor.containment'),
                    ('gh pr list -R sample-org/component-a --head ../component-b', 'deny', 'executor.containment'),
                ]
            for command, decision, rule in commands:
                with self.subTest(pane=name, command=command), patch.dict(os.environ, env, clear=True):
                    result = p.evaluate(json.dumps({'tool_name': 'Bash', 'tool_input': {'command': command}})).normalized()
                    self.assertEqual((result['decision'], result['rule']), (decision, rule), result)
            if ctx.confined_orchestrator:
                with self.assertRaises(p.PolicyFailure) as caught:
                    p.validate_bash(ctx, 'gh pr list -R sample-org/component-a', {'workdir': str(self.root)})
                self.assertEqual(caught.exception.rule, 'executor.containment')
                nested = ctx.pane_cwd / 'nested'
                nested.mkdir()
                (nested / 'body.json').write_text('{}')
                (nested / 'outside').symlink_to(self.root / 'component-b', target_is_directory=True)
                command = 'gh api repositories/123/actions/runs -X GET --input body.json'
                self.assertEqual(p.validate_bash(ctx, command, {'workdir': str(nested)}), 'orchestrator.gh_read')
                with self.assertRaises(p.PolicyFailure) as caught:
                    p.validate_bash(ctx, command.replace('body.json', 'outside/body.json'), {'workdir': str(nested)})
                self.assertEqual(caught.exception.rule, 'executor.containment')
                with self.assertRaises(p.PolicyFailure) as caught:
                    p.validate_bash(ctx, command, {'workdir': str(nested), 'cwd': str(ctx.pane_cwd)})
                self.assertEqual(caught.exception.rule, 'executor.containment')

    def test_root_only_administration(self):
        operations = [('session-workspace', 'workspace-install.sh', []),
                      ('session-workspace', 'workspace-browser-config.sh', ['--browser', 'service-web']),
                      ('session-scheduler', 'tasks-clean.sh', [])]
        p, root, _ = self.context('root')
        for plugin, script, args in operations:
            p.validate_helper(root, plugin, script, args)
        p, confined, _ = self.context('web-master')
        for plugin, script, args in operations:
            with self.assertRaises(p.PolicyFailure) as caught: p.validate_helper(confined, plugin, script, args)
            self.assertEqual(caught.exception.rule, 'routing.scope')
        self.shared_root()
        for name in ['sample-master', 'sample-vue3-master']:
            p, scoped, _ = self.context(name)
            for plugin, script, args in operations:
                with self.assertRaises(p.PolicyFailure) as caught: p.validate_helper(scoped, plugin, script, args)
                self.assertEqual(caught.exception.rule, 'routing.scope')

    def test_browser_runtime_in_development(self):
        self.shared_root()
        browser = self.cfg['sessions'][1]['panes'].pop()
        self.cfg['sessions'][0]['panes'].append(browser)
        self.cfg['browsers'][0]['session_id'] = 'development'
        self.write(); self.plan()  # Shell browser is valid outside services.
        browser['runtime'] = 'claude'
        self.write()
        result = self.run_script('validate-config')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('browser pane must be a nonoptional service shell', result.stderr)

    def test_bad_bindings(self):
        self.plan()  # valid positive control
        original = copy.deepcopy(self.cfg)
        for mutate in [
            lambda c: c['environments'][1].update(id='web'),
            lambda c: c['environments'][1].update(services=['service-web']),
            lambda c: c['environments'][1].update(cwd='../outside'),
            lambda c: c['sessions'][1]['panes'][0].update(cwd='component-a'),
            lambda c: c['sessions'][1]['panes'][1].update(cwd='component-b'),
            lambda c: c['behavior'].update(stop_scope='all'),
            lambda c: c['environments'][0].update(unchecked=True),
        ]:
            self.cfg = copy.deepcopy(original)
            mutate(self.cfg)
            self.write()
            self.assertNotEqual(self.run_script('workspace-plan','--json').returncode, 0, self.cfg)

    def test_symlink_overlap_rejected(self):
        self.plan()
        (self.root/'alias').symlink_to(self.root/'component-a',target_is_directory=True)
        self.cfg['environments'][1]['cwd']='alias'
        self.write()
        self.assertNotEqual(self.run_script('workspace-plan','--json').returncode,0)

    def test_routes(self):
        p, local, _ = self.context('web-master')
        for peer in ['root','web-executor','web-reviewer']:
            p.require_route_target(local, peer)
        for peer in ['vue3-master','vue3-executor']:
            with self.assertRaises(p.PolicyFailure): p.require_route_target(local,peer)
        p, worker, _ = self.context('web-executor')
        p.require_route_target(worker,'web-master')
        with self.assertRaises(p.PolicyFailure): p.require_route_target(worker,'root')
        p, root, _ = self.context('root')
        p.require_route_target(root,'web-master')
        with self.assertRaises(p.PolicyFailure): p.require_route_target(root,'web-executor')

    def test_scope_drift(self):
        p, ctx, env = self.context('web-master')
        env['SESSION_WORKSPACE_SCOPE_JSON']='{}'
        with patch.dict(os.environ,env,clear=True):
            _, failure=p.load_context()
        self.assertEqual(failure.rule,'identity.scope')

    def add_lane(self, name, orchestrator=True):
        cwd = 'component-' + name
        (self.root/cwd).mkdir()
        panes = [dict(name=name+'-executor', role='executor', cwd=cwd), dict(name=name+'-reviewer', role='reviewer', cwd=cwd)]
        lane = dict(id=name, cwd=cwd, development=['dev-'+name], services=[])
        if orchestrator:
            (self.root/('control-'+name)).mkdir()
            panes.insert(0, dict(name=name+'-master', role='master', cwd='control-'+name))
            lane['orchestrator'] = name+'-master'
        self.cfg['sessions'].append(dict(id='dev-'+name, name='test-dev-'+name, panes=panes))
        self.cfg['environments'].append(lane)
        self.cfg['orchestration']['targets'].append(dict(id=name, cwd=cwd, remote='origin', work_branch='main', release_branch='production', deploy={'strategy':'merge-no-ff-v1'}))
        self.write()

    def load_with(self, policy, env):
        with patch.dict(os.environ, env, clear=True):
            return policy.load_context()

    def test_scope_pin_survives_other_lanes(self):
        plan = self.plan()
        pins = {p['name']: (p['scope'], p['scope_identity']) for s in plan['sessions'] for p in s['panes'] if p.get('scope')}
        self.assertEqual(pins['web-master'][1], {'environment': 'web', 'root_orchestrator': 'root', 'own': self.cfg['environments'][0]})
        self.assertEqual(pins['root'][1], {'environment': None, 'root_orchestrator': 'root', 'direct': []})
        contexts = {name: self.context(name) for name in ['root', 'web-master', 'web-executor', 'vue3-reviewer']}
        legacy = dict(contexts['web-master'][2], SESSION_WORKSPACE_SCOPE_JSON=json.dumps(pins['web-master'][0], sort_keys=True, separators=(',', ':')))
        _, failure = self.load_with(contexts['web-master'][0], legacy)
        self.assertIsNone(failure)  # a pane launched by 0.13.1 pinned the whole scope
        self.add_lane('c')
        for name, (policy, _, env) in contexts.items():
            _, failure = self.load_with(policy, env)
            self.assertIsNone(failure, name)
        root_ctx, _ = self.load_with(contexts['root'][0], contexts['root'][2])
        self.assertIn('c-master', root_ctx.route_peers)
        _, failure = self.load_with(contexts['web-master'][0], legacy)
        self.assertEqual(failure.rule, 'identity.scope')
        # A lane the root coordinates directly changes the root's own pin.
        self.add_lane('d', orchestrator=False)
        _, failure = self.load_with(contexts['root'][0], contexts['root'][2])
        self.assertEqual(failure.rule, 'identity.scope')
        _, failure = self.load_with(contexts['web-master'][0], contexts['web-master'][2])
        self.assertIsNone(failure)
        # A change to a pane's own environment still fails it closed.
        self.cfg['environments'][0]['services'] = []
        self.write()
        for name in ['web-master', 'web-executor']:
            _, failure = self.load_with(contexts[name][0], contexts[name][2])
            self.assertEqual(failure.rule, 'identity.scope', name)
        _, failure = self.load_with(contexts['vue3-reviewer'][0], contexts['vue3-reviewer'][2])
        self.assertIsNone(failure)

    def git(self, *args, cwd=None):
        result = subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', *args],
                                cwd=cwd or self.root, env=ENV, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)

    def set_branches(self, *branches):
        for env, target, branch in zip(self.cfg['environments'], self.cfg['orchestration']['targets'], branches):
            env['branch'] = target['work_branch'] = branch
        self.write()

    def make_lanes(self):
        """component-a and component-b as linked worktrees of app/ on lane-a and lane-b."""
        app = self.root/'app'
        app.mkdir()
        (app/'README.md').write_text('main\n')
        self.git('init', '-q', '-b', 'main', cwd=app)
        self.git('add', 'README.md', cwd=app)
        self.git('commit', '-q', '-m', 'init', cwd=app)
        for lane, cwd in [('a', 'component-a'), ('b', 'component-b')]:
            self.git('worktree', 'add', '-q', '-b', 'lane-'+lane, str(self.root/cwd), cwd=app)
        self.set_branches('lane-a', 'lane-b')
        return app

    def test_lanes_on_worktrees_protect_main_checkout(self):
        app = self.make_lanes()
        p, root, _ = self.context('root')
        self.assertIn(app.resolve(), root.child_roots)
        self.assertIn((app/'.git').resolve(), root.child_roots)
        for path in [app/'README.md', app/'.git/hooks/pre-commit', app/'.git/config', self.root/'component-a/README.md']:
            with self.assertRaises(p.PolicyFailure) as caught:
                p.validate_edit(root, {'file_path': str(path)}, {})
            self.assertEqual(caught.exception.rule, 'orchestrator.child_write', path)
        for command in ['touch app/x', 'rm -f app/.git/hooks/pre-push']:
            with self.assertRaises(p.PolicyFailure) as caught:
                p.validate_bash(root, command, {})
            self.assertEqual(caught.exception.rule, 'orchestrator.child_write', command)
        p.validate_edit(root, {'file_path': str(self.root/'notes.md')}, {})
        p.validate_bash(root, 'git -C app status', {})
        p, executor, _ = self.context('web-executor')
        with self.assertRaises(p.PolicyFailure):
            p.validate_edit(executor, {'file_path': str(app/'.git/hooks/pre-commit')}, {})

    def test_worktrees_of_the_project_root(self):
        (self.root/'README.md').write_text('main\n')
        self.git('init', '-q', '-b', 'main')
        self.git('add', 'README.md')
        self.git('commit', '-q', '-m', 'init')
        self.git('worktree', 'add', '-q', '-b', 'lane-a', str(self.root/'component-a'))
        self.set_branches('lane-a')
        p, root, _ = self.context('root')
        self.assertIn((self.root/'.git').resolve(), root.child_roots)
        self.assertNotIn(self.root, root.child_roots)  # the root orchestrator's own checkout
        with self.assertRaises(p.PolicyFailure) as caught:
            p.validate_edit(root, {'file_path': str(self.root/'.git/hooks/pre-commit')}, {})
        self.assertEqual(caught.exception.rule, 'orchestrator.child_write')
        p.validate_edit(root, {'file_path': str(self.root/'README.md')}, {})
        p.validate_bash(root, 'git status', {})
        # The root coordinator's own checkout holds lane-a's ref: it may read
        # and merge it, never write it.
        for command in ['git merge lane-a', 'git log --oneline lane-a', 'git diff main lane-a', 'git branch --list',
                        'git checkout lane-a -- README.md', 'git branch side', 'git fetch origin lane-a']:
            p.validate_bash(root, command, {})
        for command in ['git branch -D lane-a', 'git branch -f lane-a main', 'git update-ref -d refs/heads/lane-a',
                        'git fetch origin main:lane-a', 'git checkout lane-a', 'git switch -C lane-a', 'git rebase main lane-a',
                        'git status\ngit branch -m lane-a gone', 'git -c x.y=z branch -D lane-a']:
            with self.assertRaises(p.PolicyFailure) as caught:
                p.validate_bash(root, command, {})
            self.assertEqual(caught.exception.rule, 'git.lane_ref', command)

    def test_lane_branch_validation(self):
        app = self.root/'app'
        app.mkdir()
        self.git('init', '-q', '-b', 'main', cwd=app)
        self.git('commit', '-q', '--allow-empty', '-m', 'init', cwd=app)
        for lane, cwd in [('a', 'component-a'), ('b', 'component-b')]:
            self.git('worktree', 'add', '-q', '-b', 'lane-'+lane, str(self.root/cwd), cwd=app)
        def error(*branches, mutate=None):
            for env in self.cfg['environments']:
                env.pop('branch', None)
            self.set_branches(*branches)
            if mutate:
                mutate(self.cfg)
                self.write()
            result = self.run_script('workspace-plan', '--json')
            return result.returncode, result.stderr
        code, err = error()
        self.assertNotEqual(code, 0)
        self.assertIn('environments that share a git repository must each declare branch', err)
        self.assertIn('must each declare branch', error('lane-a')[1])
        self.assertIn('environment branches must be unique', error('lane-a', 'lane-a')[1])
        for bad in ['HEAD', '../x', 'a..b', 'x/.hidden', 'x.lock', 'x/', '-x', 'a b']:
            self.assertIn('safe literal branch name', error(bad, 'lane-b')[1], bad)
        def other_work(cfg):
            cfg['orchestration']['targets'][0]['work_branch'] = 'main'
        self.assertIn('must use it as work_branch', error('lane-a', 'lane-b', mutate=other_work)[1])
        self.assertEqual(error('lane-a', 'lane-b')[0], 0)
        self.assertEqual(self.plan()['sessions'][1]['panes'][1]['scope_identity']['own']['branch'], 'lane-a')

    def test_plain_checkouts_need_no_branch(self):
        for cwd in ['component-a', 'component-b']:
            self.git('init', '-q', '-b', 'main', cwd=self.root/cwd)
        self.plan()

    def test_lane_executor_git_floor(self):
        self.make_lanes()
        p, ctx, _ = self.context('web-executor')
        self.assertEqual(ctx.lane_branch, 'lane-a')
        allowed = [
            'git status', 'git log --oneline lane-b', 'git diff lane-b', 'git add README.md', 'git commit -m "lane work"',
            'git push origin lane-a', 'git push -u origin HEAD', 'git push origin HEAD:lane-a', 'git push --dry-run origin refs/heads/lane-a:refs/heads/lane-a',
            'git fetch origin', 'git fetch --prune origin main', 'git fetch origin main:refs/remotes/origin/main', 'git pull --ff-only origin main',
            'git merge main', 'git rebase main', 'git rebase --continue', 'git reset --hard HEAD', 'git cherry-pick main',
            'git checkout -- README.md', 'git checkout README.md', 'git checkout main -- README.md', 'git restore --source lane-b README.md',
            'git switch --detach main', 'git checkout --detach main', 'git switch lane-a', 'git checkout -B lane-a main', 'git switch -c lane-a',
            'git branch -f lane-a HEAD', 'git branch -u origin/lane-a', 'git branch --list', 'git branch', 'git tag -l', 'git stash list',
            'git worktree list', 'git config --get user.name', 'git config user.name', 'git remote -v', 'git -C . status',
            'git --no-pager log -1', 'timeout 5 git status', 'git lfs pull', 'git symbolic-ref --short HEAD', 'git update-ref refs/heads/lane-a HEAD',
            'git --version', 'git commit -m "explain GIT_DIR=x"',
        ]
        for command in allowed:
            p.validate_bash(ctx, command, {})
        refused = [
            'git branch -f lane-b HEAD', 'git branch -D lane-b', 'git branch -d lane-a', 'git branch -m lane-b gone', 'git branch side', 'git branch -dr origin/lane-b',
            'git update-ref refs/heads/lane-b HEAD', 'git update-ref -d refs/heads/lane-a', 'git push origin lane-b', 'git push origin HEAD:lane-b',
            'git push origin :lane-a', 'git push origin +lane-a', 'git push --force origin lane-a', 'git push --force-with-lease origin lane-a',
            'git push -f origin lane-a', 'git push --all origin', 'git push --tags origin', 'git push --mirror origin', 'git push origin', 'git push',
            'git push --delete origin lane-a', 'git push https://example.invalid/x.git lane-a', 'git push origin lane-a tag-v1',
            'git fetch origin main:lane-b', 'git fetch origin +main:lane-a', 'git fetch --refmap=x origin', 'git fetch --update-head-ok origin main:lane-a',
            'git pull origin main:lane-b', 'git checkout lane-b', 'git checkout main', 'git checkout -b side', 'git checkout -B lane-b',
            'git checkout -fb side', 'git switch main', 'git switch -c side', 'git switch -', 'git checkout --ignore-other-worktrees lane-b',
            'git checkout --track origin/lane-b', 'git checkout main --', 'git rebase main lane-b', 'git rebase --update-refs main',
            'git tag v1', 'git stash', 'git stash pop', 'git worktree remove component-b', 'git worktree add ../x',
            'git config user.email x@example.invalid', 'git config core.hooksPath hooks', 'git config --global user.name x',
            'git remote set-url origin x', 'git reflog expire --all', 'git gc', 'git -c core.hooksPath=x commit -m y',
            'git --git-dir=../app/.git branch -D lane-b', 'GIT_DIR=../app/.git git branch -D lane-b',
            'export GIT_DIR=x', 'env GIT_COMMON_DIR=x git status', 'GIT_INDEX_FILE=x; export GIT_INDEX_FILE',
            'timeout 5 git push origin lane-b', 'find . -name x -exec git branch -D lane-b \\;', 'git co lane-b',
            'git submodule update --init', 'git lfs install', 'git notes add -m x', 'git symbolic-ref HEAD refs/heads/lane-b',
            'git bisect reset main', 'git status\ngit branch -D lane-b', 'git filter-branch -- --all',
        ]
        for command in refused:
            with self.assertRaises(p.PolicyFailure, msg=command) as caught:
                p.validate_bash(ctx, command, {})
            self.assertEqual(caught.exception.rule, 'git.lane_ref', command)
        self.assertIn('lane-a', str(caught.exception))
        # HEAD-moving commands need the lane branch (or a detached HEAD) checked out.
        self.git('switch', '-q', '-c', 'other', cwd=self.root/'component-a')
        for command in ['git commit -m x', 'git merge main', 'git reset --hard HEAD', 'git pull origin main', 'git branch -u origin/main']:
            with self.assertRaises(p.PolicyFailure) as caught:
                p.validate_bash(ctx, command, {})
            self.assertEqual(caught.exception.rule, 'git.lane_ref', command)
            self.assertIn('this checkout is on other', caught.exception.reason)
        p.validate_bash(ctx, 'git switch lane-a', {})
        self.git('switch', '-q', '--detach', cwd=self.root/'component-a')
        p.validate_bash(ctx, 'git commit -m x', {})
        # Another lane's executor is held to its own branch; the reviewer and
        # an environment orchestrator keep their read-only Git.
        p, other, _ = self.context('vue3-executor')
        p.validate_bash(other, 'git push origin lane-b', {})
        with self.assertRaises(p.PolicyFailure) as caught:
            p.validate_bash(other, 'git push origin lane-a', {})
        self.assertEqual(caught.exception.rule, 'git.lane_ref')
        p, master, _ = self.context('web-master')
        self.assertEqual(master.lane_branches, frozenset({'lane-a', 'lane-b'}))
        self.assertEqual(master.lane_branch, '')

    def test_local_edit_and_shell(self):
        p, ctx, _ = self.context('web-master')
        p.validate_edit(ctx,{'file_path':str(self.root/'control-web/plan.md')},{})
        p.validate_bash(ctx,'git status',{})
        for path in ['.agent-workspace/workspace.json','component-a/a.txt','component-b/a.txt','control-vue3/a.txt']:
            with self.assertRaises(p.PolicyFailure): p.validate_edit(ctx,{'file_path':str(self.root/path)},{})
        for command in ['git push','touch ../control-vue3/a.txt','tmux send-keys -t vue3-executor hi','python3 -c pass']:
            with self.assertRaises(p.PolicyFailure): p.validate_bash(ctx,command,{})

    def test_lifecycle_scope(self):
        p,ctx,_=self.context('web-master')
        p.validate_helper(ctx,'session-workspace','workspace-start.sh',['service-web'])
        p.validate_helper(ctx,'session-workspace','workspace.sh',['status','--environment','web'])
        for script,args in [('workspace-start.sh',['all']),('workspace-stop.sh',['service-vue3','--confirmed']),('workspace.sh',['restart','--environment','vue3'])]:
            with self.assertRaises(p.PolicyFailure):p.validate_helper(ctx,'session-workspace',script,args)

    def test_free_shell_lifecycle_scope(self):
        # The `workspace` dispatcher on PATH, workspace.sh and a lifecycle
        # script run by name get the same session scope as the reviewed helper.
        p, ctx, _ = self.context('web-master')
        for command in ['workspace start service-web', 'workspace stop service-web --confirmed', 'workspace status',
                        'workspace plan --json', 'workspace-environment.sh stop --environment web --services --confirmed']:
            p.validate_bash(ctx, command, {})
        for command in ['workspace stop service-vue3 --confirmed', 'workspace start service-vue3',
                        'workspace restart dev-vue3', 'workspace reconcile service-vue3 --apply',
                        'bash workspace.sh stop service-vue3 --confirmed', 'workspace-stop.sh service-vue3 --confirmed',
                        'bash /opt/x/workspace-start.sh control', 'workspace start --all', 'workspace start',
                        'workspace stop --environment vue3 --services --confirmed', 'workspace install',
                        'workspace-environment.sh stop --environment vue3 --services --confirmed',
                        'ls && workspace start service-vue3']:
            with self.assertRaises(p.PolicyFailure, msg=command) as caught:
                p.validate_bash(ctx, command, {})
            self.assertEqual(caught.exception.rule, 'routing.scope', command)
        p, root, _ = self.context('root')
        for command in ['workspace stop service-vue3 --confirmed', 'workspace start service-web', 'workspace install']:
            p.validate_bash(root, command, {})
        self.shared_root()
        p, scoped, _ = self.context('sample-vue3-master')
        p.validate_bash(scoped, 'workspace stop vue3-services --confirmed', {})
        for command in ['workspace stop services --confirmed', 'workspace stop development --confirmed']:
            with self.assertRaises(p.PolicyFailure, msg=command) as caught:
                p.validate_bash(scoped, command, {})
            self.assertEqual(caught.exception.rule, 'routing.scope', command)

    def add_shared_services(self):
        self.cfg['sessions'].append(dict(id='shared', name='test-shared', panes=[
            dict(name='db', role='service', cwd='.', command=['sleep', '600']),
            dict(name='mail', role='service', cwd='.', command=['sleep', '600'])]))
        self.cfg['environments'][0]['shared_sessions'] = ['shared']
        self.write()

    def test_shared_sessions_validation(self):
        self.add_shared_services()
        plan = self.plan()
        self.assertEqual(plan['environments'][0]['shared_sessions'], ['shared'])
        web = next(p for s in plan['sessions'] for p in s['panes'] if p['name'] == 'web-master')
        self.assertEqual(web['scope_identity']['own']['shared_sessions'], ['shared'])
        original = copy.deepcopy(self.cfg)
        for mutate, message in [
            (lambda c: c['environments'][0].update(shared_sessions=['service-vue3']), 'no environment owns'),
            (lambda c: c['environments'][0].update(shared_sessions=['service-web']), 'no environment owns'),
            (lambda c: c['environments'][0].update(shared_sessions=['missing']), 'no environment owns'),
            (lambda c: c['environments'][0].update(shared_sessions=['control']), 'only service shell panes'),
            (lambda c: c['environments'][0].update(shared_sessions=['shared', 'shared']), 'unique session ids'),
            (lambda c: c['environments'][0].update(shared_sessions='shared'), 'unique session ids'),
            (lambda c: c['sessions'][-1]['panes'][0].update(runtime='claude'), 'only service shell panes'),
        ]:
            self.cfg = copy.deepcopy(original)
            mutate(self.cfg)
            self.write()
            result = self.run_script('workspace-plan', '--json')
            self.assertNotEqual(result.returncode, 0, message)
            self.assertIn(message, result.stderr)
        self.cfg = copy.deepcopy(original)
        self.cfg['environments'][1]['shared_sessions'] = ['shared']
        self.write()
        self.plan()  # several environments may share one session
        self.add_lane('d', orchestrator=False)  # coordinated by the root
        self.cfg['environments'][-1]['shared_sessions'] = ['shared']
        self.write()
        result = self.run_script('workspace-plan', '--json')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('shared_sessions requires an environment orchestrator', result.stderr)

    def test_shared_services_start_only(self):
        self.add_shared_services()
        p, web, _ = self.context('web-master')
        self.assertEqual(web.shared_session_ids, frozenset(['shared']))
        for args in (['shared', '--pane', 'db'], ['shared', '--pane', 'db', '--pane', 'mail']):
            p.validate_helper(web, 'session-workspace', 'workspace-start.sh', args)
        p.validate_helper(web, 'session-workspace', 'workspace.sh', ['start', 'shared', '--pane', 'db'])
        p.validate_bash(web, 'workspace start shared --pane db', {})
        refused = [('workspace-stop.sh', ['shared', '--pane', 'db', '--confirmed']), ('workspace-stop.sh', ['shared', '--confirmed']),
                   ('workspace-restart.sh', ['shared']), ('workspace-reconcile.sh', ['shared', '--apply'])]
        for script, args in refused:
            with self.assertRaises(p.PolicyFailure, msg=args) as caught:
                p.validate_helper(web, 'session-workspace', script, args)
            self.assertEqual(caught.exception.rule, 'routing.shared_stop', (script, args))
        for command in ['workspace stop shared --pane db --confirmed', 'workspace stop shared --confirmed',
                        'workspace restart shared', 'bash /opt/x/workspace-stop.sh shared --confirmed']:
            with self.assertRaises(p.PolicyFailure, msg=command) as caught:
                p.validate_bash(web, command, {})
            self.assertEqual(caught.exception.rule, 'routing.shared_stop', command)
        for check in (lambda: p.validate_helper(web, 'session-workspace', 'workspace-start.sh', ['shared']),
                      lambda: p.validate_bash(web, 'workspace start shared', {})):
            with self.assertRaises(p.PolicyFailure) as caught:
                check()
            self.assertEqual(caught.exception.rule, 'routing.scope')
        with self.assertRaises(p.PolicyFailure) as caught:
            p.validate_helper(web, 'session-workspace', 'workspace-start.sh', ['shared', '--pane', 'nope'])
        self.assertEqual(caught.exception.rule, 'helper.argv')
        # An environment that does not list the session cannot start it, and
        # workers never get the shared set.
        p, vue3, _ = self.context('vue3-master')
        self.assertEqual(vue3.shared_session_ids, frozenset())
        with self.assertRaises(p.PolicyFailure) as caught:
            p.validate_helper(vue3, 'session-workspace', 'workspace-start.sh', ['shared', '--pane', 'db'])
        self.assertEqual(caught.exception.rule, 'routing.scope')
        p, executor, _ = self.context('web-executor')
        self.assertEqual(executor.shared_session_ids, frozenset())
        # The root coordinator and the user keep full control.
        p, root, _ = self.context('root')
        for script, args in refused + [('workspace-start.sh', ['shared'])]:
            p.validate_helper(root, 'session-workspace', script, args)

    def test_scheduler_scope(self):
        p,ctx,_=self.context('web-master')
        p.validate_helper(ctx,'session-scheduler','task-new.sh',['Example','--meta','environment=web'])
        with self.assertRaises(p.PolicyFailure):p.validate_helper(ctx,'session-scheduler','task-new.sh',['Example','--meta','environment=vue3'])
        task=self.root/'.tmp/scheduler/tasks/example.json'
        task.write_text(json.dumps({'meta':{'environment':'web'}}))
        p.validate_helper(ctx,'session-scheduler','task-assign.sh',['web-executor','example','Do work'])
        task.write_text(json.dumps({'meta':{'environment':'vue3'}}))
        with self.assertRaises(p.PolicyFailure):p.validate_helper(ctx,'session-scheduler','task-assign.sh',['web-executor','example','Do work'])

    def test_coordinator_tasks_use_messages(self):
        p,ctx,_=self.context('root')
        with self.assertRaises(p.PolicyFailure):p.task_assign(ctx,'task-assign.sh',['web-master','example','Do work'])
        p,ctx,_=self.context('web-master')
        p.task_assign(ctx,'task-assign.sh',['web-executor','example','Do work'])

    def test_browser_profiles(self):
        self.cfg['browsers']=[]
        for name,port in [('web',19222),('vue3',19223)]:
            s=next(s for s in self.cfg['sessions'] if s['id']=='service-'+name)
            s['panes'].append(dict(name=name+'-browser',role='service',cwd='component-a' if name=='web' else 'component-b'))
            self.cfg['browsers'].append(dict(session_id=s['id'],pane_name=name+'-browser',port=port,chrome_program='/bin/echo',mcp_package='chrome-devtools-mcp@0.20.0',mcp_server_name='browser-'+name))
        self.write();p=self.plan()
        self.assertNotEqual(p['browsers'][0]['profile_dir'],p['browsers'][1]['profile_dir'])
        for b in p['browsers']:
            pane=next(pane for s in p['sessions'] for pane in s['panes'] if pane['name']==b['pane_name'])
            self.assertIn('--user-data-dir='+b['profile_dir'],pane['command'])
        self.cfg['browsers'][1]['chrome_program']='/no-such-browser';self.write()
        checked=self.run_script('workspace-doctor','--json')
        self.assertIn('browser.service-vue3.program',checked.stdout)
        self.assertIn('/no-such-browser',checked.stdout)
        self.cfg['browsers'][1]['port']=19222;self.write()
        self.assertNotEqual(self.run_script('workspace-plan','--json').returncode,0)

    def removed_form_message(self, mutate):
        """Plan and validate must both reject a removed form with the migration message."""
        self.plan()
        validated=self.run_script('validate-config','--json')
        self.assertEqual(validated.returncode,0,validated.stderr+validated.stdout)
        mutate();self.write()
        for name in ['workspace-plan','validate-config']:
            r=self.run_script(name,'--json')
            self.assertNotEqual(r.returncode,0,name+' accepted a removed form')
            self.assertIn('removed in session-workspace 0.12.0',r.stdout+r.stderr,name)
        return self.run_script('workspace-plan','--json')

    def test_removed_integrations_rejected(self):
        r=self.removed_form_message(lambda:self.cfg.update(integrations={'jev':{'enabled':False}}))
        self.assertIn('integrations (Jev) was removed in session-workspace 0.12.0; delete it from the config',r.stdout+r.stderr)
        self.cfg.pop('integrations');self.write();self.plan()

    def test_removed_environment_jev_rejected(self):
        r=self.removed_form_message(lambda:self.cfg['environments'][0].update(jev=True))
        self.assertIn('environments[].jev was removed in session-workspace 0.12.0; delete it from the config',r.stdout+r.stderr)
        del self.cfg['environments'][0]['jev'];self.write();self.plan()

    def test_removed_integrations_pin_rejected(self):
        r=self.removed_form_message(lambda:self.cfg['stores'].setdefault('pin',[]).append('integrations'))
        self.assertIn('"integrations" in stores.pin was removed in session-workspace 0.12.0; delete it from the config',r.stdout+r.stderr)
        self.cfg['stores']['pin'].remove('integrations');self.write();self.plan()

    def test_service_port_owner_control(self):
        probe=module('port_owner_v5',os.environ.get('SERVICE_PORTS_TEST_MODULE','service-ports.py'))
        p=self.plan();s=p['sessions'][2];pane=s['panes'][0]
        with socket.socket() as listener:
            listener.bind(('127.0.0.1',0));listener.listen()
            pane['port']=listener.getsockname()[1]
            owned=subprocess.CompletedProcess([],0,stdout=p['project']['id']+'\t'+pane['name']+'\t0\tshell\n')
            with patch.object(probe.subprocess,'run',return_value=owned):
                self.assertEqual(probe.preflight(p,s['id']),0)
            foreign=subprocess.CompletedProcess([],0,stdout='other-project\t'+pane['name']+'\t0\tshell\n')
            with patch.object(probe.subprocess,'run',return_value=foreign):
                self.assertEqual(probe.preflight(p,s['id']),1)

    def test_occupied_service_port(self):
        env=dict(ENV,XDG_STATE_HOME=str(self.root/'state'))
        with socket.socket() as listener:
            listener.bind(('127.0.0.1',0));listener.listen()
            self.cfg['sessions'][2]['panes'][0]['port']=listener.getsockname()[1];self.write()
            self.plan()  # structural positive control: a unique configured port
            r=self.run_script('workspace-start','service-web','--no-attach',env=env)
            self.assertNotEqual(r.returncode,0)
            self.assertIn('service port occupied',r.stderr)
        probe=module('ports_v5','service-ports.py')
        self.assertFalse(probe.listening(self.cfg['sessions'][2]['panes'][0]['port']))

    def test_live_session_isolation(self):
        # Private tmux server. Never touch the inherited/default user server.
        socket_tmp=tempfile.TemporaryDirectory(prefix='w5t-',dir='/tmp')
        env=dict(ENV,TMUX_TMPDIR=socket_tmp.name,XDG_STATE_HOME=str(self.root/'state'),SESSION_WORKSPACE_STOP_GRACE_SECONDS='0')
        try:
            for target in ['control','dev-web','service-web','dev-vue3','service-vue3']:
                r=self.run_script('workspace-start',target,'--no-agents','--no-attach',env=env)
                self.assertEqual(r.returncode,0,r.stderr+r.stdout)
            def panes(session):
                return subprocess.check_output(['tmux','list-panes','-t','='+session,'-F','#{pane_id}:#{pane_pid}'],env=env,text=True)
            before=(panes('test-control'),panes('test-dev-web'),panes('test-service-web'))
            r=self.run_script('workspace','restart','--environment','vue3','--services','--no-agents','--no-attach',env=env)
            self.assertEqual(r.returncode,0,r.stderr+r.stdout)
            self.assertEqual(before,(panes('test-control'),panes('test-dev-web'),panes('test-service-web')))
            r=self.run_script('workspace','stop','--environment','vue3','--confirmed',env=env)
            self.assertEqual(r.returncode,0,r.stderr+r.stdout)
            self.assertEqual(before,(panes('test-control'),panes('test-dev-web'),panes('test-service-web')))
        finally:
            subprocess.run(['tmux','kill-server'],env=env,capture_output=True)
            socket_tmp.cleanup()


if __name__=='__main__':unittest.main(verbosity=2)
