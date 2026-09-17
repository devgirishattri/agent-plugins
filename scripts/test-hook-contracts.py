#!/usr/bin/env python3
import copy
import unittest
import warnings
from hook_contracts import CODEX_EVENTS, CLAUDE_EVENTS, validate_codex, validate_claude

def doc(handler, event="SessionStart"):
    return {"hooks": {event: [{"hooks": [handler]}]}}

class Hooks(unittest.TestCase):
    def test_claude_ignored_fields(self):
        command={"type":"command","command":"x"}
        for field,value in (("once",True),("if","true")):
            with warnings.catch_warnings(record=True) as seen:
                warnings.simplefilter("always")
                validate_claude(doc({**command,field:value},"UserPromptSubmit"))
                self.assertEqual(len(seen),1)
        for matcher,count in (("",0),("Bash",1)):
            item=doc(command,"UserPromptSubmit")
            item["hooks"]["UserPromptSubmit"][0]["matcher"]=matcher
            with warnings.catch_warnings(record=True) as seen:
                warnings.simplefilter("always"); validate_claude(item)
                self.assertEqual(len(seen),count)
        with warnings.catch_warnings(record=True) as seen:
            warnings.simplefilter("always")
            validate_claude(doc({**command,"if":"true"},"PreToolUse"))
            validate_claude(doc(command,"UserPromptSubmit"))
            self.assertEqual(len(seen),0)

    def test_claude_field_ownership(self):
        command={"type":"command","command":"x"}
        for field,value in (("headers",{}),("allowedEnvVars",[]),("input",{}),("model","sonnet")):
            with self.subTest(field=field),self.assertRaises(ValueError):
                validate_claude(doc({**command,field:value}))
            validate_claude(doc(command))
        validate_claude(doc({"type":"http","url":"https://example.invalid","headers":{},"allowedEnvVars":[]}))
        validate_claude(doc({"type":"mcp_tool","server":"s","tool":"t","input":{}}))
        validate_claude(doc({"type":"prompt","prompt":"x","model":"sonnet"}))
    def test_claude_events_and_handlers(self):
        for event in CLAUDE_EVENTS:
            validate_claude(doc({"type":"command","command":"bash ${CLAUDE_PLUGIN_ROOT}/run.sh"},event))
        for handler in ({"type":"http","url":"https://example.invalid"},
                        {"type":"prompt","prompt":"check"},{"type":"agent","prompt":"check"},
                        {"type":"mcp_tool","server":"s","tool":"t"}):
            validate_claude(doc(handler))
    def test_claude_invalid(self):
        for item in (doc({"type":"http"}),doc({"type":"agent"}),
                     doc({"type":"command","command":"x","timeout":True}),
                     doc({"type":"mcp_tool","server":"s","tool":"t","async":True}),
                     doc({"type":"command","command":"x"},"Unknown")):
            with self.assertRaises(ValueError): validate_claude(item)
    def test_command_events(self):
        for event in CODEX_EVENTS:
            validate_codex(doc({"type":"command","command":"bash $PLUGIN_ROOT/scripts/test.sh"},event))
    def test_mcp(self):
        validate_codex(doc({"type":"mcp_tool","server":"lint","tool":"check","input":{}},"PostToolUse"))
    def test_invalid_contracts(self):
        command={"type":"command","command":"bash $PLUGIN_ROOT/scripts/test.sh"}
        cases=[doc(command,"TypoEvent"), doc({"type":"prompt","prompt":"x"}),
               doc({"type":"agent"}),doc({"type":"mcp_tool","server":"lint"}),
               doc({"type":"mcp_tool","server":"s","tool":"t"},"SessionEnd"),
               doc({**command,"timeout":4},"Interrupt"),
               doc({**command,"command":"bash /tmp/plugins/cache/a/b/run.sh"}),
               doc({**command,"async":"true"}),doc({**command,"timeout":True}),
               doc({**command,"unknownCapability":True}),
               doc({**command,"timeout":float("nan")}),doc({**command,"timeout":-1}),
               doc({**command,"additionalContextLimit":-1}),
               doc({"type":"mcp_tool","server":"s","tool":"t","input":[]})]
        for item in cases:
            with self.subTest(item=item), self.assertRaises(ValueError):
                validate_codex(copy.deepcopy(item))

if __name__ == "__main__":
    unittest.main()
