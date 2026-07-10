---
name: task-status
description: "Show scheduler task status from the file-backed task ledger, with OVERDUE/STALE flags and stage grouping."
---

# Task Status

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from the working directory or hardcode a marketplace cache version.

Run:

```bash
export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
bash "$PLUGIN_ROOT/scripts/task-status.sh" [task-id|--all|--pending|--mine|--by-stage|--by-workflow|--workflow ID]
```

Present tab-separated output as id, status, workflow, stage, assignee, reviewer, assigner, updated time, flags, and name. `--by-stage` groups active tasks. `--by-workflow` groups the full lifecycle of tasks carrying a workflow id, including completed steps, and omits ungrouped tasks. `--workflow ID` filters one workflow. The single-task view also reports the recorded shared scheduler home and dependency states.
