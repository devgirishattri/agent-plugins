---
description: Assign a task to an executor pane and dispatch via session-chat
argument-hint: <pane> <id> <prompt>
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate. Parse `$ARGUMENTS` as: first word = pane, second = task id, rest = prompt.

```
bash ${CLAUDE_PLUGIN_ROOT}/scripts/task-assign.sh "<pane>" "<id>" "<prompt>"
```

If the script reports session-chat dispatch failed, the ledger was NOT updated — fix the dispatch issue (recipient busy, no /whoami, etc.) and retry. Remind the user that the executor pane needs `SESSION_CHAT_INCOMING_MODE=auto` (or `assist`) for the task to actually be acted on.
