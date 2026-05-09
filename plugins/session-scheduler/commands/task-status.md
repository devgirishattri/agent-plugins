---
description: Show the task ledger (default active; --all/--pending/--mine or single id)
argument-hint: [<id>|--all|--pending|--mine]
allowed-tools: Bash(bash:*)
---

## Tasks

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/task-status.sh $ARGUMENTS`

## Instructions

If the output is a JSON object (single task), pretty-print it as-is.
Otherwise render the tab-separated rows above as a markdown table:

| ID | Status | Assigner | Assignee | Name | Updated |

- Append the count line at the bottom.
- Suggest `/task-status <id>` for full detail.
