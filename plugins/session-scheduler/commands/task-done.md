---
description: Mark a task done; ack the assigner via session-chat
argument-hint: <id> [--force] [note]
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate.

```
bash ${CLAUDE_PLUGIN_ROOT}/scripts/task-done.sh $ARGUMENTS
```

- Legal from `assigned` or `review` (review approval). Other transitions are rejected; `--force` overrides and records "forced" in history.
- Records `duration_seconds` (done time minus `started_at`) when the task was assigned at some point.

Confirm and surface the note and duration if present.
