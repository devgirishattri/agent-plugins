---
name: task-review
description: "Move an assigned task to review and auto-dispatch its audit packet to the configured reviewer."
---

# Task Review

Resolve the absolute plugin root from this selected skill's installed source
path: it is the directory two levels above this `SKILL.md`. Substitute that
absolute path literally for `<PLUGIN_ROOT>` below; never infer it from the
working directory or hardcode a marketplace cache version.

`SESSION_SCHEDULER_HOME` must already be present in this pane's environment,
inherited when the agent process started (the pane/session launcher sets it —
never export or derive it here). Run exactly one Bash segment (the note is
required — typically a commit SHA or a one-line summary of what to audit), with
no `export` beforehand, no `env` or variable-assignment prefix, and no other
command chained, piped, redirected, or substituted around it:

```bash
bash "<PLUGIN_ROOT>/scripts/task-review.sh" "<task-id>" [--force] "<note>"
```

If the script reports `SESSION_SCHEDULER_HOME` is not set — or the inherited
value differs from the ledger home stated in your assignment — stop and request
a pane relaunch with the correct environment instead of deriving another ledger.

The executor (or orchestrator) runs this when work is ready for audit. Legal only from `assigned`. If the task has a `reviewer`, the script builds a private review packet containing the shared ledger homes and original assignment, then dispatches it automatically. Review state is retained if delivery fails so it can be retried. The reviewer approves with `$session-scheduler:task-done` or rejects with `$session-scheduler:task-block`.
