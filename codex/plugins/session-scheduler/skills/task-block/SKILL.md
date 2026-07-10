---
name: task-block
description: "Mark a scheduler task blocked (or reject a review) and notify the assigner when possible."
---

# Task Block

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from the working directory or hardcode a marketplace cache version.

Run:

```bash
export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
bash "$PLUGIN_ROOT/scripts/task-block.sh" "<task-id>" [--force] "<reason>"
```

Legal from `created`, `assigned`, or `review` (review rejection); other transitions are rejected unless `--force`. Unblock by re-running task-assign (blocked → assigned is legal). Report that the task was marked blocked.
