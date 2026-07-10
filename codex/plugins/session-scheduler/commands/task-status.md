---
description: Show scheduler task status
argument-hint: "[task-id|--all|--pending|--mine|--by-stage|--by-workflow|--workflow ID]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Run:

   ```bash
   export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
   bash "$PLUGIN_ROOT/scripts/task-status.sh" $ARGUMENTS
   ```

3. Present the tab-separated output as id, status, workflow, stage, assignee, reviewer, assigner, updated time, flags, and name.
4. Flags: `OVERDUE` = past `eta_at`; `STALE` = assigned/review with no update for `SESSION_SCHEDULER_STALE_MINUTES` (default 30) minutes; `-` = none.
5. Default output is active tasks; `--all` includes done and blocked tasks; `--by-stage` groups non-done tasks; `--by-workflow` shows every task carrying a workflow id, including completed steps, and omits ungrouped tasks; `--workflow ID` filters one workflow.
6. The single-task view also lists the recorded shared scheduler home, dependencies, and flags.
