#!/usr/bin/env python3
"""New helper grammars preserve pane identity, role and literal argv limits."""
import dataclasses
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


class Cases:
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve();(self.root/'tasks').mkdir()
        spec=importlib.util.spec_from_file_location('reliability_policy',ROOT/self.tree/'session-workspace/scripts/harness-policy.py')
        self.policy=importlib.util.module_from_spec(spec);sys.modules[spec.name]=self.policy;spec.loader.exec_module(self.policy)
        self.ctx=self.policy.Context(mode='enforce',semantic_role='executor',pane_name='executor',pane_cwd=self.root,project_root=self.root,
            config_path=self.root/'config.json',orchestrator_pane='owner',executor_panes=frozenset({'executor'}),reviewer_panes=frozenset({'reviewer'}),
            child_roots=(self.root,),grant_roots=(),message_roots=(),claude_home=self.root/'claude',codex_home=self.root/'codex',guards={},scheduler_root=self.root)
        self.task={'id':'T1','assigner':'owner','assignee':'executor','reviewer':'reviewer','status':'assigned','contract':{'version':1}}
        (self.root/'tasks/T1.json').write_text(json.dumps(self.task))

    def test_contract_role_and_generation(self):
        args=['verify','T1','--generation','1','--spec-digest','a'*64]
        self.policy.task_contract(self.ctx,'task-contract.sh',args)
        for bad in [args[:-2],['route','T1'],['verify','T1','--generation','0','--spec-digest','a'*64],args+['--force']]:
            with self.subTest(bad=bad),self.assertRaises(self.policy.PolicyFailure): self.policy.task_contract(self.ctx,'task-contract.sh',bad)
        other=dataclasses.replace(self.ctx,pane_name='other')
        with self.assertRaises(self.policy.PolicyFailure): self.policy.task_contract(other,'task-contract.sh',args)
        reviewer=dataclasses.replace(self.ctx,semantic_role='reviewer',pane_name='reviewer')
        with self.assertRaises(self.policy.PolicyFailure): self.policy.task_contract(reviewer,'task-contract.sh',args)
        self.policy.task_transition(True)(self.ctx,'task-review.sh',['T1','--generation','1','ready'])
        with self.assertRaises(self.policy.PolicyFailure): self.policy.task_transition(True)(self.ctx,'task-done.sh',['T1','--generation','1','APPROVE'])
        self.policy.task_transition(True)(reviewer,'task-done.sh',['T1','--generation','1','APPROVE'])

    def test_contract_inspect_attach_and_scope(self):
        for suffix in [[],['--fresh'],['--committed']]:
            self.policy.task_contract(self.ctx,'task-contract.sh',['inspect','T1',*suffix])
        spec=self.root/'spec.json';spec.write_text('{}')
        owner=dataclasses.replace(self.ctx,semantic_role='orchestrator',pane_name='owner')
        self.policy.task_contract(owner,'task-contract.sh',['attach','T1','--spec',str(spec)])
        self.policy.task_contract(owner,'task-contract.sh',['reconcile','T1','--generation','1','--note','worker stopped'])
        scoped=dataclasses.replace(owner,scoped=True,environment='alpha')
        with self.assertRaises(self.policy.PolicyFailure): self.policy.task_contract(scoped,'task-contract.sh',['inspect','T1'])
        self.task['meta']={'environment':'alpha'};(self.root/'tasks/T1.json').write_text(json.dumps(self.task))
        self.policy.task_contract(scoped,'task-contract.sh',['inspect','T1'])

    def test_malformed_tasks_and_generation_controls(self):
        reviewer=dataclasses.replace(self.ctx,semantic_role='reviewer',pane_name='reviewer')
        owner=dataclasses.replace(self.ctx,semantic_role='orchestrator',pane_name='owner')
        check=self.policy.task_transition(True)
        args=['T1','--generation','1','APPROVE']
        check(reviewer,'task-done.sh',args)
        for data in [[],None,{**self.task,'meta':'x'},{k:v for k,v in self.task.items() if k!='contract'}]:
            (self.root/'tasks/T1.json').write_text(json.dumps(data))
            with self.subTest(data=data),self.assertRaises(self.policy.PolicyFailure): check(reviewer,'task-done.sh',args)
        check(reviewer,'task-done.sh',['T1','legacy note'])
        (self.root/'tasks/T1.json').write_text(json.dumps(self.task))
        with self.assertRaises(self.policy.PolicyFailure):
            self.policy.task_contract(owner,'task-contract.sh',['reconcile','T1','--generation','1','--note','--force'])
        self.policy.task_contract(owner,'task-contract.sh',['reconcile','T1','--generation','1','--note','worker stopped'])

    def test_pr_literal_grammar(self):
        self.policy.pr_status(self.ctx,'pr-status.sh',['--repo','example/sample','--pr','1','--expected-head','a'*40])
        snapshot=self.root/'pr.json';snapshot.write_text('{}')
        self.policy.pr_status(self.ctx,'pr-status.sh',['--snapshot',str(snapshot)])
        for args in [['--repo','example/sample','--pr','0'],['--repo','example/sample','--pr','1','--pr','2'],['--snapshot',str(snapshot),'--repo','example/sample'],['--repo','example/sample','--pr','1','--merge']]:
            with self.subTest(args=args),self.assertRaises(self.policy.PolicyFailure): self.policy.pr_status(self.ctx,'pr-status.sh',args)


class Codex(Cases,unittest.TestCase): tree='codex/plugins'
class Claude(Cases,unittest.TestCase): tree='plugins'

if __name__=='__main__': unittest.main()
