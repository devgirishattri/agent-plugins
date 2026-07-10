---
name: task-new
description: "Create a scheduler task with optional stage, dependencies, reviewer route, and workflow group."
---

# Task New

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from the working directory or hardcode a marketplace cache version.

Run:

```bash
export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
bash "$PLUGIN_ROOT/scripts/task-new.sh" <name> [--meta k=v] [--stage NAME] [--depends-on id1,id2] [--reviewer PANE] [--workflow ID]
```

- `--stage NAME` — optional pipeline stage label (suggested: `plan`, `dispatch`, `execute`, `audit`, `push`).
- `--depends-on id1,id2` — comma-separated existing task ids; assignment is gated until every dependency is `done`.
- `--reviewer PANE` — route `task-review` automatically to this independent reviewer.
- `--workflow ID` — group related tasks; `--workflow-id` is accepted as an alias.

Return the created task id and name.
