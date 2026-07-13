---
description: At-a-glance dashboard of active tasks grouped by stage
argument-hint: ""
allowed-tools: Bash(bash:*)
---

## Board

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-board.sh"`

## Instructions

`SESSION_SCHEDULER_HOME` must already be present in this session's environment, inherited when the agent process started. If the output above reports it is not set, stop and request that this pane/session be relaunched with the correct environment — do not export the variable or derive another ledger.

Relay the board output as-is inside a fenced code block (it is pre-aligned plain text). Per task it shows: id, name, status, assignee, age since creation, OVERDUE/STALE flags, and unmet dependency count. Tasks are grouped by stage; unstaged tasks appear under `(none)`. `done` tasks are excluded.

The final line is the totals summary (e.g. `7 active: 2 created, 3 assigned, 1 review, 1 blocked; 1 overdue`). Highlight any OVERDUE or STALE tasks and suggest `/task-status <id>` to inspect them.
