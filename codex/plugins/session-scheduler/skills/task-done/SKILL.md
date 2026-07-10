---
name: task-done
description: "Mark a scheduler task done (records duration) and notify the assigner when possible."
---

# Task Done

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from the working directory or hardcode a marketplace cache version.

Run:

```bash
export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
bash "$PLUGIN_ROOT/scripts/task-done.sh" "<task-id>" [--force] "<note>"
```

Legal from `assigned` or `review` (review approval); other transitions are rejected unless `--force` (which records "forced" in history). Records `duration_seconds` since first assignment. Report that the task was marked done.
