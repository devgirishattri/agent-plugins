---
name: task-status
description: "Show scheduler task status from the file-backed task ledger, with OVERDUE/STALE flags and stage grouping."
---

# Task Status

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.2.0}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
```

Run:

```bash
bash "$PLUGIN_ROOT/scripts/task-status.sh" [task-id|--all|--pending|--mine|--by-stage]
```

Present tab-separated output as id, status, stage, assignee, assigner, updated time, flags, and name. Flags: `OVERDUE` = past `eta_at`; `STALE` = assigned/review with no update for `SESSION_SCHEDULER_STALE_MINUTES` (default 30) minutes. `--by-stage` groups non-done tasks by stage. The single-task view also lists dependencies with their statuses.
