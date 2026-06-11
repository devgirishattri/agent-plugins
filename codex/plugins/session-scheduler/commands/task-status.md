---
description: Show scheduler task status
argument-hint: [task-id|--all|--pending|--mine|--by-stage]
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.2.1}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
   ```

2. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/task-status.sh" $ARGUMENTS
   ```

3. Present the tab-separated output as id, status, stage, assignee, assigner, updated time, flags, and name.
4. Flags: `OVERDUE` = past `eta_at`; `STALE` = assigned/review with no update for `SESSION_SCHEDULER_STALE_MINUTES` (default 30) minutes; `-` = none.
5. Default output is active tasks; `--all` includes done and blocked tasks; `--by-stage` groups non-done tasks under `Stage: <name>` headers (`(none)` for unstaged).
6. The single-task view also lists dependencies with their statuses and any flags.
