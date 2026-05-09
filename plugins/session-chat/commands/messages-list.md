---
description: List dispatched message files (read-only)
argument-hint: [--from NAME] [--to NAME]
allowed-tools: Bash(bash:*)
---

## Messages

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/messages-list.sh $ARGUMENTS`

## Instructions

Do not narrate. Render the tab-separated output above as a markdown table:

| Age | Size | From | To | File |

- Show the total count + bytes line below the table.
- Suggest `/messages-clean` to remove old files.
