---
name: send
description: "Send a message to another named tmux pane through session-chat. Use when the user asks to message, send, notify, or talk to another named Codex session."
---

# Send

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from cwd or hardcode a marketplace cache version.

Parse the first argument as the target pane name and the rest as the message. If either is missing, tell the user:

```text
Usage: $session-chat:send <pane-name> <message>
```

Use this skill only for single-line messages up to `SESSION_CHAT_SEND_MAX_LEN` characters, default 1024. For long, multi-line, or quoting-sensitive content, use `$session-chat:dispatch` instead.
If this message responds to an incoming session-chat message or dispatch, use
`$session-chat:reply <pane> <incoming-id> <message>` instead so the transport
records correlation automatically.

Run:

```bash
bash "$PLUGIN_ROOT/scripts/send-message.sh" [--priority high] [--ttl <minutes>] [--reply-to <incoming-id>] "<target-name>" "<message>"
```

If tmux is not active, explain that messaging requires running Codex inside tmux.
If the target is not found, suggest `$session-chat:panes`. If this pane has no name, suggest `$session-chat:whoami <name>`.
If the output reports a single-line or length limit, suggest `$session-chat:dispatch <pane-name> <task prompt>`.
If the output reports multiple panes named the same target, tell the user to rename one pane with `$session-chat:whoami <name>`.
If a live timeout is followed by `Queued ...`, report durable queued success and do not retry. Raise `SESSION_CHAT_VERIFY_TIMEOUT_MS` only when immediate live delivery matters. Retry only a hard failure that did not queue, after fixing its cause.
