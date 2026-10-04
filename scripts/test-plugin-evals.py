#!/usr/bin/env python3
"""Validate portable fixture boundaries and event grading without model calls."""
import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import sys
import unittest
from unittest.mock import patch,Mock

spec=importlib.util.spec_from_file_location("plugin_evals",os.environ.get("PLUGIN_EVALS_TEST_RUNNER",str(Path(__file__).with_name("plugin-evals.py"))))
runner=importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class Scenarios(unittest.TestCase):
    def test_main_requires_budget_and_allocates_native_caps(self):
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory);root=base/'repo';folder=root/'plugins/knowledge/evals/case-one';folder.mkdir(parents=True)
            (folder/'case.json').write_text(json.dumps({'id':'case-one','prompt':'Do the task','kind':'contract'}))
            second=folder.with_name('case-two');second.mkdir()
            (second/'case.json').write_text(json.dumps({'id':'case-two','prompt':'Do another task','kind':'contract'}))
            common=['--run','--provider','claude','--output',str(base/'report.json')]
            with patch.object(runner,'ROOT',root),patch.object(runner,'probe_claude',return_value={'status':'completed','reported_cost_usd':0}) as probe,contextlib.redirect_stderr(io.StringIO()),contextlib.redirect_stdout(io.StringIO()):
                for args in [common,*[common+['--max-cost-usd',cap] for cap in ['0','nan','1000']],common+['--max-cost-usd','1','--provider','codex']]:
                    with patch.object(sys,'argv',['runner',*args]),self.assertRaises(SystemExit):runner.main()
                    probe.assert_not_called()
                with patch.object(sys,'argv',['runner']):runner.main()
                probe.assert_not_called()
                with patch.object(sys,'argv',['runner',*common,'--max-cost-usd','1','--output',str(root/'README.md')]),self.assertRaises(SystemExit):runner.main()
                probe.assert_not_called()
                with patch.object(sys,'argv',['runner',*common,'--max-cost-usd','1','--max-cases','2']):runner.main()
                self.assertEqual(probe.call_count,2)
                self.assertEqual([call.args[-1] for call in probe.call_args_list],[.5,.5])
                self.assertEqual(json.loads((base/'report.json').read_text())['provider'],'claude')
                probe.reset_mock();probe.return_value={'status':'completed','reported_cost_usd':1}
                with patch.object(sys,'argv',['runner',*common,'--max-cost-usd','1','--max-cases','2']):runner.main()
                self.assertEqual(probe.call_count,1)
                probe.reset_mock();probe.side_effect=ValueError('missing baseline')
                with patch.object(sys,'argv',['runner',*common,'--max-cost-usd','1']):runner.main()
                self.assertEqual(json.loads((base/'report.json').read_text())['runs'][0]['status'],'infrastructure_error')

    def test_output_is_ignored_and_plugin_mount_excludes_graders(self):
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory);root=base/'repo';root.mkdir()
            runner.subprocess.run(['git','init','-q',str(root)],check=True)
            (root/'.gitignore').write_text('.tmp/\n')
            with patch.object(runner,'ROOT',root):
                self.assertFalse(runner.output_allowed(root/'README.md'))
                self.assertTrue(runner.output_allowed(root/'.tmp/report.json'))
                self.assertTrue(runner.output_allowed(base/'report.json'))
            source=base/'source';(source/'evals').mkdir(parents=True);(source/'evals/case.json').write_text('hidden grader')
            (source/'SKILL.md').write_text('actual instructions')
            work=base/'workspace';work.mkdir();installed=runner.mount_plugin(source,work)
            self.assertFalse((installed/'evals').exists());self.assertEqual((installed/'SKILL.md').read_text(),'actual instructions')

    def test_broken_stdin_still_stops_process(self):
        for error in [None,BrokenPipeError()]:
            conversation=runner.ClaudeConversation.__new__(runner.ClaudeConversation)
            conversation.process=Mock();conversation.process.stdin.close.side_effect=error
            conversation.reader=Mock();conversation.err_reader=Mock()
            with patch.object(runner,'stop_group') as stop:
                conversation.close();stop.assert_called_once_with(conversation.process)
                conversation.process.wait.assert_called_once()

    def test_event_volume_limit_stops_the_turn(self):
        with tempfile.TemporaryDirectory() as directory:
            code="import sys;sys.stdin.readline();print('x'*1000,flush=True);sys.stdin.read()"
            with patch.object(runner,'MAX_EVENT_BYTES',100):
                conversation=runner.ClaudeConversation([sys.executable,'-u','-c',code],os.environ.copy(),Path(directory))
                try:
                    with self.assertRaisesRegex(RuntimeError,'event byte limit'):conversation.turn('go',2)
                finally:conversation.close()

    def test_early_process_exit_keeps_cleanup_safe(self):
        with tempfile.TemporaryDirectory() as directory:
            conversation=runner.ClaudeConversation([sys.executable,'-c','pass'],os.environ.copy(),Path(directory))
            # Observe EOF without reaping the leader; Darwin retains a zombie group.
            self.assertIsNone(conversation.queue.get(timeout=2))
            conversation.close()
            self.assertIsNotNone(conversation.process.returncode)

    def test_environment_baseline_and_artifact_limits(self):
        with patch.dict(os.environ,{'GITHUB_TOKEN':'private','AWS_SECRET_ACCESS_KEY':'private','OPENAI_API_KEY':'private','SESSION_CONTEXT_HOME':'real','PATH':'/bin'},clear=True):
            self.assertEqual(runner.probe_environment(),{'PATH':'/bin'})
        case={'postcheck':{'script':'check.sh','args':['unchanged']}}
        with self.assertRaises(ValueError):runner.require_baselines(case,{})
        runner.require_baselines(case,{'.eval-snapshot':'hash'})
        with tempfile.TemporaryDirectory() as directory:
            workspace=Path(directory);(workspace/'small.md').write_text('small');(workspace/'large').write_bytes(b'x'*100001)
            evidence=runner.artifact_evidence(workspace)
            self.assertEqual(evidence['artifacts'],{'small.md':'small'});self.assertIn('large',evidence['omitted_artifacts'])
            with patch.object(runner,'MAX_ARTIFACT_FILES',0):self.assertEqual(runner.artifact_evidence(workspace)['artifacts'],{})
            (workspace/'alias').symlink_to(workspace/'small.md')
            with self.assertRaises(ValueError):runner.inside(workspace,'alias')

    def test_conversation_sends_separate_real_user_turns(self):
        fake="""import sys,json
for line in sys.stdin:
 message=json.loads(line)
 assert message['type']=='user' and message['message']['role']=='user'
 print(json.dumps({'type':'result','subtype':'success','result':message['message']['content'],'total_cost_usd':0}),flush=True)
"""
        with tempfile.TemporaryDirectory() as directory:
            conversation=runner.ClaudeConversation([sys.executable,'-u','-c',fake],os.environ.copy(),Path(directory))
            try:
                _,first=conversation.turn('Prepare the batch',2)
                self.assertEqual(first['result'],'Prepare the batch')
                _,second=conversation.turn('I approve the displayed hash',2)
                self.assertEqual(second['result'],'I approve the displayed hash')
                self.assertEqual([e['probe_input']['role'] for e in conversation.events if 'probe_input' in e],['user','user'])
            finally:conversation.close()

    def test_postcheck_source_and_baseline_are_pinned(self):
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory);evals=base/'evals';folder=evals/'case-one';folder.mkdir(parents=True)
            script=evals/'check.sh';script.write_text('[ "$1" = candidate ] && [ -f "$2/saved.md" ]\n')
            workspace=base/'workspace';workspace.mkdir();(workspace/'.eval-snapshot').write_text('original')
            path=folder/'case.json';path.write_text('{}')
            subject=runner.tree_digest(evals);baselines=runner.fixture_baselines(workspace)
            check={'script':'check.sh','args':['candidate']}
            def result():return runner.postcheck(check,path,workspace,os.environ.copy(),subject,baselines)['passed']
            self.assertFalse(result())
            (workspace/'saved.md').write_text('artifact');self.assertTrue(result())
            (workspace/'.eval-manifest.md').write_text('new review scratch');self.assertTrue(result())
            (workspace/'.eval-snapshot').write_text('forged');self.assertFalse(result())
            (workspace/'.eval-snapshot').write_text('original');self.assertTrue(result())
            script.write_text('exit 0');self.assertFalse(result())

    def test_manifest_replies_require_displayed_current_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace=Path(directory);manifest=workspace/'manifest.md';manifest.write_text('exact reviewed batch')
            case={'manifest':'manifest.md'};digest=runner.hashlib.sha256(manifest.read_bytes()).hexdigest()
            with self.assertRaises(ValueError):runner.manifest_reply('approve_manifest',case,workspace,'Approved')
            message,binding=runner.manifest_reply('approve_manifest',case,workspace,'SHA-256 '+digest)
            self.assertIn(digest,message);self.assertEqual(binding['reply_hash'],digest)
            message,binding=runner.manifest_reply('mismatched_manifest',case,workspace,digest)
            self.assertNotEqual(binding['reply_hash'],digest);self.assertEqual(manifest.read_text(),'exact reviewed batch')
            message,binding=runner.manifest_reply('tamper_manifest_then_approve',case,workspace,digest)
            self.assertIn(digest,message);self.assertNotEqual(runner.hashlib.sha256(manifest.read_bytes()).hexdigest(),digest)
            with self.assertRaises(ValueError):runner.manifest_reply('approve_manifest',case,workspace,digest)
            manifest.unlink();manifest.symlink_to(workspace/'missing')
            with self.assertRaises(ValueError):runner.manifest_reply('approve_manifest',case,workspace,digest)

    def test_claude_requires_correlated_completed_success(self):
        call={'type':'assistant','message':{'content':[{'type':'tool_use','id':'t1','name':'Bash','input':{'command':'bash /installed/writer.sh'}}]}}
        reply={'type':'user','message':{'content':[{'type':'tool_result','tool_use_id':'t1','is_error':False,'content':'exit 0'}]},'tool_use_result':{'interrupted':False}}
        self.assertEqual(runner.claude_events([call]),[])
        self.assertEqual(runner.claude_events([reply]),[])
        self.assertEqual(runner.claude_events([call,reply])[0]['item']['exit_code'],0)
        interrupted={**reply,'tool_use_result':{'interrupted':True}}
        self.assertIsNone(runner.claude_events([call,interrupted])[0]['item']['exit_code'])
        failed={**reply,'message':{'content':[{'type':'tool_result','tool_use_id':'t1','is_error':True,'content':'exit 0'}]}}
        self.assertIsNone(runner.claude_events([call,failed])[0]['item']['exit_code'])
        self.assertEqual(len(runner.claude_events([call,reply,reply])),1)

    def test_followup_and_postcheck_schema(self):
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory);folder=base/'case-one';folder.mkdir();path=folder/'case.json'
            (base/'check.sh').write_text('exit 0')
            case={'id':'case-one','kind':'contract','prompt':'Wrap up','manifest':'.tmp/manifest.md',
                  'postcheck':{'script':'check.sh','args':['unchanged']},'followups':[{'reply':'approve_manifest'}]}
            path.write_text(json.dumps(case));self.assertEqual(runner.validate(path),case)
            for changes in [{'manifest':'../outside.md'},{'followups':'x'},
                            {'followups':[{'reply':'invent_approval'}]},
                            {'followups':[{'prompt':'x','reply':'approve_manifest'}]},
                            {'postcheck':{'script':'../outside.sh','args':[]}},
                            {'postcheck':{'script':'check.sh','args':'unchanged'}}]:
                path.write_text(json.dumps({**case,**changes}))
                with self.subTest(changes=changes),self.assertRaises(ValueError):runner.validate(path)

    def test_trusted_tree_path_symlink_digest_and_argument_controls(self):
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory);root=base/'installed';root.mkdir()
            script=root/'verify.sh';script.write_text('exit 0')
            other=root/'other.sh';other.write_text('exit 0')
            library=root/'lib.py';library.write_text('unchanged')
            workspace=base/'workspace';workspace.mkdir()
            clone=workspace/'verify.sh';clone.write_text('exit 0')
            alias=base/'verify.sh';alias.symlink_to(script)
            trusted=runner.trust_tree(root)
            case={'expectations':{'executions':[{'script':'verify.sh','exit_code':0,'args_prefix':['verify']}]}}
            def check(path,args='verify T1'):
                event={'type':'item.completed','item':{'type':'command_execution','command':'bash '+str(path)+' '+args,'exit_code':0}}
                return runner.grade(case,[event],workspace,trusted)['execution:0:verify.sh']
            self.assertTrue(check(script));self.assertFalse(check(other));self.assertFalse(check(clone));self.assertFalse(check(alias))
            self.assertFalse(check(script,'--help'));self.assertFalse(check(script,'inspect T1'))
            script.write_text('exit 0 # changed');self.assertFalse(check(script));script.write_text('exit 0')
            library.write_text('changed');self.assertFalse(check(script));library.write_text('unchanged')
            self.assertTrue(check(script))
            case['expectations']['executions'][0].pop('args_prefix');case['expectations']['executions'][0]['args']=['verify','T1']
            self.assertTrue(check(script));self.assertFalse(check(script,'verify T2'))
            # macOS reports both /var and /private/var spellings in real traces.
            self.assertTrue(check(script.resolve()))

    def test_execution_receipts_require_actual_success_and_counts(self):
        with tempfile.TemporaryDirectory() as directory:
            script=Path(directory)/"verify.sh";script.write_text("exit 0")
            trusted=runner.trust_tree(Path(directory))
            case={"expectations":{"executions":[{"script":"verify.sh","exit_code":0,"min_count":1,"max_count":1}]}}
            key="execution:0:verify.sh"
            good={"type":"item.completed","item":{"type":"command_execution","command":"bash "+str(script),"exit_code":0}}
            self.assertTrue(runner.grade(case,[good],Path(directory),trusted).get(key,False))
            wrapped={**good,'item':{**good['item'],'command':"/bin/zsh -lc 'bash "+str(script)+"'"}}
            self.assertTrue(runner.grade(case,[wrapped],Path(directory),trusted).get(key,False))
            self.assertFalse(runner.grade(case,[good],Path(directory)).get(key,False))
            bad_events=[[],[{"type":"item.completed","item":{"type":"agent_message","text":"bash /fixture/verify.sh passed"}}],
                        [{**good,"type":"item.started"}], [good,good]]
            for command,code in [("echo bash /fixture/verify.sh",0),("bash /fixture/verify.sh",1),
                                 ("bash /fixture/verify.sh",None),("bash /fixture/verify.sh",False),
                                 ("bash /fixture/verify.sh || true",0),("bash /fixture/verify.sh > output",0),
                                 ("bash /fixture/verify.sh >> output",0),("bash -c 'verify.sh'",0),("bash /fixture/verify.sh\ntrue",0),("bash /fixture/verify.sh\rtrue",0),("bash /fixture/verify.sh\n",0),("bash ./verify.sh",0),("bash /untrusted/verify.sh",0)]:
                command=command.replace('/fixture/verify.sh',str(script))
                bad_events.append([{**good,"item":{**good['item'],"command":command,"exit_code":code}}])
            for events in bad_events:
                with self.subTest(events=events): self.assertFalse(runner.grade(case,events,Path(directory),trusted).get(key,False))

    def test_json_artifacts_not_prose_and_not_boolean_number_equivalence(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); path=root/'result.json'
            case={"expectations":{"json_contains":{"result.json":{"state":"done","verified":True}}}}
            key='json:result.json'
            for value in [None,'not json',json.dumps({'state':'done','verified':1}),json.dumps({'state':'done'})]:
                if value is not None: path.write_text(value)
                self.assertFalse(runner.grade(case,[],root).get(key,False))
            path.write_text(json.dumps({'state':'done','verified':True,'other':'allowed'}))
            self.assertTrue(runner.grade(case,[],root).get(key,False))

    def test_new_expectation_schema(self):
        with tempfile.TemporaryDirectory() as directory:
            folder=Path(directory)/'case-one';folder.mkdir();path=folder/'case.json'
            base={'id':'case-one','kind':'contract','prompt':'Verify this change'}
            for expected in [{'executions':[{'script':'verify.sh','exit_code':0}]},
                             {'json_contains':{'result.json':{'state':'done'}}}]:
                path.write_text(json.dumps({**base,'expectations':expected}));runner.validate(path)
            for expected in [{'executions':'no'}, {'executions':[{'script':'../verify.sh','exit_code':0}]},
                             {'executions':[{'script':'verify.sh','exit_code':False}]},
                             *({'executions':[{'script':'verify.sh','exit_code':0,**bad}]} for bad in [{'args':'x'},{'args':[1]},{'args':[],'args_prefix':[]}]),
                             {'executions':[{'script':'verify.sh','exit_code':0,'min_count':2,'max_count':1}]},
                             {'json_contains':{'../result.json':{'state':'done'}}},{'json_contains':{'result.json':{}}}]:
                path.write_text(json.dumps({**base,'expectations':expected}))
                with self.subTest(expected=expected),self.assertRaises(ValueError): runner.validate(path)

    def test_schema_and_escape_rejection(self):
        with tempfile.TemporaryDirectory() as temp:
            folder=Path(temp)/"case-one"; folder.mkdir(); path=folder/"case.json"
            valid=dict(id="case-one",kind="contract",prompt="Check fixture",expectations={})
            path.write_text(json.dumps(valid)); self.assertEqual(runner.validate(path),valid)
            for changes in ({"expectations":[]},{"expectations":{"files":[]}},
                            {"expectations":{"files":{"../escape":True}}},
                            {"expectations":{"regex":["["]}},
                            {"scaffold":"/tmp/outside.sh"},{"kind":"unknown"},
                            {"unset_env":["HOME"]},{"unset_env":"SESSION_CONTEXT_HOME"}):
                path.write_text(json.dumps({**valid,**changes}))
                with self.subTest(changes=changes),self.assertRaises((ValueError,runner.re.error)):
                    runner.validate(path)

    def test_symlink_escape(self):
        with tempfile.TemporaryDirectory() as temp:
            base=Path(temp)/"workspace"; base.mkdir()
            (base/"outside").symlink_to(Path(temp),target_is_directory=True)
            with self.assertRaises(ValueError): runner.inside(base,"outside/file")

    def test_grading_uses_completed_events(self):
        with tempfile.TemporaryDirectory() as temp:
            base=Path(temp); (base/"expected.txt").touch()
            case={"expectations":{"regex":["ready"],"tool_used":["search.sh"],
                "forbidden_skills":["delete"],"files":{"expected.txt":True,"absent":False}}}
            events=[{"type":"item.completed","item":{"type":"agent_message","text":"ready"}},
                    {"type":"item.started","item":{"type":"command_execution","command":"search.sh"}}]
            self.assertFalse(runner.grade(case,events,base)["tool:search.sh"])
            events.append({"type":"item.completed","item":{"type":"command_execution",
                "command":"bash /fixture/search.sh"}})
            self.assertTrue(all(runner.grade(case,events,base).values()))
            events.append({"type":"item.completed","item":{"type":"command_execution",
                "command":"cat /plugin/skills/delete/SKILL.md"}})
            self.assertFalse(runner.grade(case,events,base)["no-skill:delete"])
            case["expectations"]["tool_used_any"]=["find.sh","search.sh"]
            self.assertTrue(runner.grade(case,events,base)["tool:any"])
            case["expectations"]["tool_used_any"]=["missing.sh"]
            self.assertFalse(runner.grade(case,events,base)["tool:any"])

if __name__=="__main__": unittest.main()
