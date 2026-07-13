---
name: task-status
description: "Show scheduler task status from the file-backed task ledger, with OVERDUE/STALE flags and stage grouping."
---

# Task Status

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
bash "<PLUGIN_ROOT>/scripts/task-status.sh" [task-id|--all|--pending|--mine|--by-stage|--by-workflow|--workflow ID]
```

If the script reports `SESSION_SCHEDULER_HOME` is not set, stop and request a
pane relaunch with the correct environment instead of deriving another ledger.

Present tab-separated output as id, status, workflow, stage, assignee, reviewer, assigner, updated time, flags, and name. `--by-stage` groups active tasks. `--by-workflow` groups the full lifecycle of tasks carrying a workflow id, including completed steps, and omits ungrouped tasks. `--workflow ID` filters one workflow. The single-task view also reports the recorded shared scheduler home and dependency states.
