---
description: At-a-glance dashboard of active scheduler tasks grouped by stage
argument-hint: ""
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Run:

   ```bash
   export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
   bash "$PLUGIN_ROOT/scripts/task-board.sh"
   ```

3. Relay the board output as-is inside a fenced code block. Per task it shows id, name, status, assignee, reviewer, workflow, age, OVERDUE/STALE flags, and unmet dependencies. Tasks are grouped by stage; done tasks are excluded.
4. The final line is the totals summary (e.g. `7 active: 2 created, 3 assigned, 1 review, 1 blocked; 1 overdue`). Highlight any OVERDUE or STALE tasks and suggest `$session-scheduler:task-status <task-id>` to inspect them.
