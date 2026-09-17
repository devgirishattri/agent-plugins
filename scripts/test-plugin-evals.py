#!/usr/bin/env python3
"""Validate portable fixture boundaries and event grading without model calls."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location("plugin_evals",Path(__file__).with_name("plugin-evals.py"))
runner=importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class Scenarios(unittest.TestCase):
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
