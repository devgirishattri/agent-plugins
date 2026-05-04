---
description: List context snapshots for the current project
allowed-tools: Bash(bash:*)
---

## Context Snapshots (Current Project)

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/list-contexts.sh`

## Instructions

Present the tab-separated data above as a markdown table:

| Snapshot | Lines | Last Updated |

- If no snapshots found, suggest `/context-generate` to create one
- Suggest `/context-load <snapshot>` to load a snapshot
- Suggest `/context-share <session> <snapshot>` to share with another session
- Suggest `/context-remove <snapshot>` to delete a snapshot
