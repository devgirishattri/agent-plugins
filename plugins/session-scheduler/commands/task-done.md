---
description: Mark a task done; ack the assigner via session-chat
argument-hint: <id> [note]
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate.

```
bash ${CLAUDE_PLUGIN_ROOT}/scripts/task-done.sh $ARGUMENTS
```

Confirm and surface the note if present.
