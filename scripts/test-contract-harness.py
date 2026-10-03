#!/usr/bin/env python3
"""Active strict-v1 controls for task-contract verify; isolated provider fixtures.

Originally authored independently by the Claude reviewer; run both providers.

Everything lives in a tempfile tree: fake provider home with the cache layout the
engine resolves (<home>/.claude/plugins/cache/girishattri-plugins/<plugin>/<ver>/scripts),
a registry selecting those versions, an enforce-mode harness config, and a Git
fixture holding a tracked check script that writes a marker file when executed.
The engine module is loaded FROM the copied cache path so HERE resolves in the cache.
"""
import argparse
import importlib.util
import sys
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

parser=argparse.ArgumentParser(add_help=False)
parser.add_argument('--provider',choices=['claude','codex'],default='claude')
options,unittest_args=parser.parse_known_args()
PROVIDER=options.provider
REPO = Path(__file__).resolve().parents[1]
TREE=REPO / ('codex/plugins' if PROVIDER=='codex' else 'plugins')
MANIFEST='.codex-plugin' if PROVIDER=='codex' else '.claude-plugin'
SCHED_SRC = TREE / 'session-scheduler/scripts'
WS_SRC = TREE / 'session-workspace/scripts'
FIXTURE = WS_SRC / 'fixtures/valid/harness-v2.json'
MARKET = 'girishattri-plugins'
MASTER = 'harness-sample-master'
EXEC = 'harness-sample-component-executor'
REVIEW = 'harness-sample-component-reviewer'


def version_of(plugin):
    return json.loads((TREE / plugin / MANIFEST / 'plugin.json').read_text())['version']


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='harness-verify-')
        self.base = Path(self.temp.name).resolve()
        self.project = self.base / 'project'
        self.markers = self.base / 'markers'
        self.markers.mkdir()
        self.env_patch = patch.dict(os.environ, {k: v for k, v in os.environ.items() if k in {'PATH', 'LANG'}}, clear=True)
        self.env_patch.start()
        self.home = self.base / 'home'
        self.provider_home = self.home / ('.codex' if PROVIDER=='codex' else '.claude')
        self.cache = self.provider_home / 'plugins/cache' / MARKET
        self.sched_ver, self.ws_ver = version_of('session-scheduler'), version_of('session-workspace')
        self.install_cache(self.sched_ver, self.ws_ver)
        self.write_registry({'session-scheduler': self.sched_ver, 'session-workspace': self.ws_ver})
        self.config = self.project / '.agent-workspace/workspace.json'
        self.build_project()
        self.mod = self.load_engine(self.cache / 'session-scheduler' / self.sched_ver / 'scripts/task-contract.py')
        self.scheduler = self.project / '.tmp/scheduler'
        for child in ['tasks', 'handoffs', 'locks', 'prompts']:
            (self.scheduler / child).mkdir(parents=True, exist_ok=True)
        os.environ.update({'HOME': str(self.home), 'SESSION_SCHEDULER_HOME': str(self.scheduler)})

    def tearDown(self):
        self.env_patch.stop()
        self.temp.cleanup()

    # ---- fake installed provider home -------------------------------------
    def install_cache(self, sched_ver, ws_ver):
        ignore = shutil.ignore_patterns('__pycache__', '*.pyc')
        shutil.copytree(SCHED_SRC, self.cache / 'session-scheduler' / sched_ver / 'scripts', ignore=ignore)
        shutil.copytree(WS_SRC, self.cache / 'session-workspace' / ws_ver / 'scripts', ignore=ignore)
        for name,version in [('session-scheduler',sched_ver),('session-workspace',ws_ver)]:
            shutil.copytree(TREE/name/MANIFEST,self.cache/name/version/MANIFEST)

    def write_registry(self, versions, extra=None):
        if PROVIDER=='codex':
            self.registry_file=self.provider_home/'config.toml'
            self.registry_file.parent.mkdir(parents=True,exist_ok=True)
            self.registry_file.write_text(''.join('[plugins."'+name+'@'+MARKET+'"]\nenabled = true\n' for name in versions))
            for name in ['session-scheduler','session-workspace']:
                path=self.provider_home/'.tmp/marketplaces'/MARKET/'codex/plugins'/name/MANIFEST/'plugin.json'
                if name in versions:
                    path.parent.mkdir(parents=True,exist_ok=True)
                    path.write_text(json.dumps({'name':name,'version':versions[name]}))
                elif path.exists(): path.unlink()
            return
        plugins = {f'{name}@{MARKET}': [{'scope': 'user', 'projectPath': None, 'version': ver,
                                         'installPath': str(self.cache / name / ver)}] for name, ver in versions.items()}
        plugins.update(extra or {})
        reg = self.provider_home / 'plugins/installed_plugins.json'
        self.registry_file=reg
        reg.parent.mkdir(parents=True, exist_ok=True)
        reg.write_text(json.dumps({'version': 2, 'plugins': plugins}))

    def load_engine(self, path):
        spec = importlib.util.spec_from_file_location('contract_' + path.parent.parent.parent.name + path.parent.parent.name, path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    # ---- project + repo ------------------------------------------------------
    def git(self, repo, *args):
        return subprocess.run(['git', '-C', str(repo), *args], check=True, capture_output=True).stdout

    def build_project(self):
        for d in ['.agent-workspace', '.agents/memory', 'component-a', 'component-b', 'tools']:
            (self.project / d).mkdir(parents=True, exist_ok=True)
        shutil.copy(FIXTURE, self.config)
        for name in ['component-a', 'component-b', 'tools']:
            repo = self.project / name
            self.git(repo, 'init', '-q')
            self.git(repo, 'config', 'user.email', 'fixture@example.invalid')
            self.git(repo, 'config', 'user.name', 'Fixture')
            self.git(repo, 'config', 'commit.gpgsign', 'false')

    def commit_check(self, repo_name, body, marker):
        repo = self.project / repo_name
        script = body.format(marker=marker, config=self.config)
        (repo / 'check.sh').write_text(script)
        self.git(repo, 'add', '.')
        self.git(repo, 'commit', '-qm', 'fixture')
        return repo

    def identity(self, pane=EXEC, role='executor', cwd=None):
        return {'SESSION_WORKSPACE_CONFIG': str(self.config), 'SESSION_WORKSPACE_PROJECT_ROOT': str(self.project),
                'SESSION_WORKSPACE_PANE_NAME': pane, 'SESSION_WORKSPACE_ROLE': role,
                'SESSION_WORKSPACE_PANE_CWD': str(cwd or self.project / 'component-a'),
                'SESSION_WORKSPACE_HARNESS_MODE': 'enforce', 'CLAUDE_HOME': str(self.home / '.claude'), 'CODEX_HOME': str(self.home / '.codex')}

    BODY = '#!/bin/bash\nprintf ran > \'{marker}\'\nexit 0\n'

    def contract(self, repo_name='component-a', args=None, body=None, mod=None, ident=True):
        """Attach + assign (outside the harness identity), then optionally activate it."""
        self.marker = self.markers / ('m-' + repo_name)
        repo = self.commit_check(repo_name, body or self.BODY, self.marker)
        self.spec = {'schema_version': 1, 'repository': str(repo),
                     'checks': [{'id': 'unit', 'script': 'check.sh', 'args': args or [], 'timeout_seconds': 10}],
                     'ttl_seconds': 600, 'max_attempts': 2}
        specfile = self.base / 'spec.json'
        specfile.write_text(json.dumps(self.spec))
        self.task = self.scheduler / 'tasks/T1.json'
        self.task.write_text(json.dumps({'id': 'T1', 'assigner': MASTER, 'reviewer': REVIEW, 'status': 'created', 'history': []}))
        self.mod_used = mod or self.mod
        self.store = self.mod_used.Store('T1', MASTER)
        self.store.attach(specfile)
        self.store.dispatch = lambda *a: True
        self.store.assign(EXEC, 'Implement the change')
        self.revision = self.data()['contract']['revision']
        if ident:
            os.environ.update(self.identity())

    def data(self):
        return json.loads(self.task.read_text())

    def verify(self):
        self.store.actor = EXEC
        return self.store.verify(self.data()['contract']['generation'], self.mod_used.hashed(self.spec))

    def assert_refused_unexecuted(self, fragment=None):
        with self.assertRaises(ValueError) as caught:
            self.verify()
        if fragment:
            self.assertIn(fragment, str(caught.exception))
        self.assertFalse(self.marker.exists(), 'check script executed despite refusal')
        c = self.data()['contract']
        self.assertEqual(c['phase'], 'idle')
        self.assertNotIn('receipt', c)
        self.assertNotIn('reservation', c)
        self.assertEqual(c['revision'], self.revision, 'refusal must not reserve/mutate the contract')
        self.assertEqual(list((self.scheduler / 'handoffs/T1').glob('log-*')) if (self.scheduler / 'handoffs/T1').exists() else [], [])
        return str(caught.exception)

    def receipt(self):
        c = self.data()['contract']
        return json.loads((self.scheduler / 'handoffs/T1' / c['receipt']['name']).read_text())

    def full_cycle(self):
        self.store.actor = EXEC
        self.store.transition('review', 1, 'ready')
        self.store.actor = REVIEW
        self.store.transition('done', 1, 'APPROVE inspected exact source')


class PositiveControl(Fixture):
    def test_1_active_harness_executor_verify_passes_harness_decided(self):
        self.contract()
        result = self.verify()
        self.assertEqual(result['state'], 'passed')
        self.assertTrue(self.marker.exists(), 'positive control must actually execute the check')
        receipt = self.receipt()
        self.assertEqual(receipt['policy_decisions'], ['harness-decided'])
        self.assertEqual(receipt['actor'], EXEC)
        configuration = receipt['source']['configuration']
        self.assertEqual(configuration['path'], str(self.config))
        self.assertEqual(configuration['sha256'], __import__('hashlib').sha256(self.config.read_bytes()).hexdigest())
        self.full_cycle()
        self.assertEqual(self.store.inspect(fresh=True)['state'], 'admitted')
        self.assertEqual(self.store.inspect(committed=True)['state'], 'admitted')

    def test_1b_cli_entrypoint_from_cache_passes(self):
        self.contract()
        env = dict(os.environ, TASK_CONTRACT_ACTOR=EXEC)
        engine = self.cache / 'session-scheduler' / self.sched_ver / 'scripts/task-contract.py'
        result = subprocess.run(['python3', '-B', str(engine), 'verify', 'T1', '--generation', '1', '--spec-digest', self.mod.hashed(self.spec)],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, (result.stdout, result.stderr))
        self.assertEqual(json.loads(result.stdout)['state'], 'passed')
        self.assertEqual(self.receipt()['policy_decisions'], ['harness-decided'])

    def test_1c_inactive_control_without_identity_is_reviewed_not_decided(self):
        self.contract(ident=False)
        self.assertEqual(self.verify()['state'], 'passed')
        self.assertEqual(self.receipt()['policy_decisions'], ['inactive-command-reviewed'])


class Deny(Fixture):
    def test_2a_traversal_operand_denied(self):
        self.contract(args=['../component-b/check.sh'])
        self.assertIn('executor.containment', self.assert_refused_unexecuted('inner check denied by harness policy'))

    def test_2a_control_literal_dollar_arg_is_data_not_expansion(self):
        # Engine runs argv literally (shlex.join quotes it), so the harness correctly treats '$HOME' as data.
        self.contract(args=['$HOME'])
        self.assertEqual(self.verify()['state'], 'passed')
        self.assertEqual(self.receipt()['policy_decisions'], ['harness-decided'])

    def test_2b_absolute_operand_outside_executor_cwd_denied(self):
        self.contract(args=['/etc/hosts'])
        self.assertIn('executor.containment', self.assert_refused_unexecuted('inner check denied by harness policy'))

    def test_2c_inline_shell_flag_denied(self):
        self.contract(args=['-c'])
        self.assertIn('executor.inline_code', self.assert_refused_unexecuted('inner check denied by harness policy'))

    def test_2d_repository_outside_executor_cwd_denied(self):
        # Executor is configured in component-a; the contract points at sibling component-b.
        self.contract(repo_name='component-b')
        self.assertIn('executor.containment', self.assert_refused_unexecuted('inner check denied by harness policy'))

    def test_2e_audit_mode_cannot_downgrade_enforce_launcher(self):
        # Control for deny tests: the same benign contract passes under the positive identity,
        # and a launcher/config mode mismatch is an integrity denial, not an audit pass.
        self.contract()
        cfg = json.loads(self.config.read_text())
        cfg['harness']['mode'] = 'audit'
        self.config.write_text(json.dumps(cfg, indent=2))
        self.assert_refused_unexecuted('harness identity unavailable')


class Identity(Fixture):
    def drop(self, *names):
        for name in names:
            os.environ.pop(name, None)

    def test_3a_missing_pane_name_refused(self):
        self.contract(); self.drop('SESSION_WORKSPACE_PANE_NAME')
        self.assert_refused_unexecuted('harness identity unavailable')

    def test_3b_missing_role_refused(self):
        self.contract(); self.drop('SESSION_WORKSPACE_ROLE')
        self.assert_refused_unexecuted('harness identity unavailable')

    def test_3c_mode_without_config_is_partial(self):
        self.contract(); self.drop('SESSION_WORKSPACE_CONFIG')
        self.assert_refused_unexecuted('partial harness identity')

    def test_3d_config_without_mode_refused(self):
        self.contract(); self.drop('SESSION_WORKSPACE_HARNESS_MODE')
        self.assert_refused_unexecuted('harness identity unavailable')

    def test_3e_unknown_pane_refused(self):
        self.contract(); os.environ['SESSION_WORKSPACE_PANE_NAME'] = 'harness-sample-ghost'
        self.assert_refused_unexecuted('harness identity unavailable')

    def test_3f_role_mismatch_refused(self):
        self.contract(); os.environ['SESSION_WORKSPACE_ROLE'] = 'reviewer'
        self.assert_refused_unexecuted('harness identity unavailable')

    def test_3g_cwd_mismatch_refused(self):
        self.contract(); os.environ['SESSION_WORKSPACE_PANE_CWD'] = str(self.project)
        self.assert_refused_unexecuted('harness identity unavailable')

    def test_3h_alias_disagreement_refused(self):
        self.contract(); os.environ['SESSION_CHAT_PANE_NAME'] = REVIEW
        self.assert_refused_unexecuted('harness identity unavailable')

    def test_3i_alias_agreement_control_passes(self):
        self.contract(); os.environ['SESSION_CHAT_PANE_NAME'] = EXEC
        self.assertEqual(self.verify()['state'], 'passed')

    def test_3j_stale_identity_reviewer_env_with_executor_actor_refused(self):
        # Engine actor (bound assignee) is the executor, but the inherited harness identity is the reviewer pane.
        self.contract(); os.environ.update(self.identity(REVIEW, 'reviewer'))
        self.assert_refused_unexecuted()

    def test_3k_stale_identity_orchestrator_env_with_executor_actor_refused(self):
        # Orchestrator identity has a looser shell floor; the engine must not let it vouch for the executor's check.
        self.contract(); os.environ.update(self.identity(MASTER, 'master', self.project))
        self.assert_refused_unexecuted()


class ActorBinding(Fixture):
    def test_3l_control_executor_identity_denied_for_repo_outside_its_cwd(self):
        self.contract(repo_name='tools')
        self.assertIn('executor.containment', self.assert_refused_unexecuted('inner check denied by harness policy'))

    def test_3m_orchestrator_identity_cannot_vouch_for_executor_actor_on_non_child_repo(self):
        # Same contract as 3l, but env identity is the orchestrator pane while the engine actor (assignee) is the executor.
        self.contract(repo_name='tools'); os.environ.update(self.identity(MASTER, 'master', self.project))
        self.assert_refused_unexecuted()


class Drift(Fixture):
    def edit_config(self, mutate):
        cfg = json.loads(self.config.read_text()); mutate(cfg)
        self.config.write_text(json.dumps(cfg, indent=2))

    def _invalid_drift(self, mutate):
        self.contract()
        self.edit_config(mutate)
        self.assert_refused_unexecuted('harness identity unavailable')
        # control: restoring the valid bytes makes the very same contract pass
        shutil.copy(FIXTURE, self.config)
        self.assertEqual(self.verify()['state'], 'passed')
        self.assertTrue(self.marker.exists())

    def test_4a_harness_disabled_in_config_after_assign_refused(self):
        self._invalid_drift(lambda c: c['harness'].update(enabled=False))

    def test_4a_roles_broken_in_config_after_assign_refused(self):
        self._invalid_drift(lambda c: c['harness']['roles'].update(reviewer='missing'))

    def test_4a_pane_removed_from_config_after_assign_refused(self):
        self._invalid_drift(lambda c: c['sessions'][0].update(panes=[p for p in c['sessions'][0]['panes'] if p['role'] != 'executor']))

    def test_4b_config_deleted_or_corrupt_refused_unexecuted(self):
        self.contract()
        self.config.write_text('{not json')
        self.assert_refused_unexecuted()

    def test_4c_valid_drift_before_verify_is_bound_into_receipt_and_stale_after(self):
        # Characterisation: attach/assign do not pin the config; verify binds whatever valid config is live.
        self.contract()
        original_sha = __import__('hashlib').sha256(self.config.read_bytes()).hexdigest()
        self.edit_config(lambda c: c['project'].update(display_name='Drifted Display Name'))
        self.assertEqual(self.verify()['state'], 'passed')
        bound = self.receipt()['source']['configuration']['sha256']
        self.assertNotEqual(bound, original_sha)
        self.full_cycle()
        self.assertEqual(self.store.inspect(fresh=True)['state'], 'admitted')   # control: no drift since verify
        self.edit_config(lambda c: c['project'].update(display_name='Second drift'))
        self.assertEqual(self.store.inspect()['state'], 'admitted')             # durable admission is time-of-close
        with self.assertRaises(ValueError): self.store.inspect(fresh=True)
        with self.assertRaises(ValueError): self.store.inspect(committed=True)

    def test_4d_drift_after_receipt_rejected_by_fresh_and_committed_then_restored(self):
        self.contract(); self.verify(); self.full_cycle()
        good = self.config.read_bytes()
        self.assertEqual(self.store.inspect(fresh=True)['state'], 'admitted')
        self.assertEqual(self.store.inspect(committed=True)['state'], 'admitted')
        self.edit_config(lambda c: c['behavior'].update(save_before_stop=False))
        with self.assertRaises(ValueError): self.store.inspect(fresh=True)
        with self.assertRaises(ValueError): self.store.inspect(committed=True)
        self.config.write_bytes(good)
        self.assertEqual(self.store.inspect(committed=True)['state'], 'admitted')

    def test_4e_config_mutated_by_check_during_verify_is_stale_and_inadmissible(self):
        body = '#!/bin/bash\nprintf ran > \'{marker}\'\nprintf " " >> \'{config}\'\nexit 0\n'
        self.contract(body=body)
        result = self.verify()
        self.assertEqual(result['state'], 'stale')
        self.assertTrue(self.marker.exists())
        self.store.actor = EXEC
        with self.assertRaises(ValueError): self.store.transition('review', 1, 'ready')


class MissingPolicy(Fixture):
    def test_5a_selected_workspace_cache_removed(self):
        self.contract(); shutil.rmtree(self.cache / 'session-workspace')
        self.assert_refused_unexecuted()

    def test_5b_registry_selects_uninstalled_version(self):
        self.contract(); self.write_registry({'session-scheduler': self.sched_ver, 'session-workspace': '9.9.9'})
        self.assert_refused_unexecuted()

    def test_5c_registry_without_workspace_entry(self):
        self.contract(); self.write_registry({'session-scheduler': self.sched_ver})
        self.assert_refused_unexecuted()

    def test_5d_registry_missing(self):
        self.contract(); self.registry_file.unlink()
        self.assert_refused_unexecuted()

    def test_5e_scheduler_not_the_selected_version(self):
        self.contract(); self.write_registry({'session-scheduler': '0.0.1', 'session-workspace': self.ws_ver})
        self.assert_refused_unexecuted('selected harness evaluator unavailable')

    def test_5f_engine_outside_installed_cache_refused(self):
        outside = self.base / 'outside/session-scheduler/scripts'
        shutil.copytree(SCHED_SRC, outside, ignore=shutil.ignore_patterns('__pycache__'))
        mod = self.load_engine(outside / 'task-contract.py')
        self.contract(mod=mod)
        self.assert_refused_unexecuted('active harness requires an installed selected scheduler')

    def test_5g_control_registry_and_cache_intact_passes(self):
        self.contract()
        self.assertEqual(self.verify()['state'], 'passed')


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0],*unittest_args],verbosity=2)
