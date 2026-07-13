---
name: task-board
description: "Render an at-a-glance dashboard of active scheduler tasks grouped by stage."
---

# Task Board

Resolve the absolute plugin root from this selected skill's installed source
path: it is the directory two levels above this `SKILL.md`. Substitute that
absolute path literally for `<PLUGIN_ROOT>` below; never infer it from the
working directory or hardcode a marketplace cache version.

`SESSION_SCHEDULER_HOME` must already be present in this pane's environment,
inherited when the agent process started (the pane/session launcher sets it —
never export or derive it here). Run exactly one Bash segment, with no `export`
beforehand, no `env` or variable-assignment prefix, and no other command
chained, piped, redirected, or substituted around it:

```bash
bash "<PLUGIN_ROOT>/scripts/task-board.sh"
```

If the script reports `SESSION_SCHEDULER_HOME` is not set, stop and request a
pane relaunch with the correct environment instead of deriving another ledger.

Relay the output as-is inside a fenced code block. Per task it shows id, name, status, assignee, reviewer, workflow, age, OVERDUE/STALE flags, and unmet dependencies, grouped by stage. Highlight any OVERDUE or STALE tasks.
