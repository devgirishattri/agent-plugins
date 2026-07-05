---
description: Mark a task blocked; ack the assigner via session-chat
argument-hint: <id> [--force] <reason>
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate. The reason is required.

```
export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
bash ${CLAUDE_PLUGIN_ROOT}/scripts/task-block.sh $ARGUMENTS
```

Legal from `created`, `assigned`, or `review` (review rejection). Other transitions are rejected; `--force` overrides and records "forced" in history. Unblock by re-running `/task-assign` (blocked → assigned is legal).
