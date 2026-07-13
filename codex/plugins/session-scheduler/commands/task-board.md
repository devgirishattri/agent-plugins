---
description: At-a-glance dashboard of active scheduler tasks grouped by stage
argument-hint: ""
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
   bash "<PLUGIN_ROOT>/scripts/task-board.sh"
   ```

   If the script reports `SESSION_SCHEDULER_HOME` is not set, stop and request
   that this pane be relaunched with the correct environment instead of
   deriving another ledger.

3. Relay the board output as-is inside a fenced code block. Per task it shows id, name, status, assignee, reviewer, workflow, age, OVERDUE/STALE flags, and unmet dependencies. Tasks are grouped by stage; done tasks are excluded.
4. The final line is the totals summary (e.g. `7 active: 2 created, 3 assigned, 1 review, 1 blocked; 1 overdue`). Highlight any OVERDUE or STALE tasks and suggest `$session-scheduler:task-status <task-id>` to inspect them.
