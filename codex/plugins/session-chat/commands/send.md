---
description: Send a message to another named tmux pane
argument-hint: <pane-name> <message>
---

## Instructions

`$session-chat:send` is for single-line messages up to 1024 characters by default. Use `$session-chat:dispatch` for multi-line or quoting-sensitive content.
For a response to an incoming message, use `$session-chat:reply` so correlation
is transport-generated rather than manually typed.

1. Parse `$ARGUMENTS`: optional `--priority high` (surfaces before normal messages if queued) and `--ttl <minutes>` (drop instead of surfacing if still queued after the window) come first; then the target pane name; everything after is the message.
2. If either value is missing, tell the user: `Usage: $session-chat:send <pane-name> <message>`.
3. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

4. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/send-message.sh" [--priority high] [--ttl <minutes>] [--reply-to <incoming-id>] "<target-name>" "<message>"
   ```

5. If the output says `Sent to ...`, confirm to the user.
6. If there is an error about no name, suggest `$session-chat:whoami <name>`.
7. If the target is not found, suggest `$session-chat:panes`.
8. For single-line or length limits, suggest `$session-chat:dispatch <pane-name> <task prompt>`.
9. For duplicate names, suggest `$session-chat:whoami <name>` in one pane.
10. If there is an error that the send did not land within the timeout, tell the user the target may be busy; retry when idle or raise `SESSION_CHAT_VERIFY_TIMEOUT_MS`.
