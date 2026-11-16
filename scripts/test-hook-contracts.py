#!/usr/bin/env python3
import copy
import unittest
import warnings
from hook_contracts import (CODEX_EVENTS, CLAUDE_EVENTS, check_hook_intent, hook_output_effect,
                            validate_codex, validate_claude)

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
    def test_claude_on_failure(self):
        for kind,handler in (("command",{"type":"command","command":"x"}),("http",{"type":"http","url":"https://example.invalid"})):
            for value in ("continue","block"):
                validate_claude(doc({**handler,"onFailure":value},"PreToolUse"))
            for value in ("deny",True,None):
                with self.subTest(kind=kind,value=value),self.assertRaises(ValueError):
                    validate_claude(doc({**handler,"onFailure":value},"PreToolUse"))
        with self.assertRaises(ValueError):
            validate_claude(doc({"type":"prompt","prompt":"x","onFailure":"block"},"PreToolUse"))
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


class Outputs(unittest.TestCase):
    """Hook output contracts: what each runtime does with a hook's stdout."""

    def effect(self, provider, event, stdout, stderr="", code=0):
        return hook_output_effect(provider, event, stdout, stderr, code)

    def test_prompt_approve_with_system_message_is_rejected(self):
        # session-chat 0.17.21: queued messages printed this and never reached Claude.
        out = '{"decision":"approve","systemMessage":"session-chat: queued"}'
        for provider in ("claude", "codex"):
            with self.subTest(provider=provider), self.assertRaises(ValueError):
                self.effect(provider, "UserPromptSubmit", out)
        # Without the invalid decision it parses, but a context hook must not
        # put its text where only the user sees it.
        effect = self.effect("claude", "UserPromptSubmit", '{"systemMessage":"session-chat: queued"}')
        self.assertTrue(effect["user_message"])
        self.assertFalse(effect["model_context"])
        with self.assertRaises(ValueError):
            check_hook_intent("context", "UserPromptSubmit", effect)

    def test_stop_context_continues_the_turn(self):
        # knowledge 0.5.12: a user reminder sent as Stop additionalContext.
        out = '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"run consolidate"}}'
        effect = self.effect("claude", "Stop", out)
        self.assertTrue(effect["continues_turn"])
        for intent in ("notice", "continue-turn", "context"):
            with self.subTest(intent=intent), self.assertRaises(ValueError):
                check_hook_intent(intent, "Stop", effect)
        with self.assertRaises(ValueError):
            self.effect("codex", "Stop", out)  # Codex Stop has no hookSpecificOutput
        block = self.effect("codex", "Stop", '{"decision":"block","reason":"run consolidate"}')
        with self.assertRaises(ValueError):
            check_hook_intent("notice", "Stop", block)
        check_hook_intent("continue-turn", "Stop", block)
        notice = self.effect("codex", "Stop", '{"systemMessage":"run consolidate"}')
        check_hook_intent("notice", "Stop", notice)

    def test_plain_stdout(self):
        for provider in ("claude", "codex"):
            for event in ("SessionStart", "UserPromptSubmit"):
                self.assertTrue(self.effect(provider, event, "some context\n")["model_context"])
            for event in ("PreToolUse", "Stop"):
                with self.subTest(provider=provider, event=event), self.assertRaises(ValueError):
                    self.effect(provider, event, "stray text\n")
        with self.assertRaises(ValueError):
            self.effect("claude", "PostToolBatch", "stray text")
        with self.assertRaises(ValueError):
            check_hook_intent("notice", "SessionStart", self.effect("claude", "SessionStart", "a notice"))

    def test_json_shape(self):
        bad = [("claude", "SessionStart", '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"x"}}'),
               ("codex", "SessionStart", '{"hookSpecificOutput":{"hookEventName":"SessionStart","sessionTitle":"x"}}'),
               ("codex", "UserPromptSubmit", '{"terminalSequence":"\\u0007"}'),
               ("claude", "UserPromptSubmit", '{"decision":"block"}'),
               ("claude", "UserPromptSubmit", '{"reason":"x"}'),
               ("claude", "Stop", '{"continue":"no"}'),
               ("claude", "PreToolUse", '{"decision":"block","reason":"x"}'),
               ("codex", "PreToolUse", '{"continue":false}'),
               ("codex", "PreToolUse", '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"defer"}}'),
               ("claude", "SessionStart", '{"unknown":1}'),
               ("claude", "SessionStart", "{not json}"),
               ("codex", "SessionStart", "[1]")]
        for provider, event, out in bad:
            with self.subTest(provider=provider, event=event, out=out), self.assertRaises(ValueError):
                self.effect(provider, event, out)
        self.assertEqual(self.effect("claude", "SessionStart", "")["model_context"], False)
        self.assertTrue(self.effect("claude", "SessionStart",
                                    '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"x","sessionTitle":"t"}}')["model_context"])

    def test_exit_codes(self):
        self.assertTrue(self.effect("claude", "PreToolUse", "", "BLOCKED by policy", 2)["blocks"])
        for stdout, stderr, code in (("", "", 2), ('{"systemMessage":"x"}', "BLOCKED", 2), ("", "boom", 1)):
            with self.subTest(code=code, stderr=stderr), self.assertRaises(ValueError):
                self.effect("claude", "PreToolUse", stdout, stderr, code)
        with self.assertRaises(ValueError):
            self.effect("claude", "SessionStart", "", "x", 2)

    def test_gate_never_widens(self):
        for out in ('{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}',
                    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"command":"true"}}}',
                    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}'):
            with self.subTest(out=out), self.assertRaises(ValueError):
                check_hook_intent("gate", "PreToolUse", self.effect("claude", "PreToolUse", out))
        with self.assertRaises(ValueError):
            check_hook_intent("gate", "PreToolUse", self.effect("codex", "PreToolUse", '{"decision":"approve"}'))
        check_hook_intent("gate", "PreToolUse", self.effect("codex", "PreToolUse", '{"systemMessage":"AUDIT"}'))
        check_hook_intent("gate", "PreToolUse", self.effect("claude", "PreToolUse",
                          '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"x"}}'))

    def test_intent_scope(self):
        silent = self.effect("claude", "Stop", "")
        check_hook_intent("silent", "Stop", silent)
        with self.assertRaises(ValueError):
            check_hook_intent("silent", "UserPromptSubmit", self.effect("claude", "UserPromptSubmit", "x"))
        with self.assertRaises(ValueError):
            check_hook_intent("continue-turn", "UserPromptSubmit", silent)
        with self.assertRaises(ValueError):
            check_hook_intent("gate", "Stop", silent)
        with self.assertRaises(ValueError):
            check_hook_intent("bogus", "Stop", silent)


if __name__ == "__main__":
    unittest.main()
