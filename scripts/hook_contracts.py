"""Release-time Codex hook capability policy, verified against CLI 0.154 schemas.

This is a project support policy, not a version pin or a runtime converter.
Unknown events/handlers require explicit capability review. MCP errors cannot
replace command-hook enforcement. Source: https://learn.chatgpt.com/docs/hooks
"""
import json
import math
import warnings

CODEX_EVENTS = frozenset({"PreToolUse", "PermissionRequest", "PostToolUse",
    "PreCompact", "PostCompact", "SessionStart", "SessionEnd", "UserPromptSubmit",
    "SubagentStart", "SubagentStop", "Stop", "Interrupt"})

# Claude 2.1.273 documentation, independently checked by agent-claude.
CLAUDE_EVENTS = frozenset("SessionStart Setup InstructionsLoaded UserPromptSubmit UserPromptExpansion MessageDisplay PreToolUse PermissionRequest PostToolUse PostToolUseFailure PostToolBatch PermissionDenied Notification SubagentStart SubagentStop TaskCreated TaskCompleted Stop StopFailure TeammateIdle ConfigChange CwdChanged DirectoryAdded FileChanged WorktreeCreate WorktreeRemove PreCompact PostCompact PreModelSwitch PostModelSwitch SessionEnd Elicitation ElicitationResult".split())
CLAUDE_NO_MATCHER = frozenset("UserPromptSubmit PostToolBatch Stop TeammateIdle TaskCreated TaskCompleted WorktreeCreate WorktreeRemove MessageDisplay CwdChanged".split())
CLAUDE_TOOL_EVENTS = frozenset("PreToolUse PostToolUse PostToolUseFailure PermissionRequest PermissionDenied".split())


def validate_claude(doc):
    hooks=doc.get("hooks")
    if not isinstance(hooks,dict) or not hooks:
        raise ValueError("missing non-empty hooks object")
    required={"command":("command",),"http":("url",),"mcp_tool":("server","tool"),
              "prompt":("prompt",),"agent":("prompt",)}
    for event,entries in hooks.items():
        if event not in CLAUDE_EVENTS:
            raise ValueError(f"unsupported Claude hook event {event!r}; review capability policy")
        if not isinstance(entries,list) or not entries:
            raise ValueError(f"{event}: expected non-empty entries")
        for entry in entries:
            if not isinstance(entry,dict) or not isinstance(entry.get("hooks"),list) or not entry["hooks"]:
                raise ValueError(f"{event}: expected non-empty handlers")
            if "matcher" in entry and not isinstance(entry["matcher"],str):
                raise ValueError(f"{event}: matcher must be string")
            if entry.get("matcher") and event in CLAUDE_NO_MATCHER:
                warnings.warn(f"{event}: non-empty matcher is ignored by Claude",stacklevel=2)
            for handler in entry["hooks"]:
                if not isinstance(handler,dict) or handler.get("type") not in required:
                    raise ValueError(f"{event}: unsupported Claude handler")
                kind=handler["type"]
                if "if" in handler and event not in CLAUDE_TOOL_EVENTS:
                    warnings.warn(f"{event}: if is only supported for tool events",stacklevel=2)
                if "once" in handler:
                    warnings.warn(f"{event}: once is ignored in plugin hooks.json",stacklevel=2)
                for field,kinds in {"headers":{"http"},"allowedEnvVars":{"http"},
                                    "input":{"mcp_tool"},"model":{"prompt","agent"}}.items():
                    if field in handler and kind not in kinds:
                        raise ValueError(f"{event}: {field} unsupported on {kind}")
                for field in required[kind]:
                    if not isinstance(handler.get(field),str) or not handler[field].strip():
                        raise ValueError(f"{event}: {kind} requires {field}")
                for field in ("statusMessage","if","model"):
                    if field in handler and not isinstance(handler[field],str):
                        raise ValueError(f"{event}: {field} must be string")
                for field in ("async","asyncRewake","once"):
                    if field in handler and type(handler[field]) is not bool:
                        raise ValueError(f"{event}: {field} must be boolean")
                if kind!="command" and any(f in handler for f in ("async","asyncRewake","args","shell")):
                    raise ValueError(f"{event}: command-only field on {kind}")
                if "timeout" in handler and (type(handler["timeout"]) is not int or handler["timeout"]<=0):
                    raise ValueError(f"{event}: timeout must be positive integer")
                for field in ("args","allowedEnvVars"):
                    if field in handler and (not isinstance(handler[field],list) or not all(isinstance(v,str) for v in handler[field])):
                        raise ValueError(f"{event}: {field} must be string array")
                for field in ("input","headers"):
                    if field in handler and not isinstance(handler[field],dict):
                        raise ValueError(f"{event}: {field} must be object")
                if "shell" in handler and handler["shell"] not in ("bash","powershell"):
                    raise ValueError(f"{event}: unsupported shell")
                # Claude Code 2.1.295+: "block" fails the triggering action closed
                # when the hook cannot start, times out or exits unexpectedly.
                if "onFailure" in handler:
                    if kind not in ("command","http"):
                        raise ValueError(f"{event}: onFailure unsupported on {kind}")
                    if handler["onFailure"] not in ("continue","block"):
                        raise ValueError(f"{event}: onFailure must be continue or block")


def validate_codex(doc):
    hooks = doc.get("hooks")
    if not isinstance(hooks, dict) or not hooks:
        raise ValueError("missing non-empty hooks object")
    for event, entries in hooks.items():
        if event not in CODEX_EVENTS:
            raise ValueError(f"unsupported Codex hook event {event!r}; review capability policy")
        if not isinstance(entries, list) or not entries:
            raise ValueError(f"{event}: expected non-empty entries")
        for entry in entries:
            if not isinstance(entry, dict):
                raise ValueError(f"{event}: entry must be object")
            if "matcher" in entry and not isinstance(entry["matcher"], str):
                raise ValueError(f"{event}: matcher must be string")
            handlers = entry.get("hooks")
            if not isinstance(handlers, list) or not handlers:
                raise ValueError(f"{event}: expected non-empty handlers")
            for handler in handlers:
                if not isinstance(handler, dict):
                    raise ValueError(f"{event}: handler must be object")
                kind = handler.get("type")
                if kind not in {"command", "mcp_tool"}:
                    raise ValueError(f"{event}: unsupported Codex handler {kind!r}")
                common={"type","timeout","statusMessage","additionalContextLimit"}
                allowed=common | ({"command","commandWindows","async"} if kind=="command" else {"server","tool","input"})
                if set(handler)-allowed:
                    raise ValueError(f"{event}: unsupported Codex handler fields {sorted(set(handler)-allowed)}")
                for field in ("statusMessage", "commandWindows"):
                    if field in handler and not isinstance(handler[field], str):
                        raise ValueError(f"{event}: {field} must be string")
                if "async" in handler and not isinstance(handler["async"], bool):
                    raise ValueError(f"{event}: async must be boolean")
                if "timeout" in handler:
                    timeout = handler["timeout"]
                    if type(timeout) not in (int, float) or not math.isfinite(timeout) or timeout <= 0:
                        raise ValueError(f"{event}: timeout must be positive finite number")
                    if event in {"Interrupt", "SessionEnd"} and timeout > 3:
                        raise ValueError(f"{event}: timeout exceeds supported 3 seconds")
                if "additionalContextLimit" in handler:
                    limit = handler["additionalContextLimit"]
                    if type(limit) is not int or limit < 0:
                        raise ValueError(f"{event}: additionalContextLimit must be nonnegative integer")
                if kind == "command":
                    command = handler.get("command")
                    if not isinstance(command, str) or not command.strip():
                        raise ValueError(f"{event}: command missing")
                    if "CODEX_PLUGIN_ROOT" in command or "/plugins/cache/" in command:
                        raise ValueError(f"{event}: command uses legacy/cache-derived root")
                    if "$PLUGIN_ROOT" not in command and "${PLUGIN_ROOT}" not in command:
                        raise ValueError(f"{event}: command must use runtime PLUGIN_ROOT")
                else:
                    if event == "SessionEnd":
                        raise ValueError("SessionEnd does not support MCP tool hooks")
                    for field in ("server", "tool"):
                        if not isinstance(handler.get(field), str) or not handler[field].strip():
                            raise ValueError(f"{event}: MCP {field} missing")
                    if "input" in handler and not isinstance(handler["input"], dict):
                        raise ValueError(f"{event}: MCP input must be object")
                    if "command" in handler or "async" in handler or "commandWindows" in handler:
                        raise ValueError(f"{event}: command-only field on MCP handler")


# ---------------------------------------------------------------------------
# Hook OUTPUT contracts: what each runtime does with a command hook's stdout
# and exit code, for the events this repository's hooks use.
#
# Claude Code 2.1.325: hooks reference, "JSON output" and each event's
# "decision control" section. Plain stdout is model context only on
# SessionStart and UserPromptSubmit; elsewhere it goes to the debug log.
# Codex 0.169.0: codex-rs/hooks/src/schema.rs (every output struct is
# deny_unknown_fields) and engine/output_parser.rs. Stdout that starts with
# "{" or "[" must parse; plain stdout is model context on SessionStart and
# UserPromptSubmit, ignored on PreToolUse and a failure on Stop.
#
# Each table row: event -> (top-level decision values, hookSpecificOutput
# fields besides hookEventName or None, plain stdout is model context).
# ---------------------------------------------------------------------------
CLAUDE_OUTPUT_UNIVERSAL = frozenset({"continue", "stopReason", "suppressOutput", "systemMessage", "terminalSequence"})
CODEX_OUTPUT_UNIVERSAL = frozenset({"continue", "stopReason", "suppressOutput", "systemMessage"})
CLAUDE_OUTPUT = {
    "SessionStart": (frozenset(), frozenset({"additionalContext", "initialUserMessage", "sessionTitle", "watchPaths", "reloadSkills"}), True),
    "UserPromptSubmit": (frozenset({"block"}), frozenset({"additionalContext", "sessionTitle", "suppressOriginalPrompt"}), True),
    # Top-level decision/reason are deprecated for PreToolUse.
    "PreToolUse": (frozenset(), frozenset({"permissionDecision", "permissionDecisionReason", "updatedInput", "additionalContext"}), False),
    "PostToolBatch": (frozenset({"block"}), frozenset({"additionalContext"}), False),
    "Stop": (frozenset({"block"}), frozenset({"additionalContext"}), False),
}
CODEX_OUTPUT = {
    "SessionStart": (frozenset(), frozenset({"additionalContext"}), True),
    "UserPromptSubmit": (frozenset({"block"}), frozenset({"additionalContext"}), True),
    "PreToolUse": (frozenset({"approve", "block"}), frozenset({"permissionDecision", "permissionDecisionReason", "updatedInput", "additionalContext"}), False),
    "Stop": (frozenset({"block"}), None, False),
}
PERMISSION_DECISIONS = {"claude": frozenset({"allow", "deny", "ask", "defer"}), "codex": frozenset({"allow", "deny", "ask"})}
HOOK_INTENTS = frozenset({"context", "notice", "continue-turn", "gate", "silent"})


def _string(value):
    return isinstance(value, str)


def hook_output_effect(provider, event, stdout, stderr, exit_code):
    """Read one hook run the way the runtime would and return its effect.

    Raises ValueError when the runtime would reject the output, ignore it, or
    report the run as a hook error. The returned dict says what the run does:
    model_context, user_message, continues_turn (and continues_via), blocks,
    stops, permission and rewrites_input.
    """
    tables = {"claude": (CLAUDE_OUTPUT, CLAUDE_OUTPUT_UNIVERSAL), "codex": (CODEX_OUTPUT, CODEX_OUTPUT_UNIVERSAL)}
    if provider not in tables:
        raise ValueError(f"unknown provider {provider!r}")
    table, universal = tables[provider]
    if event not in table:
        raise ValueError(f"{provider} {event}: no output contract; add the event to hook_contracts.py")
    decisions, specific, plain_is_context = table[event]
    effect = {"model_context": False, "user_message": False, "continues_turn": False, "continues_via": None,
              "blocks": False, "stops": False, "permission": None, "rewrites_input": False}
    text = stdout.strip()
    if exit_code == 2:
        if not stderr.strip():
            raise ValueError(f"{event}: exit 2 without a stderr reason is a hook error")
        if text:
            raise ValueError(f"{event}: exit 2 with stdout mixes exit-code and JSON control")
        if event in ("PreToolUse", "UserPromptSubmit"):
            effect["blocks"] = True
        elif event == "Stop":
            effect.update(continues_turn=True, continues_via="exit2", model_context=True)
        else:
            raise ValueError(f"{event}: exit 2 has no supported effect here")
        return effect
    if exit_code != 0:
        raise ValueError(f"{event}: exit {exit_code} is a non-blocking hook error")
    if not text:
        return effect
    if not (text.startswith("{") or text.startswith("[")):
        if not plain_is_context:
            raise ValueError(f"{event}: plain stdout is not delivered on this event ({provider})")
        effect["model_context"] = True
        return effect
    try:
        doc = json.loads(text)
    except ValueError as exc:
        raise ValueError(f"{event}: stdout looks like JSON but does not parse ({exc})") from None
    if not isinstance(doc, dict):
        raise ValueError(f"{event}: JSON output must be one object")
    allowed = set(universal) | {"hookSpecificOutput"} if specific is not None else set(universal)
    if decisions:
        allowed |= {"decision", "reason"}
    unknown = sorted(set(doc) - allowed)
    if unknown:
        raise ValueError(f"{event}: {provider} does not accept {unknown}")
    for field in ("continue", "suppressOutput"):
        if field in doc and type(doc[field]) is not bool:
            raise ValueError(f"{event}: {field} must be boolean")
    for field in ("stopReason", "systemMessage", "terminalSequence", "reason"):
        if field in doc and not _string(doc[field]):
            raise ValueError(f"{event}: {field} must be a string")
    if provider == "codex" and event == "PreToolUse":
        if doc.get("continue") is False or "stopReason" in doc or doc.get("suppressOutput") is True:
            raise ValueError("PreToolUse: Codex rejects continue:false, stopReason and suppressOutput")
    if doc.get("systemMessage"):
        effect["user_message"] = True
    if doc.get("continue") is False:
        effect["stops"] = True
    if "decision" in doc:
        if doc["decision"] not in decisions:
            raise ValueError(f"{event}: decision {doc['decision']!r} is not one of {sorted(decisions)}")
        if doc["decision"] == "block" and not (doc.get("reason") or "").strip():
            raise ValueError(f"{event}: decision block needs a non-empty reason")
        if doc["decision"] == "approve":
            effect["permission"] = "allow"
        elif event == "Stop":
            effect.update(continues_turn=True, continues_via="decision", model_context=True)
        elif event == "PostToolBatch":
            effect["stops"] = True
        else:
            effect["blocks"] = True
    elif "reason" in doc:
        raise ValueError(f"{event}: reason without decision is ignored")
    hso = doc.get("hookSpecificOutput")
    if hso is not None:
        if not isinstance(hso, dict):
            raise ValueError(f"{event}: hookSpecificOutput must be an object")
        if hso.get("hookEventName") != event:
            raise ValueError(f"{event}: hookSpecificOutput.hookEventName must be {event!r}")
        extra = sorted(set(hso) - {"hookEventName"} - set(specific))
        if extra:
            raise ValueError(f"{event}: {provider} hookSpecificOutput does not accept {extra}")
        for field in ("additionalContext", "permissionDecisionReason", "sessionTitle", "initialUserMessage"):
            if field in hso and not _string(hso[field]):
                raise ValueError(f"{event}: hookSpecificOutput.{field} must be a string")
        if hso.get("additionalContext"):
            effect["model_context"] = True
            if event == "Stop":
                effect.update(continues_turn=True, continues_via="additionalContext")
        if "permissionDecision" in hso:
            if hso["permissionDecision"] not in PERMISSION_DECISIONS[provider]:
                raise ValueError(f"{event}: permissionDecision {hso['permissionDecision']!r} is not accepted by {provider}")
            effect["permission"] = hso["permissionDecision"]
            if hso["permissionDecision"] == "deny":
                effect["blocks"] = True
        if "updatedInput" in hso:
            effect["rewrites_input"] = True
    return effect


def check_hook_intent(intent, event, effect):
    """Raise ValueError when a hook run's effect does not match its declared intent.

    context        adds model context and nothing else (never on Stop, where
                   context continues the turn).
    notice         shows the user a systemMessage and nothing else; the model
                   never sees it and the turn is not continued.
    continue-turn  Stop only: continues the turn with decision "block" and a
                   reason, the one form both runtimes accept.
    gate           PreToolUse only: blocks (exit 2 or a deny) or shows a
                   notice, and never allows, asks, defers or rewrites a call.
    silent         prints nothing.
    """
    if intent not in HOOK_INTENTS:
        raise ValueError(f"unknown hook intent {intent!r}")
    others = {key for key in ("model_context", "user_message", "continues_turn", "blocks", "stops", "rewrites_input") if effect[key]}
    if effect["permission"] not in (None, "deny"):
        others.add(f"permission {effect['permission']}")
    if intent == "silent":
        allowed = set()
    elif intent == "context":
        if event == "Stop":
            raise ValueError("context on Stop continues the turn; declare continue-turn or notice")
        allowed = {"model_context"}
    elif intent == "notice":
        allowed = {"user_message"}
    elif intent == "continue-turn":
        if event != "Stop":
            raise ValueError("continue-turn is a Stop intent")
        if effect["continues_turn"] and effect["continues_via"] != "decision":
            raise ValueError(f"Stop continues the turn via {effect['continues_via']}; use decision block with a reason, which both runtimes accept")
        allowed = {"continues_turn", "model_context"}
    else:
        if event != "PreToolUse":
            raise ValueError("gate is a PreToolUse intent")
        allowed = {"blocks", "user_message"}
    unexpected = sorted(others - allowed)
    if unexpected:
        raise ValueError(f"{intent} hook on {event} also {', '.join(unexpected)}")
