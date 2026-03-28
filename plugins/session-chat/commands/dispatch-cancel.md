---
description: Cancel and close a running worker pane
argument-hint: <label | all>
allowed-tools: Bash(bash:*)
---

## Cancel Worker

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/cancel-worker.sh $ARGUMENTS`

## Instructions

- If $ARGUMENTS is empty, ask the user which task to cancel or suggest "all"
- Report what was cancelled
- If nothing was cancelled, explain why (no running tasks, label not found)
