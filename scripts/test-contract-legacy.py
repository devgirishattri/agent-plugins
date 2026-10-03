#!/usr/bin/env python3
"""Contract seams in legacy helpers, with real locks and isolated stub transport."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
STUB='''#!/bin/bash
if [ "$1" = route ]; then printf '%s\\n' "$@" > "$TEST_ROUTE_LOG"; exit 0; fi
state=$(cat "$TEST_STATES/$2" 2>/dev/null || echo invalid)
case "$state" in admitted) rc=0;; active|closed-unadmitted) rc=1;; liar) state=admitted; rc=1;; *) rc=2;; esac
printf '{"state":"%s"}\\n' "$state"; exit "$rc"
'''


class Cases:
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='contract-legacy-');self.addCleanup(self.temp.cleanup)
        self.base=Path(self.temp.name).resolve();self.scripts=self.base/'scripts';self.scripts.mkdir()
        source=Path(os.environ.get('CONTRACT_LEGACY_'+self.provider.upper()+'_SCRIPTS',str(ROOT/self.tree/'session-scheduler/scripts')))
        for path in source.glob('*.sh'): shutil.copy(path,self.scripts/path.name)
        with (self.scripts/'lib.sh').open('a') as handle: handle.write('\ncurrent_pane_name() { echo owner; }\n')
        self.home=self.base/'store';self.states=self.base/'states';self.states.mkdir()
        self.engine=self.scripts/'task-contract.sh';self.engine.write_text(STUB)
        self.chat=self.base/'chat';(self.chat/'scripts').mkdir(parents=True)
        for provider in ['claude','codex']:
            folder=self.chat/('.'+provider+'-plugin');folder.mkdir();(folder/'plugin.json').write_text('{"name":"session-chat","version":"0.17.13"}')
        self.transport='''#!/bin/bash
if [ -n "${TEST_ATTACH_FILE:-}" ]; then
  jq '.contract={"version":1}' "$TEST_ATTACH_FILE" > "$TEST_ATTACH_FILE.tmp" && mv "$TEST_ATTACH_FILE.tmp" "$TEST_ATTACH_FILE"
fi
exit 0
'''
        for script in ['dispatch-to-session.sh','send-message.sh']: (self.chat/'scripts'/script).write_text(self.transport)
        self.env={k:v for k,v in os.environ.items() if not k.startswith(('SESSION_','KNOWLEDGE_','TMUX','CLAUDE_','CODEX_'))}
        self.env.update(HOME=str(self.base),SESSION_SCHEDULER_HOME=str(self.home),SESSION_CHAT_ROOT_OVERRIDE=str(self.chat),TEST_STATES=str(self.states),TEST_ROUTE_LOG=str(self.base/'route.log'))
        result=self.run_script('task-status.sh','--all');self.assertEqual(result.returncode,0,result.stderr)

    def run_script(self,name,*args,extra=None):
        return subprocess.run(['bash',str(self.scripts/name),*args],env=dict(self.env,**(extra or {})),capture_output=True,text=True)

    def shell(self,body,*args,extra=None):
        return subprocess.run(['bash','-c','source "$1"; shift; '+body,'legacy-fixture',str(self.scripts/'lib.sh'),*args],env=dict(self.env,**(extra or {})),capture_output=True,text=True)

    def task(self,name,contract=False,**changes):
        data={'id':name,'name':name,'assigner':'owner','assignee':'executor','reviewer':'reviewer','status':'created','created_at':'2020-01-01T00:00:00Z','updated_at':'2020-01-01T00:00:00Z','history':[],'meta':{},'depends_on':[]}
        if contract: data['contract']={'version':1}
        data.update(changes);path=self.home/'tasks'/(name+'.json');path.write_text(json.dumps(data));return path

    def test_routes_missing_engine_and_legacy_control(self):
        path=self.task('T1',True);before=path.read_bytes()
        for name,args in [('assign',['executor','T1','prompt']),('review',['T1','--generation','1','ready']),('done',['T1','--force','bypass']),('block',['T1','--generation','1','blocked'])]:
            result=self.run_script('task-'+name+'.sh',*args);self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual((self.base/'route.log').read_text().splitlines(),['route',name,*args]);self.assertEqual(path.read_bytes(),before)
        self.engine.unlink()
        for name,args in [('assign',['executor','T1','prompt']),('review',['T1','note']),('done',['T1','note']),('block',['T1','note'])]:
            result=self.run_script('task-'+name+'.sh',*args);self.assertEqual(result.returncode,2,result.stderr);self.assertEqual(path.read_bytes(),before)
        self.task('T2');result=self.run_script('task-block.sh','T2','legacy control');self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads((self.home/'tasks/T2.json').read_text())['status'],'blocked')
        result=self.run_script('task-assign.sh','executor','absent','prompt');self.assertNotEqual(result.returncode,0);self.assertIn('not found',(result.stdout+result.stderr).lower())

    def test_direct_writers_refuse_under_lock_with_force(self):
        body='''if declare -F append_history_update >/dev/null; then append_history_update "$1" blocked blocked owner note; first=$?; task_jq_update "$1" '.name="changed"'; second=$?;
else task_set_status "$2" blocked owner note; first=$?; task_update "$2" '.name="changed"'; second=$?; fi
printf '%s/%s' "$first" "$second"
'''
        for contracted in [True,False]:
            path=self.task('T1',contracted);before=path.read_bytes()
            result=self.shell(body,str(path),'T1',extra={'SESSION_SCHEDULER_FORCE':'1'})
            self.assertEqual(result.stdout,'1/1' if contracted else '0/0',result.stderr)
            if contracted: self.assertEqual(path.read_bytes(),before)
            else: self.assertEqual(json.loads(path.read_text())['name'],'changed')

    def test_inline_assignment_race_and_control(self):
        path=self.task('T1');result=self.run_script('task-assign.sh','executor','T1','--force','prompt',extra={'TEST_ATTACH_FILE':str(path)})
        self.assertNotEqual(result.returncode,0);self.assertEqual(json.loads(path.read_text())['status'],'created');self.assertIn('contract',json.loads(path.read_text()))
        self.task('T2');result=self.run_script('task-assign.sh','executor','T2','prompt');self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads((self.home/'tasks/T2.json').read_text())['status'],'assigned')

    def test_dependency_admission_cannot_be_forced(self):
        self.task('dep',True,status='done');path=self.task('T1',depends_on=['dep'])
        for state in ['closed-unadmitted','invalid','liar']:
            (self.states/'dep').write_text(state)
            result=self.run_script('task-assign.sh','executor','T1','--force','prompt');self.assertNotEqual(result.returncode,0);self.assertEqual(json.loads(path.read_text())['status'],'created')
        (self.states/'dep').write_text('admitted');saved=self.engine.read_text();self.engine.unlink()
        self.assertNotEqual(self.run_script('task-assign.sh','executor','T1','--force','prompt').returncode,0)
        self.engine.write_text(saved);result=self.run_script('task-assign.sh','executor','T1','--force','prompt');self.assertEqual(result.returncode,0,result.stderr)
        self.task('T2',depends_on=['../malformed','absent']);result=self.run_script('task-assign.sh','executor','T2','--force','legacy control');self.assertEqual(result.returncode,0,result.stderr)

    def test_flags_doctor_and_status_output(self):
        path=self.task('T1',True,status='done');legacy=self.task('T2',status='blocked')
        for state,wanted in [('closed-unadmitted','closed-unadmitted'),('admitted','admitted'),('liar','invalid')]:
            (self.states/'T1').write_text(state)
            result=self.shell('task_flags "$1"',str(path));self.assertEqual(result.stdout.strip(),'CONTRACT:'+wanted)
        self.assertEqual(self.shell('task_flags "$1"',str(legacy)).stdout.strip(),'-')
        (self.states/'T1').write_text('closed-unadmitted')
        result=self.run_script('scheduler-doctor.sh');self.assertIn('contracts:',result.stdout);self.assertIn('closed-unadmitted',result.stdout)
        result=self.run_script('task-status.sh','--all');self.assertFalse(result.stdout.startswith('WARN:'))
        self.engine.unlink();result=self.run_script('scheduler-doctor.sh');self.assertIn('task-contract.sh missing',result.stdout);self.assertIn('invalid/unavailable',result.stdout)
        with (self.scripts/'lib.sh').open('a') as handle:
            handle.write('\ncommand() { if [ "$1" = -v ] && [ "${2:-}" = python3 ]; then return 1; fi; builtin command "$@"; }\n')
        self.assertIn('python3 missing',self.run_script('scheduler-doctor.sh').stdout)

    def test_cleanup_retains_contracts_and_rechecks_after_lock(self):
        retained=self.task('contracted',True);deleted=self.task('legacy')
        result=self.run_script('tasks-clean.sh','--older-than','30','--apply');self.assertEqual(result.returncode,0,result.stderr);self.assertTrue(retained.exists());self.assertFalse(deleted.exists())
        raced=self.task('raced')
        # Attach while holding the real lock, after the cleanup scan selected it.
        with (self.scripts/'lib.sh').open('a') as handle:
            handle.write('''
if declare -F acquire_task_lock >/dev/null; then LOCK_NAME=acquire_task_lock; else LOCK_NAME=task_lock; fi
eval "$(declare -f "$LOCK_NAME" | sed "1s/$LOCK_NAME/original_fixture_lock/")"
eval "$LOCK_NAME() { original_fixture_lock \\"\\$@\\" || return; if [ \\"\\$1\\" = raced ]; then jq '.contract={}' \\"\\$SESSION_SCHEDULER_HOME/tasks/raced.json\\" > \\"\\$SESSION_SCHEDULER_HOME/staged\\"; mv \\"\\$SESSION_SCHEDULER_HOME/staged\\" \\"\\$SESSION_SCHEDULER_HOME/tasks/raced.json\\"; fi; }"
''')
        result=self.run_script('tasks-clean.sh','--older-than','30','--apply');self.assertEqual(result.returncode,0,(result.stdout,result.stderr));self.assertTrue(raced.exists())
        if self.provider=='codex': self.assertIn('deleted=0',result.stdout)
        self.assertFalse(any((self.home/'locks').iterdir()))


class Codex(Cases,unittest.TestCase): tree='codex/plugins';provider='codex'
class Claude(Cases,unittest.TestCase): tree='plugins';provider='claude'

if __name__=='__main__': unittest.main()
