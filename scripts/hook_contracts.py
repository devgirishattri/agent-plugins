"""Release-time Codex hook capability policy, verified against CLI 0.154 schemas.

This is a project support policy, not a version pin or a runtime converter.
Unknown events/handlers require explicit capability review. MCP errors cannot
replace command-hook enforcement. Source: https://learn.chatgpt.com/docs/hooks
"""
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
