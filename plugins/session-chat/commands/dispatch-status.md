---
description: Show status of dispatched tasks to other sessions
argument-hint: [session-name]
allowed-tools: Bash(bash:*)
---

## Task Status

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-status.sh $ARGUMENTS`

## Instructions

Present the tab-separated data above as a markdown table:

| Session | Status | Pane | Created |

Rules:
- If no tasks found, report that
- For completed tasks, suggest `/dispatch-collect <session>` to read results
