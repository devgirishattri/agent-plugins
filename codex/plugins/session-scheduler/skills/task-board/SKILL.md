---
name: task-board
description: "Render an at-a-glance dashboard of active scheduler tasks grouped by stage."
---

# Task Board

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from the working directory or hardcode a marketplace cache version.

Run:

```bash
export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
bash "$PLUGIN_ROOT/scripts/task-board.sh"
```

Relay the output as-is inside a fenced code block. Per task it shows id, name, status, assignee, reviewer, workflow, age, OVERDUE/STALE flags, and unmet dependencies, grouped by stage. Highlight any OVERDUE or STALE tasks.
