---
description: Search sessions by name, ID prefix, or project path
argument-hint: <search-query>
allowed-tools: Bash(bash:*)
---

## Search Results

Searching for: **$ARGUMENTS**

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/search-sessions.sh "$ARGUMENTS"`

## Instructions

Present matching sessions as a markdown table:

| Name | Session ID | Project | Size | Last Modified |

Rules:
- Show full Session IDs (so users can copy them for /session-delete)
- If no sessions match, tell the user no sessions matched "$ARGUMENTS"
- If $ARGUMENTS is empty, tell the user: Usage: `/session-search <name-or-id-or-project>`
- Show the count of matching sessions at the bottom
- Mention that `/session-delete <session-id>` can be used to delete a session
