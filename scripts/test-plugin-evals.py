#!/usr/bin/env python3
"""Validate portable fixture boundaries and event grading without model calls."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location("plugin_evals",os.environ.get("PLUGIN_EVALS_TEST_RUNNER",str(Path(__file__).with_name("plugin-evals.py"))))
runner=importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class Scenarios(unittest.TestCase):
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
