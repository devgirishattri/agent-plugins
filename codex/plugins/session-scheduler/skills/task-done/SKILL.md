---
name: task-done
description: "Mark a scheduler task done (records duration) and notify the assigner when possible."
---

# Task Done

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
bash "<PLUGIN_ROOT>/scripts/task-done.sh" "<task-id>" [--force] "<note>"
```

If the script reports `SESSION_SCHEDULER_HOME` is not set — or the inherited
value differs from the ledger home stated in your assignment — stop and request
a pane relaunch with the correct environment instead of deriving another ledger.

Legal from `assigned` or `review` (review approval); other transitions are rejected unless `--force` (which records "forced" in history). Records `duration_seconds` since first assignment. Report that the task was marked done.
