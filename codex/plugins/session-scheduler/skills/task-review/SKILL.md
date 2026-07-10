---
name: task-review
description: "Move an assigned task to review and auto-dispatch its audit packet to the configured reviewer."
---

# Task Review

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from the working directory or hardcode a marketplace cache version.

Run (the note is required — typically a commit SHA or a one-line summary of what to audit):

```bash
export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
bash "$PLUGIN_ROOT/scripts/task-review.sh" "<task-id>" [--force] "<note>"
```

The executor (or orchestrator) runs this when work is ready for audit. Legal only from `assigned`. If the task has a `reviewer`, the script builds a private review packet containing the shared ledger homes and original assignment, then dispatches it automatically. Review state is retained if delivery fails so it can be retried. The reviewer approves with `$session-scheduler:task-done` or rejects with `$session-scheduler:task-block`.
