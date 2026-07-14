---
description: List context snapshots for the current project
allowed-tools: Bash(bash:*)
---

## Context Snapshots (Current Project)

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/list-contexts.sh"`

## Instructions

- `SESSION_CONTEXT_HOME` must already be present in this session's environment, inherited when the agent process started. If the output above reports it is not set, stop and request that this pane/session be relaunched with the correct environment — do not export the variable or derive another context store.
Present the tab-separated data above as a markdown table:

| Snapshot | Lines | Last Updated | Versions |

- The Versions column counts archived history entries (created each time a snapshot is overwritten, max 10 kept)
- If no snapshots found, suggest `/context-generate` to create one
- Suggest `/context-load <snapshot>` to load a snapshot
- Suggest `/context-diff <snapshot>` to compare a snapshot with its previous version
- Suggest `/context-share <session> <snapshot>` to share with another session
- Suggest `/context-remove <snapshot>` to delete a snapshot
