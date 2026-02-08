---
description: List Claude Code sessions (current project by default, or "all")
argument-hint: [all]
allowed-tools: Bash(bash:*)
---

## Session Data

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/list-sessions.sh $ARGUMENTS`

## Instructions

Present the tab-separated data above as a clean markdown table with these columns:

| Name | Session ID | Project | Size | Last Modified |

Rules:
- Sort by Last Modified (most recent first) - data is already sorted
- Show full Session IDs (so users can copy them for /session-delete)
- If a session has no name, show "(untitled)"
- Show the total count of sessions at the bottom
- If the output is empty or says "No sessions found", report that no sessions were found
- Mention: use `/session-list all` to see sessions across all projects
- Suggest using `/session-search <query>` to filter results
