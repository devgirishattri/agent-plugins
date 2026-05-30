---
name: task-status
description: "Show scheduler task status from the file-backed task ledger."
---

# Task Status

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.1.3}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
```

Run:

```bash
bash "$PLUGIN_ROOT/scripts/task-status.sh" <args>
```

Present tab-separated output as id, status, assignee, assigner, updated time, and name.
