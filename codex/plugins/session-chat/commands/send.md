---
description: Send a message to another named tmux pane
argument-hint: <pane-name> <message>
---

## Instructions

`/send` is for single-line messages up to 1024 characters by default. For multi-line prompts, long tasks, code, logs, or quoting-sensitive content, use `/dispatch` and refer to the `session-chat` skill decision table.

1. Parse `$ARGUMENTS`: the first word is the target pane name, and everything after it is the message.
2. If either value is missing, tell the user: `Usage: /send <pane-name> <message>`.
3. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.12.2}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
   ```

4. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/send-message.sh" "<target-name>" "<message>"
   ```

5. If the output says `Sent to ...`, confirm to the user.
6. If there is an error about no name, tell the user to run `/whoami <name>` first.
7. If the target is not found, suggest `/panes` to show available targets.
8. If there is an error about single-line or length limits, tell the user to use `/dispatch <pane-name> <task prompt>`.
9. If there is an error about multiple panes with the same name, tell the user to rename one of those panes with `/whoami <name>`.
10. If there is an error that the send did not land within the timeout, tell the user the target may be busy; retry when idle or raise `SESSION_CHAT_VERIFY_TIMEOUT_MS`.
