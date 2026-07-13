---
description: Show scheduler task status
argument-hint: "[task-id|--all|--pending|--mine|--by-stage|--by-workflow|--workflow ID]"
---

## Instructions

1. Resolve the absolute plugin root from the installed plugin source containing
   this command reference and substitute it literally for `<PLUGIN_ROOT>` below.
   Do not infer it from cwd or hardcode a cache version.

2. `SESSION_SCHEDULER_HOME` must already be present in this pane's environment,
   inherited when the agent process started (the pane/session launcher sets it —
   never export or derive it here). Run exactly one Bash segment, with no
   `export` beforehand, no `env` or variable-assignment prefix, and no other
   command chained, piped, redirected, or substituted around it:

   ```bash
   bash "<PLUGIN_ROOT>/scripts/task-status.sh" $ARGUMENTS
   ```

   If the script reports `SESSION_SCHEDULER_HOME` is not set, stop and request
   that this pane be relaunched with the correct environment instead of
   deriving another ledger.

3. Present the tab-separated output as id, status, workflow, stage, assignee, reviewer, assigner, updated time, flags, and name.
4. Flags: `OVERDUE` = past `eta_at`; `STALE` = assigned/review with no update for `SESSION_SCHEDULER_STALE_MINUTES` (default 30) minutes; `-` = none.
5. Default output is active tasks; `--all` includes done and blocked tasks; `--by-stage` groups non-done tasks; `--by-workflow` shows every task carrying a workflow id, including completed steps, and omits ungrouped tasks; `--workflow ID` filters one workflow.
6. The single-task view also lists the recorded shared scheduler home, dependencies, and flags.
