---
name: task-assign
description: "Assign an existing scheduler task to a named pane through session-chat."
---

# Task Assign

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.1.1}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
```

Run:

```bash
bash "$PLUGIN_ROOT/scripts/task-assign.sh" "<pane-name>" "<task-id>" "<prompt>"
```

Report success or the precise session-chat error. Remind the user that executor panes need `SESSION_CHAT_INCOMING_MODE=auto` or `assist` to act on assigned dispatches.
