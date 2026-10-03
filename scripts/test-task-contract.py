#!/usr/bin/env python3
"""Deterministic contract controls over real Git subjects and scheduler locks."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]


class Contracts(unittest.TestCase):
    provider='codex/plugins'

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='contract-')
        self.base=Path(self.temp.name).resolve();self.repo=self.base/'repo';self.repo.mkdir()
        self.home=self.base/'scheduler'
        for child in ['tasks','handoffs','locks','prompts']: (self.home/child).mkdir(parents=True,exist_ok=True)
        self.env=patch.dict(os.environ,{k:v for k,v in os.environ.items() if not k.startswith(('SESSION_','KNOWLEDGE_','TMUX','CLAUDE_','CODEX_'))},clear=True);self.env.start()
        os.environ['SESSION_SCHEDULER_HOME']=str(self.home)
        self.module_path=ROOT/self.provider/'session-scheduler/scripts/task-contract.py'
        spec=importlib.util.spec_from_file_location('contract',self.module_path)
        self.mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.mod)
        self.git('init','-q');self.git('config','user.email','fixture@example.invalid');self.git('config','user.name','Fixture')
        (self.repo/'check.sh').write_text('#!/bin/bash\nexit 0\n');(self.repo/'source').write_text('baseline')
        self.git('add','.');self.git('commit','-qm','fixture')
        self.spec={'schema_version':1,'repository':str(self.repo),'checks':[{'id':'unit','script':'check.sh','args':[],'timeout_seconds':1}],'ttl_seconds':600,'max_attempts':2}
        self.specfile=self.base/'spec.json';self.specfile.write_text(json.dumps(self.spec))
        self.path=self.home/'tasks/T1.json';self.path.write_text(json.dumps({'id':'T1','assigner':'owner','reviewer':'reviewer','status':'created','history':[]}))
        self.store=self.mod.Store('T1','owner');self.store.attach(self.specfile)
        self.store.dispatch=lambda *args: True

    def tearDown(self): self.env.stop();self.temp.cleanup()
    def git(self,*args): return subprocess.run(['git','-C',str(self.repo),*args],check=True,capture_output=True).stdout
    def read(self): return json.loads(self.path.read_text())
    def write(self,data): self.path.write_text(json.dumps(data))
    def assign(self): self.store.actor='owner';return self.store.assign('executor','Implement source change')
    def verify(self): self.store.actor='executor';return self.store.verify(self.read()['contract']['generation'],self.mod.hashed(self.spec))
    def review(self): self.store.actor='executor';return self.store.transition('review',1,'ready')
    def complete(self): self.store.actor='reviewer';return self.store.transition('done',1,'APPROVE inspected exact source')

    def test_full_cycle_and_source_log_receipt_expiry_tampering(self):
        self.assign();self.assertEqual(self.verify()['state'],'passed');self.review();self.complete()
        self.assertEqual(self.store.inspect()['state'],'admitted')
        data=self.read();receipt=self.home/'handoffs/T1'/data['contract']['receipt']['name'];original=receipt.read_bytes()
        for mutation in ['source','log','receipt','expiry']:
            with self.subTest(mutation=mutation):
                if mutation=='source': (self.repo/'source').write_text('changed')
                elif mutation=='log':
                    log=self.home/'handoffs/T1'/json.loads(original)['checks'][0]['log'];log.write_text('tampered')
                elif mutation=='receipt': receipt.write_text('{}')
                else:
                    value=json.loads(original);value['finished_at']=0;receipt.write_text(json.dumps(value))
                    data['contract']['receipt']['sha256']=self.mod.hashed(value);data['contract']['admission']['receipt']=data['contract']['receipt'];self.write(data)
                with self.assertRaises(ValueError): self.store.inspect(fresh=True)
                (self.repo/'source').write_text('baseline');receipt.write_bytes(original)
                if mutation=='log': log.write_bytes(b'')
        # Reset digest after expiry mutation: positive control still admits.
        data['contract']['receipt']['sha256']=self.mod.hashed(json.loads(original));self.write(data)
        self.assertEqual(self.store.inspect()['state'],'admitted')

    def test_generation_actor_force_and_bounded_recovery(self):
        self.assign();self.store.actor='reviewer'
        with self.assertRaises(ValueError): self.store.verify(1,self.mod.hashed(self.spec))
        self.store.actor='executor'
        with self.assertRaises(ValueError): self.store.transition('done',1,'self approval')
        with self.assertRaises(ValueError): self.store.transition('block',2,'late')
        self.store.transition('block',1,'blocked');self.store.actor='owner'
        os.environ['SESSION_SCHEDULER_FORCE']='1'
        with self.assertRaises(ValueError): self.assign()
        self.store.reconcile(1,'observed worker stopped; no unresolved effects');self.assign()
        self.store.actor='executor'
        with self.assertRaises(ValueError): self.store.verify(1,self.mod.hashed(self.spec))
        self.store.transition('block',2,'blocked again');self.store.actor='owner';self.store.reconcile(2,'worker stopped')
        with self.assertRaises(ValueError): self.assign()
        self.assertEqual(self.read()['contract']['attempts'],2)

    def test_missing_receipt_changed_check_and_wrong_digest(self):
        self.assign()
        with self.assertRaises(ValueError): self.review()
        self.store.actor='executor'
        with self.assertRaises(ValueError): self.store.verify(1,'0'*64)
        (self.repo/'check.sh').write_text('exit 0 # weakened')
        with self.assertRaises(ValueError): self.verify()
        (self.repo/'check.sh').write_text('#!/bin/bash\nexit 0\n');self.assertEqual(self.verify()['state'],'passed')

    def test_ambiguous_dispatch_reservation_and_late_completion(self):
        self.store.dispatch=lambda *args: False
        self.assertEqual(self.assign()['state'],'uncertain')
        with self.assertRaises(ValueError): self.assign()
        data=self.read();data['contract']['reservation']={'expires_at':10**12};self.write(data)
        with self.assertRaises(ValueError): self.store.reconcile(1,'too early')
        data['contract']['reservation']['expires_at']=0;self.write(data)
        revision=data['contract']['revision'];self.store.reconcile(1,'confirmed no running worker')
        with self.assertRaises(ValueError): self.store.finish(revision,lambda d,c: c.update(phase='idle'))
        self.store.dispatch=lambda *args: True;self.assertEqual(self.assign()['state'],'assigned')

    def test_legacy_close_cannot_satisfy_admission(self):
        self.assign();data=self.read();data['status']='done';self.write(data)
        with self.assertRaises(ValueError): self.store.inspect(fresh=True)
        data['status']='assigned';self.write(data);self.verify();self.review();self.complete()
        self.assertEqual(self.store.inspect()['state'],'admitted')

    def test_committed_equivalent_content(self):
        self.assign();(self.repo/'source').write_text('reviewed change');self.verify();self.review();self.complete()
        self.git('add','.');self.git('commit','-qm','reviewed')
        with self.assertRaises(ValueError): self.store.inspect(fresh=True)
        self.assertEqual(self.store.inspect()['state'],'admitted')
        self.assertEqual(self.store.inspect(committed=True)['state'],'admitted')
        (self.repo/'source').write_text('unreviewed')
        with self.assertRaises(ValueError): self.store.inspect(committed=True)

    def test_harness_missing_policy_fails_before_execution(self):
        self.assign();os.environ['SESSION_WORKSPACE_HARNESS_MODE']='enforce'
        with self.assertRaises(ValueError): self.verify()
        self.assertEqual(self.read()['contract']['phase'],'idle')
        del os.environ['SESSION_WORKSPACE_HARNESS_MODE'];self.assertEqual(self.verify()['state'],'passed')

    def test_durable_admission_and_fresh_preflight_are_distinct(self):
        self.assign();self.verify();self.review();self.complete()
        (self.repo/'later-work').write_text('new unrelated work')
        with patch.object(self.mod.time,'time',return_value=10**10):
            self.assertEqual(self.store.inspect()['state'],'admitted')
            with self.assertRaises(ValueError): self.store.inspect(fresh=True)
        self.assertEqual(self.store.inspect()['state'],'admitted')

    def test_admission_timestamp_must_still_be_inside_receipt_ttl(self):
        self.spec['ttl_seconds']=1
        data=self.read();data['contract']['spec']=self.spec;self.write(data)
        self.assign();self.verify();self.review()
        record=self.read()['contract']['receipt']
        finished=json.loads((self.home/'handoffs/T1'/record['name']).read_text())['finished_at']
        with patch.object(self.mod.time,'time',side_effect=[finished,finished+2]):
            with self.assertRaises(ValueError): self.complete()
        self.assertEqual(self.read()['status'],'review')
        with patch.object(self.mod.time,'time',return_value=finished):
            self.complete();self.assertEqual(self.store.inspect()['state'],'admitted')

    def test_failing_timeout_and_mutating_checks(self):
        self.assign();self.assertEqual(self.verify()['state'],'passed')
        for body,state in [('exit 3\n','failed'),('sleep 3\n','inconclusive'),('echo changed > source\n','stale')]:
            with self.subTest(state=state):
                (self.repo/'check.sh').write_text(body);self.git('add','.');self.git('commit','-qm','new fixture')
                self.path.write_text(json.dumps({'id':'T1','assigner':'owner','reviewer':'reviewer','status':'created','history':[]}))
                self.store.actor='owner';self.store.attach(self.specfile);self.assign()
                self.assertEqual(self.verify()['state'],state)
                with self.assertRaises(ValueError): self.review()

    def test_cli_invalid_active_and_legacy_guard(self):
        result=subprocess.run(['python3',str(self.module_path),'inspect','absent'],capture_output=True,text=True)
        self.assertEqual((result.returncode,json.loads(result.stdout)['state']),(2,'invalid'))
        result=subprocess.run(['python3',str(self.module_path),'inspect','T1'],capture_output=True,text=True)
        self.assertEqual((result.returncode,json.loads(result.stdout)['state']),(1,'active'))
        before=self.path.read_bytes()
        result=subprocess.run(['bash',str(self.module_path.with_name('task-done.sh')),'T1','--force','bypass'],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0);self.assertEqual(self.path.read_bytes(),before)

    def test_legacy_writer_requires_exactly_one_object(self):
        lib=Path(os.environ.get('TASK_CONTRACT_TEST_'+('CODEX' if self.provider.startswith('codex') else 'CLAUDE')+'_LIB',str(self.module_path.with_name('lib.sh'))))
        command='source "$1"; if declare -F write_json_atomic >/dev/null; then printf "%s" "$3" | write_json_atomic "$2"; else task_write T1 "$3"; fi'
        before=self.path.read_bytes()
        for payload in ['', '[]','not json','{}\n{}','{"id":']:
            with self.subTest(payload=payload):
                self.path.write_bytes(before)
                result=subprocess.run(['bash','-c',command,'writer-control',str(lib),str(self.path),payload],capture_output=True,text=True)
                self.assertNotEqual(result.returncode,0);self.assertEqual(self.path.read_bytes(),before)
        self.path.write_bytes(before)
        result=subprocess.run(['bash','-c',command,'writer-control',str(lib),str(self.path),before.decode()],capture_output=True,text=True)
        self.assertEqual(result.returncode,0);self.assertEqual(json.loads(self.path.read_text()),json.loads(before))

    def test_real_wrapper_and_transport_cycle(self):
        socket=self.base/'tmux-socket'
        def tmux(*args):
            return subprocess.run(['tmux','-S',str(socket),*args],check=True,capture_output=True,text=True).stdout.strip()
        tmux('new-session','-d','-x','220','-y','40','-s','contract','cat')
        try:
            tmux('split-window','-t','contract','cat');tmux('split-window','-t','contract','cat')
            panes=tmux('list-panes','-t','contract','-F','#{pane_id}').splitlines()
            for pane,name in zip(panes,['owner','executor','reviewer']): tmux('set-option','-p','-t',pane,'@name',name)
            env=dict(os.environ,TMUX=tmux('display-message','-p','-t',panes[0],'#{socket_path},#{pid},0'),
                     CODEX_HOME=str(self.base/'codex-home'),CLAUDE_HOME=str(self.base/'claude-home'),
                     SESSION_CHAT_TARGET_MESSAGES_DIR=str(self.base/'messages'),
                     SESSION_CHAT_ROOT_OVERRIDE=str(ROOT/self.provider/'session-chat'))
            (self.base/'messages').mkdir()
            def run(pane,script,*args):
                result=subprocess.run(['bash',str(self.module_path.with_name(script)),*args],env=dict(env,TMUX_PANE=pane),capture_output=True,text=True)
                self.assertEqual(result.returncode,0,(result.stdout,result.stderr))
                return result
            run(panes[0],'task-assign.sh','executor','T1','Implement fixture source')
            run(panes[1],'task-contract.sh','verify','T1','--generation','1','--spec-digest',self.mod.hashed(self.spec))
            run(panes[1],'task-review.sh','T1','--generation','1','ready for independent review')
            run(panes[2],'task-done.sh','T1','--generation','1','APPROVE inspected source')
            self.assertEqual(self.store.inspect()['state'],'admitted')
            self.assertTrue(list((self.home/'handoffs/T1').glob('dispatch-*')))
        finally:
            subprocess.run(['tmux','-S',str(socket),'kill-server'],capture_output=True)


class ClaudeContracts(Contracts): provider='plugins'


if __name__=='__main__': unittest.main()
