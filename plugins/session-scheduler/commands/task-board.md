---
description: At-a-glance dashboard of active tasks grouped by stage
argument-hint: ""
allowed-tools: Bash(bash:*)
---

## Board

!`export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"; bash ${CLAUDE_PLUGIN_ROOT}/scripts/task-board.sh`

## Instructions

Relay the board output as-is inside a fenced code block (it is pre-aligned plain text). Per task it shows: id, name, status, assignee, age since creation, OVERDUE/STALE flags, and unmet dependency count. Tasks are grouped by stage; unstaged tasks appear under `(none)`. `done` tasks are excluded.

The final line is the totals summary (e.g. `7 active: 2 created, 3 assigned, 1 review, 1 blocked; 1 overdue`). Highlight any OVERDUE or STALE tasks and suggest `/task-status <id>` to inspect them.
