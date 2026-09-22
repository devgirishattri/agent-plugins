#!/usr/bin/env python3
"""Synthetic v5 regressions; no paid calls, real agent launches or user stores."""
import argparse
import copy
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
        for d in ['component-a', 'component-b', 'control-web', 'control-vue3', '.agent-workspace', '.tmp/scheduler/tasks', '.tmp/messages', '.tmp/integrations']:
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
                   SESSION_WORKSPACE_SCOPE_JSON=json.dumps(pane['scope'], sort_keys=True, separators=(',', ':')),
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

    def test_bad_bindings(self):
        self.plan()  # valid positive control
        original = copy.deepcopy(self.cfg)
        for mutate in [
            lambda c: c['environments'][1].update(id='web'),
            lambda c: c['environments'][1].update(services=['service-web']),
            lambda c: c['environments'][1].update(cwd='../outside'),
            lambda c: c['sessions'][1]['panes'][0].update(cwd='.'),
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

    def test_jev_off_and_removal(self):
        self.cfg['integrations']={'jev':{'enabled':False,'credential_file':'missing/key'}};self.write()
        self.plan()
        r=self.run_script('workspace-jev','--packet','does-not-exist','--sanitized')
        self.assertEqual(json.loads(r.stdout)['status'],'disabled')
        del self.cfg['integrations'];self.write();self.plan()
        self.assertEqual(json.loads(self.run_script('workspace-jev','--status').stdout)['status'],'disabled')

    def test_jev_mock_and_budget(self):
        j=module('jev_v5','jev-adapter.py')
        self.cfg['integrations']={'jev':{'enabled':True,'credential_file':'.key','mode':'advisory'}}
        self.cfg['harness']={'enabled':False}
        del self.cfg['orchestration']
        for e in self.cfg['environments']: del e['orchestrator']
        for session in self.cfg['sessions']:
            session['panes']=[p for p in session['panes'] if p['name'] not in ('web-master','vue3-master')]
        self.cfg['stores']['pin'].append('integrations');self.write()
        subprocess.run(['git','init','-q',str(self.root)],check=True)
        (self.root/'.gitignore').write_text('.key\n')
        (self.root/'.key').write_text('synthetic-test-key');(self.root/'.key').chmod(0o600)
        packet=self.root/'packet.json';packet.write_text(json.dumps(dict(surface='chat',current_observation='No pane named worker',background='')))
        args=argparse.Namespace(config=str(self.path),environment=None,status=False,packet=str(packet),sanitized=True)
        catalog=json.loads((HERE/'jev-catalog.json').read_text())
        response={'model':j.MODEL,'answers':{'guide':{'type':'choice','choice':'missing_target','confidence':1,'probabilities':{k:float(k=='missing_target') for k in catalog}}},'usage':{'input_tokens':200}}
        env=dict(ENV,SESSION_WORKSPACE_INTEGRATIONS_HOME=str(self.root/'.tmp/integrations'),SESSION_WORKSPACE_JEV_MAX_REQUESTS='1')
        calls=[]
        def send(body,key,timeout):calls.append(body);return response
        with patch.dict(os.environ,env,clear=True):
            out=j.evaluate(args,sender=send)
            self.assertEqual(out['category'],'missing_target')
            self.assertEqual(j.evaluate(args,sender=send)['reason_code'],'already_attempted')
            packet.write_text(json.dumps(dict(surface='chat',current_observation='Another report',background='')))
            self.assertEqual(j.evaluate(args,sender=send)['status'],'budget_exhausted')
        self.assertEqual(len(calls),1)
        self.assertNotIn('synthetic-test-key',(self.root/'.tmp/integrations/jev-budget.jsonl').read_text())
        response['answers']['guide']['probabilities']['missing_target']=float('nan')
        with self.assertRaises(ValueError):j.answer(response,catalog)

    def test_jev_disabled_zero_io(self):
        j=module('jev_off_v5','jev-adapter.py')
        args=argparse.Namespace(config=None,environment=None,status=False,packet='absent',sanitized=True)
        with patch.object(j,'safe_file',side_effect=AssertionError('file read')), patch.object(j,'ledger',side_effect=AssertionError('store read')):
            out=j.evaluate(args,planner=lambda _: {'integrations':{'jev':{'enabled':False}}},sender=lambda *_: self.fail('network call'))
            self.assertEqual(out['status'],'disabled')
        # Adapter removal is an explicit unavailable result, never a core import failure.
        wrapper=self.root/'workspace-jev.sh';wrapper.write_text((HERE/'workspace-jev.sh').read_text())
        r=subprocess.run(['bash',str(wrapper),'--status'],capture_output=True,text=True)
        self.assertEqual(json.loads(r.stdout)['reason_code'],'adapter_removed')
        self.plan()

    def test_credential_safety(self):
        j=module('jev_key_v5','jev-adapter.py')
        key=self.root/'key';key.write_text('synthetic');key.chmod(0o600)
        self.assertEqual(j.safe_file(key,self.root,100,True),'synthetic')
        key.chmod(0o644)
        with self.assertRaises(ValueError):j.safe_file(key,self.root,100,True)
        key.chmod(0o600)
        alias=self.root/'alias';alias.symlink_to(key)
        with self.assertRaises((OSError,ValueError)):j.safe_file(alias,self.root,100,True)
        alias.unlink();os.link(key,alias)
        with self.assertRaises(ValueError):j.safe_file(key,self.root,100,True)

    def test_jev_failure_and_disable_during_request(self):
        j=module('jev_failure_v5','jev-adapter.py')
        (self.root/'key').write_text('synthetic');(self.root/'key').chmod(0o600)
        subprocess.run(['git','init','-q',str(self.root)],check=True)
        (self.root/'.gitignore').write_text('key\n')
        packet=self.root/'packet.json';packet.write_text(json.dumps(dict(surface='chat',current_observation='No accessible named worker',background='')))
        p={'project':{'root':str(self.root)},'integrations':{'jev':{'enabled':True,'credential_file':'key','mode':'advisory'}},'integration_store':str(self.root/'.tmp/integrations')}
        args=argparse.Namespace(config=None,environment=None,status=False,packet=str(packet),sanitized=True)
        catalog=json.loads((HERE/'jev-catalog.json').read_text())
        response={'model':j.MODEL,'answers':{'guide':{'type':'choice','choice':'missing_target','confidence':1,'probabilities':{k:float(k=='missing_target') for k in catalog}}},'usage':{'input_tokens':100}}
        env=dict(ENV,SESSION_WORKSPACE_INTEGRATIONS_HOME=p['integration_store'],SESSION_WORKSPACE_JEV_MAX_REQUESTS='2')
        def failure(*_):raise TimeoutError()
        with patch.dict(os.environ,env,clear=True):
            self.assertEqual(j.evaluate(args,planner=lambda _:p,sender=failure)['status'],'unavailable')
            packet.write_text(json.dumps(dict(surface='chat',current_observation='New report',background='')))
            def disable(*_):
                p['integrations']['jev']['enabled']=False
                return response
            self.assertEqual(j.evaluate(args,planner=lambda _:p,sender=disable)['reason_code'],'stale_result')
            self.assertEqual(j.evaluate(args,planner=lambda _:p,sender=lambda *_:self.fail('sent after off'))['status'],'disabled')
        self.assertEqual(len((self.root/'.tmp/integrations/jev-budget.jsonl').read_text().splitlines()),2)

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
