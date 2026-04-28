---
description: Send a message to another named tmux pane
argument-hint: <pane-name> <message>
---

## Instructions

1. Parse `$ARGUMENTS`: the first word is the target pane name, and everything after it is the message.
2. If either value is missing, tell the user: `Usage: /send <pane-name> <message>`.
3. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.9.5}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
   ```

4. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/send-message.sh" "<target-name>" "<message>"
   ```

5. If the output says `Sent to ...`, confirm to the user.
6. If there is an error about no name, tell the user to run `/whoami <name>` first.
7. If the target is not found, suggest `/panes` to show available targets.
