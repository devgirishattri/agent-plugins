---
name: task-block
description: "Mark a scheduler task blocked and notify the assigner when possible."
---

# Task Block

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.1.3}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
```

Run:

```bash
bash "$PLUGIN_ROOT/scripts/task-block.sh" "<task-id>" "<reason>"
```

Report that the task was marked blocked.
