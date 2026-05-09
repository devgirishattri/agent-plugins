---
description: Mark a task blocked; ack the assigner via session-chat
argument-hint: <id> <reason>
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate. The reason is required.

```
bash ${CLAUDE_PLUGIN_ROOT}/scripts/task-block.sh $ARGUMENTS
```
