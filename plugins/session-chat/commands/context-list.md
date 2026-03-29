---
description: List all available project context snapshots
allowed-tools: Bash(bash:*)
---

## Available Context Snapshots

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/list-contexts.sh`

## Instructions

Present the tab-separated data above as a markdown table:

| Project | Lines | Last Updated |

- If no snapshots found, suggest `/context-generate` to create one
- Suggest `/context-load <project>` to load a snapshot
- Suggest `/context-share <session> <project>` to share with another session
