---
description: At-a-glance dashboard of active tasks grouped by stage
argument-hint: ""
allowed-tools: Bash(bash:*)
---

## Board

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-board.sh"`

## Instructions

`SESSION_SCHEDULER_HOME` must already be present in this session's environment. It is inherited when the agent process started. If the output above reports that it is not set, stop. Ask the user to relaunch this pane/session with the correct environment. Do not export the variable or derive another ledger.

Contracted tasks show `CONTRACT:<state>` (admitted, closed-unadmitted, active, invalid) in the flags column; a bare `done` is not acceptance.

Relay the board output as-is inside a fenced code block. The output is pre-aligned plain text. Per task it shows: id, name, status, assignee, age since creation, OVERDUE/STALE flags, and unmet dependency count. Tasks are grouped by stage. Unstaged tasks appear under `(none)`. `done` tasks are excluded.

The final line is the totals summary (e.g. `7 active: 2 created, 3 assigned, 1 review, 1 blocked; 1 overdue`). Highlight any OVERDUE or STALE tasks. Suggest `/task-status <id>` to inspect them.
