---
name: task-board
description: "Render an at-a-glance dashboard of active scheduler tasks grouped by stage."
---

# Task Board

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.4.0}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
```

Run:

```bash
export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
bash "$PLUGIN_ROOT/scripts/task-board.sh"
```

Relay the output as-is inside a fenced code block (pre-aligned plain text). Per task it shows id, name, status, assignee, age since creation, OVERDUE/STALE flags, and unmet dependency count, grouped by stage (`(none)` for unstaged). The final line is the totals summary (e.g. `7 active: 2 created, 3 assigned, 1 review, 1 blocked; 1 overdue`). Highlight any OVERDUE or STALE tasks.
