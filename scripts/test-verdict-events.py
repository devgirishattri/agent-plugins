#!/usr/bin/env python3
"""Cross-provider verdict behavior with real ledgers, draft checks and contract engine.

Transport and pane discovery are recording stubs. Provider-local suites cover
real transport and externally injected crashes. VERDICT_TEST_{CLAUDE,CODEX}_ROOT
can point to a plugin tree overlaid from an exact baseline commit.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PROVIDERS = {
    'claude': Path(os.environ.get('VERDICT_TEST_CLAUDE_ROOT', ROOT / 'plugins')),
    'codex': Path(os.environ.get('VERDICT_TEST_CODEX_ROOT', ROOT / 'codex/plugins')),
}


class Verdicts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='verdict-', dir='/tmp')
        self.base = Path(self.tmp.name).resolve()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('SESSION_', 'KNOWLEDGE_'))
                    and k not in {'TMUX', 'TMUX_PANE', 'BASH_ENV', 'ENV'}}

    def tearDown(self):
        self.tmp.cleanup()

    def fixture(self, provider, label):
        base = self.base / provider / label
        chat = base / 'chat'
        scripts = chat / 'scripts'
        scripts.mkdir(parents=True)
        for name in ['lib.sh', 'own-draft-check.sh']:
            source = PROVIDERS[provider] / 'session-chat/scripts' / name
            if source.exists(): shutil.copyfile(source, scripts / name)
        for meta in ['.claude-plugin', '.codex-plugin']:
            (chat / meta).mkdir()
            (chat / meta / 'plugin.json').write_text('{"version":"0.17.18"}')
        (scripts / 'get-my-name.sh').write_text('printf "%s" "$PROBE_ACTOR"\n')
        (scripts / 'dispatch-to-session.sh').write_text('''printf '%s\\n' "$1" >> "$PROBE_LOG/dispatch.log"
cp "$2" "$PROBE_LOG/payload.md"
[ "${PROBE_DISPATCH:-ok}" != fail ] || { printf '%s\\n' 'fixture: no pane named reviewer' "${PROBE_ID_STDERR:-}" >&2; exit 1; }
if [ "${PROBE_DISPATCH:-ok}" = queued ]; then echo "Queued dispatch to '$1'"; else echo "Dispatched task to '$1'"; fi
[ -z "${PROBE_ID_OUTPUT:-}" ] || printf '%s\\n' "$PROBE_ID_OUTPUT"
[ -z "${PROBE_ID_STDERR:-}" ] || printf '%s\\n' "$PROBE_ID_STDERR" >&2
exit 0
''')
        (scripts / 'send-message.sh').write_text('printf "%s\\n" "$2" >> "$PROBE_LOG/send.log"\nexit "${PROBE_SEND_RC:-0}"\n')
        bindir = base / 'bin'; bindir.mkdir()
        tmux = bindir / 'tmux'; tmux.write_text('#!/bin/sh\nprintf "%s" "$PROBE_ACTOR"\n'); tmux.chmod(0o700)
        messages = base / 'messages'
        for actor in ['reviewer', 'foreign', 'executor']:
            (messages / 'drafts' / actor).mkdir(parents=True, exist_ok=True)
        for directory in [messages, messages / 'drafts', *(messages / 'drafts').iterdir()]: directory.chmod(0o700)
        log = base / 'log'; log.mkdir()
        env = dict(self.env, SESSION_SCHEDULER_HOME=str(base / 'scheduler'),
                   SESSION_CHAT_ROOT_OVERRIDE=str(chat), SESSION_CHAT_TARGET_MESSAGES_DIR=str(messages),
                   PATH=str(bindir)+os.pathsep+self.env['PATH'], TMUX='fixture', TMUX_PANE='%1',
                   PROBE_LOG=str(log), PROBE_ID_OUTPUT='Message id: aaaaaaaaaaaaaaaa')
        return {'provider': provider, 'base': base, 'env': env, 'log': log, 'messages': messages,
                'scripts': PROVIDERS[provider] / 'session-scheduler/scripts'}

    def run_helper(self, f, actor, script, *args, ok=True, extra=None):
        env = dict(f['env'], PROBE_ACTOR=actor, SESSION_CHAT_PANE_NAME=actor, **(extra or {}))
        result = subprocess.run(['bash', str(f['scripts'] / script), *args], env=env,
                                capture_output=True, text=True, timeout=35)
        if ok: self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def task_path(self, f, task): return Path(f['env']['SESSION_SCHEDULER_HOME']) / 'tasks' / (task+'.json')
    def data(self, f, task): return json.loads(self.task_path(f, task).read_text())
    def reset_log(self, f):
        for path in f['log'].iterdir(): path.unlink()

    def new(self, f, review=True):
        self.run_helper(f, 'master', 'task-new.sh', 'verdict fixture', '--reviewer', 'reviewer')
        task = max((Path(f['env']['SESSION_SCHEDULER_HOME']) / 'tasks').glob('*.json'), key=lambda p: p.stat().st_mtime_ns).stem
        self.run_helper(f, 'master', 'task-assign.sh', 'executor', task, 'work')
        if review: self.run_helper(f, 'executor', 'task-review.sh', task, 'ready')
        self.reset_log(f)
        return task

    def draft(self, f, body=b'Approve\nComplete verdict with unicode: \xc3\xa9\n', actor='reviewer'):
        path = f['messages'] / 'drafts' / actor / 'verdict.md'
        path.write_bytes(body); path.chmod(0o600)
        return path

    def event(self, f, task):
        events = self.data(f, task)['meta']['verdict_events']
        self.assertEqual(len(events), 1)
        return next(iter(events.values()))

    def test_full_verdict_transition_notification_and_cleanup(self):
        for provider in PROVIDERS:
            for op in ['done', 'block']:
                with self.subTest(provider=provider, operation=op):
                    f = self.fixture(provider, op); task = self.new(f); draft = self.draft(f); body = draft.read_bytes()
                    self.run_helper(f, 'reviewer', f'task-{op}.sh', task, '--note-file', str(draft))
                    event = self.event(f, task)
                    self.assertEqual(self.data(f, task)['status'], 'done' if op == 'done' else 'blocked')
                    self.assertEqual(event['request_msg_id'], 'a'*16)
                    self.assertIsNone(event['generation'])
                    self.assertEqual((event['actor'], event['route_to'], event['notification']['state']), ('reviewer','master','delivered'))
                    self.assertEqual(Path(event['artifact']).read_bytes(), body)
                    self.assertEqual(event['artifact_sha256'], hashlib.sha256(body).hexdigest())
                    self.assertEqual((f['log'] / 'dispatch.log').read_text(), 'master\n')
                    self.assertIn(body, (f['log'] / 'payload.md').read_bytes())
                    ve = next(iter(self.data(f, task)['meta']['verdict_events']))
                    self.assertTrue((f['log'] / 'payload.md').read_text().startswith(f'[task:{task}] [event:{ve}] '))
                    self.assertFalse((f['log'] / 'send.log').exists()); self.assertFalse(draft.exists())
                    self.assertNotIn('[re:', (f['log'] / 'payload.md').read_text())

    def test_queued_fallback_and_unconfirmed_failure(self):
        for provider in PROVIDERS:
            for dispatch, send, wanted in [('queued','0','queued'), ('fail','0','inline-fallback'), ('fail','1','failed')]:
                with self.subTest(provider=provider, state=wanted):
                    f=self.fixture(provider,wanted);task=self.new(f);draft=self.draft(f)
                    self.run_helper(f,'reviewer','task-done.sh',task,'--note-file',str(draft), extra={'PROBE_DISPATCH':dispatch,'PROBE_SEND_RC':send})
                    self.assertEqual(self.event(f,task)['notification']['state'],wanted)
                    self.assertEqual((f['log']/'dispatch.log').read_text(),'master\n')
                    self.assertEqual((f['log']/'send.log').exists(),dispatch=='fail')
                    if dispatch == 'fail':
                        pointer = (f['log']/'send.log').read_text()
                        ve = next(iter(self.data(f, task)['meta']['verdict_events']))
                        self.assertIn(task, pointer); self.assertIn(ve, pointer)
                        self.assertIn(f'full verdict recorded: task-status {task}', pointer)
                    before=self.task_path(f,task).read_bytes()
                    output=self.run_helper(f,'master','task-status.sh',task).stdout
                    self.assertEqual(before,self.task_path(f,task).read_bytes())
                    if wanted=='failed':
                        self.assertIn('delivery not confirmed',output);self.assertNotIn('not delivered',output)

    def test_refusals_have_no_transition_and_valid_controls(self):
        for provider in PROVIDERS:
            for op, case in [(op, case) for op in ['done', 'block'] for case in ['foreign','oversize','nul','utf8','missing-helper','generation']]:
                with self.subTest(provider=provider, operation=op, case=case):
                    f=self.fixture(provider,op+'-'+case);task=self.new(f);extra={};args=[]
                    body={'nul':b'before\0after','utf8':b'broken\xff'}.get(case,b'complete verdict')
                    draft=self.draft(f,body,actor='foreign' if case=='foreign' else 'reviewer')
                    if case=='oversize':extra={'SESSION_SCHEDULER_NOTE_MAX_BYTES':'2'}
                    helper=Path(f['env']['SESSION_CHAT_ROOT_OVERRIDE'])/'scripts/own-draft-check.sh'
                    saved=helper.read_bytes() if helper.exists() else None
                    if case=='missing-helper' and helper.exists():helper.unlink()
                    if case=='generation':args=['--generation','1']
                    before=self.task_path(f,task).read_bytes()
                    result=self.run_helper(f,'reviewer',f'task-{op}.sh',task,*args,'--note-file',str(draft),ok=False,extra=extra)
                    self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                    self.assertEqual(before,self.task_path(f,task).read_bytes())
                    self.assertFalse(list((Path(f['env']['SESSION_SCHEDULER_HOME'])/'prompts').glob('*-verdict-*.md')))
                    self.assertFalse((f['log']/'dispatch.log').exists());self.assertTrue(draft.exists())
                    if saved is not None:helper.write_bytes(saved)
                    control=self.draft(f)
                    self.run_helper(f,'reviewer',f'task-{op}.sh',task,'--note-file',str(control))
                    self.assertEqual(self.event(f,task)['notification']['state'],'delivered')

    def test_status_lists_keep_event_rows_outside_task_table(self):
        for provider in PROVIDERS:
            with self.subTest(provider=provider):
                f=self.fixture(provider,'status-list'); task=self.new(f)
                # Control: no event block before a verdict exists.
                header='Verdict events (observational; run task-status <id> for the full verdict):'
                self.assertNotIn(header,self.run_helper(f,'master','task-status.sh','--all').stdout)
                self.run_helper(f,'reviewer','task-done.sh',task,'--note-file',str(self.draft(f)))
                ve=next(iter(self.data(f,task)['meta']['verdict_events']))
                before=self.task_path(f,task).read_bytes()
                for mode in ['--all','--mine']:
                    output=self.run_helper(f,'master','task-status.sh',mode).stdout
                    self.assertIn(header,output)
                    table,events=output.split(header,1)
                    self.assertIn(task,table); self.assertNotIn(ve,table)
                    self.assertIn(ve,events); self.assertIn(task,events)
                self.assertEqual(before,self.task_path(f,task).read_bytes())

    def test_codex_review_dispatch_failure_preserves_stderr(self):
        f=self.fixture('codex','review-stderr'); task=self.new(f,review=False)
        result=self.run_helper(f,'executor','task-review.sh',task,'ready',extra={
            'PROBE_DISPATCH':'fail','PROBE_ID_STDERR':'Message id: '+'c'*16})
        self.assertIn('fixture: no pane named reviewer',result.stderr)
        self.assertIsNone(self.data(f,task)['meta'].get('review_request_msg_id'))
        # A successful dispatch records its stdout ID, even with a different stderr ID.
        self.run_helper(f,'executor','task-review.sh',task,'ready',extra={'PROBE_ID_STDERR':'Message id: '+'c'*16})
        self.assertEqual(self.data(f,task)['meta']['review_request_msg_id'],'a'*16)

    def test_reassignment_clears_request_id(self):
        for provider in PROVIDERS:
            with self.subTest(provider=provider):
                f=self.fixture(provider,'reassign'); task=self.new(f)
                self.assertEqual(self.data(f,task)['meta']['review_request_msg_id'],'a'*16)
                self.run_helper(f,'reviewer','task-block.sh',task,'revise')
                self.run_helper(f,'master','task-assign.sh','executor',task,'revised work')
                self.assertIsNone(self.data(f,task)['meta'].get('review_request_msg_id'))
                self.run_helper(f,'executor','task-review.sh',task,'ready',extra={'PROBE_ID_OUTPUT':'Message id: '+'b'*16})
                self.assertEqual(self.data(f,task)['meta']['review_request_msg_id'],'b'*16)

    def test_request_id_is_stdout_only_and_unknown_on_ambiguous_output(self):
        for provider in PROVIDERS:
            for name, output, expected in [('valid','Message id: '+'b'*16,'b'*16),('missing','',None),('duplicate','Message id: '+'a'*16+'\nMessage id: '+'b'*16,None),('malformed','Message id: bad-id',None),('stderr-only','',None)]:
                with self.subTest(provider=provider,case=name):
                    f=self.fixture(provider,'id-'+name);task=self.new(f,review=False)
                    self.run_helper(f,'executor','task-review.sh',task,'ready',extra={'PROBE_ID_OUTPUT':output,'PROBE_ID_STDERR':'Message id: '+'c'*16 if name=='stderr-only' else ''})
                    self.assertEqual(self.data(f,task)['meta']['review_request_msg_id'],expected)

    def test_contract_admission_and_notification_are_compatible(self):
        for provider in PROVIDERS:
            for op in ['done','block']:
                with self.subTest(provider=provider,operation=op):
                    f=self.fixture(provider,'contract-'+op)
                    repo=f['base']/'repo';repo.mkdir();(repo/'check.sh').write_text('#!/bin/sh\nexit 0\n')
                    for args in [['init','-q'],['add','.'],['-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture']]:
                        subprocess.run(['git','-C',str(repo),*args],env=self.env,check=True,capture_output=True)
                    spec=f['base']/'spec.json';spec.write_text(json.dumps({'schema_version':1,'repository':str(repo),'checks':[{'id':'unit','script':'check.sh','args':[],'timeout_seconds':10}],'ttl_seconds':600,'max_attempts':3}))
                    self.run_helper(f,'master','task-new.sh','contract fixture','--reviewer','reviewer')
                    task=next((Path(f['env']['SESSION_SCHEDULER_HOME'])/'tasks').glob('*.json')).stem
                    self.run_helper(f,'master','task-contract.sh','attach',task,'--spec',str(spec))
                    self.run_helper(f,'master','task-contract.sh','assign','executor',task,'work')
                    inspection=self.run_helper(f,'master','task-contract.sh','inspect',task,ok=False)
                    self.assertEqual(inspection.returncode,1)
                    inspected=json.loads(inspection.stdout)
                    self.assertEqual(inspected['state'],'active')
                    self.run_helper(f,'executor','task-contract.sh','verify',task,'--generation','1','--spec-digest',inspected['spec_digest'])
                    self.run_helper(f,'executor','task-review.sh',task,'--generation','1','ready');self.reset_log(f)
                    draft=self.draft(f)
                    for refused_args in [[], ['--generation','1','--force']]:
                        before=self.task_path(f,task).read_bytes()
                        result=self.run_helper(f,'reviewer',f'task-{op}.sh',task,*refused_args,'--note-file',str(draft),ok=False)
                        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
                        self.assertEqual(before,self.task_path(f,task).read_bytes())
                        self.assertTrue(draft.exists()); self.assertFalse((f['log']/'dispatch.log').exists())
                        self.assertFalse(list((Path(f['env']['SESSION_SCHEDULER_HOME'])/'prompts').glob('*-verdict-*.md')))
                    self.run_helper(f,'reviewer',f'task-{op}.sh',task,'--generation','1','--note-file',str(draft))
                    event=self.event(f,task);self.assertEqual(event['generation'],1);self.assertEqual(event['request_msg_id'],'a'*16)
                    self.assertEqual(event['notification']['state'],'delivered')
                    self.assertEqual((f['log']/'dispatch.log').read_text(),'master\n')
                    if op=='done':
                        data=self.data(f,task)
                        self.assertEqual(hashlib.sha256(json.dumps(data['history'],sort_keys=True,separators=(',',':')).encode()).hexdigest(),data['contract']['admission']['history'])
                        self.assertEqual(json.loads(self.run_helper(f,'master','task-contract.sh','inspect',task).stdout)['state'],'admitted')

    def test_corrupt_artifact_is_not_displayed_and_status_does_not_write(self):
        for provider in PROVIDERS:
            with self.subTest(provider=provider):
                f=self.fixture(provider,'status');task=self.new(f);draft=self.draft(f)
                self.run_helper(f,'reviewer','task-done.sh',task,'--note-file',str(draft))
                event=self.event(f,task);before=self.task_path(f,task).read_bytes()
                self.assertIn('Complete verdict',self.run_helper(f,'master','task-status.sh',task).stdout)
                Path(event['artifact']).write_text('UNVERIFIED SENTINEL')
                output=self.run_helper(f,'master','task-status.sh',task).stdout
                self.assertNotIn('UNVERIFIED SENTINEL',output);self.assertIn('body not shown',output)
                self.assertEqual(before,self.task_path(f,task).read_bytes())

    def test_cleanup_preserves_live_and_dual_owned_verdict_files(self):
        for provider in PROVIDERS:
            with self.subTest(provider=provider):
                f=self.fixture(provider,'cleanup');old=self.new(f)
                self.run_helper(f,'reviewer','task-done.sh',old,'--note-file',str(self.draft(f)))
                old_event=self.event(f,old);artifact=Path(old_event['artifact'])
                notice=artifact.with_name(artifact.stem+'-notice.md');notice_before=notice.read_bytes()
                # A distinct surviving task owns the notice filename as its base prompt.
                live_data=self.data(f,old);live_data.update(id=notice.stem,status='assigned',meta={})
                self.task_path(f,notice.stem).write_text(json.dumps(live_data))
                old_data=self.data(f,old);old_data['updated_at']='2000-01-01T00:00:00Z'
                self.task_path(f,old).write_text(json.dumps(old_data))
                orphan=artifact.parent/'missing-task-verdict-1111111111111111.md'
                orphan.write_text('aged orphan');os.utime(orphan,(946684800,946684800))
                young=artifact.parent/'young-task-verdict-2222222222222222.md';young.write_text('young orphan')
                self.run_helper(f,'master','tasks-clean.sh','--older-than','30')
                self.assertTrue(artifact.exists());self.assertTrue(orphan.exists())
                self.run_helper(f,'master','tasks-clean.sh','--older-than','30','--apply')
                self.assertFalse(self.task_path(f,old).exists());self.assertFalse(artifact.exists());self.assertFalse(orphan.exists())
                self.assertEqual(notice.read_bytes(),notice_before);self.assertTrue(young.exists())
                self.assertTrue(self.task_path(f,notice.stem).exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
