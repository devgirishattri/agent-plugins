---
description: Assign a scheduler task to a named pane
argument-hint: <pane-name> <task-id> <prompt>
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.1.2}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
   ```

2. Parse `$ARGUMENTS`: first word is target pane, second word is task id, everything after is the prompt.
3. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/task-assign.sh" "<pane-name>" "<task-id>" "<prompt>"
   ```

4. If dispatch succeeds, report the task id and assignee.
5. If the target pane is missing or duplicated, suggest checking `$session-chat:panes` and `$session-chat:whoami`.
6. Mention that executor panes need `SESSION_CHAT_INCOMING_MODE=auto` or `assist` to act on assigned dispatches.
