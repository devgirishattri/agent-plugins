---
description: Show status of all dispatched worker tasks
argument-hint: [label]
allowed-tools: Bash(bash:*)
---

## Task Status

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-status.sh $ARGUMENTS`

## Instructions

Present the tab-separated data above as a markdown table:

| Label | Status | Model | Pane | Created |

Rules:
- If no tasks found, report that
- For running tasks, suggest `/dispatch-cancel <label>` to cancel
- For completed tasks, suggest `/dispatch-collect <label>` to read results
