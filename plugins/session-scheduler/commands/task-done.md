---
description: Mark a task done; ack the assigner via session-chat
argument-hint: <id> [--force] [note]
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate.

`SESSION_SCHEDULER_HOME` must already be present in this session's environment, inherited when the agent process started (the pane/session launcher sets it — never export or derive it here). Run the helper as exactly one Bash segment, with no `export` beforehand, no `env` or variable-assignment prefix, and no other command chained, piped, redirected, or substituted around it:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-done.sh" $ARGUMENTS
```

If the script reports `SESSION_SCHEDULER_HOME` is not set — or your inherited value differs from the ledger home stated in your assignment — stop and request that this pane/session be relaunched with the correct environment instead of deriving another ledger.

- Legal from `assigned` or `review` (review approval). Other transitions are rejected; `--force` overrides and records "forced" in history.
- Records `duration_seconds` (done time minus `started_at`) when the task was assigned at some point.

Confirm and surface the note and duration if present.
