---
name: send
description: "Send a message to another named tmux pane through session-chat. Use when the user asks to message, send, notify, or talk to another named Codex session."
---

# Send

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.10.0}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
```

Parse the first argument as the target pane name and the rest as the message. If either is missing, tell the user:

```text
Usage: $session-chat:send <pane-name> <message>
```

Use this skill only for single-line messages up to `SESSION_CHAT_SEND_MAX_LEN` characters, default 1024. For long, multi-line, or quoting-sensitive content, use `$session-chat:dispatch` instead.

Run:

```bash
bash "$PLUGIN_ROOT/scripts/send-message.sh" "<target-name>" "<message>"
```

If tmux is not active, explain that messaging requires running Codex inside tmux.
If the target is not found, suggest `$session-chat:panes`. If this pane has no name, suggest `$session-chat:whoami <name>`.
If the output reports a single-line or length limit, suggest `$session-chat:dispatch <pane-name> <task prompt>`.
If the output reports multiple panes named the same target, tell the user to rename one pane with `$session-chat:whoami <name>`.
If the output says the message did not land within the timeout, say the target may be busy and retry when idle or raise `SESSION_CHAT_VERIFY_TIMEOUT_MS`.
