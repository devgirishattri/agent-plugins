---
description: At-a-glance dashboard of active scheduler tasks grouped by stage
argument-hint: ""
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-plugins/session-scheduler/0.4.1}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
   ```

2. Run:

   ```bash
   export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
   bash "$PLUGIN_ROOT/scripts/task-board.sh"
   ```

3. Relay the board output as-is inside a fenced code block (it is pre-aligned plain text). Per task it shows: id, name, status, assignee, age since creation, OVERDUE/STALE flags, and unmet dependency count. Tasks are grouped by stage; unstaged tasks appear under `(none)`. `done` tasks are excluded.
4. The final line is the totals summary (e.g. `7 active: 2 created, 3 assigned, 1 review, 1 blocked; 1 overdue`). Highlight any OVERDUE or STALE tasks and suggest `$session-scheduler:task-status <task-id>` to inspect them.
