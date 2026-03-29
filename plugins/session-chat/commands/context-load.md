---
description: Load a shared project context snapshot into this session
argument-hint: <project-name>
allowed-tools: Bash(bash:*), Read
---

## Context Snapshot

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/load-context.sh $ARGUMENTS`

## Instructions

- If the snapshot was loaded successfully, read and internalize the context above
- Summarize what you learned: tech stack, key endpoints, auth pattern, conventions
- This context should inform your responses in this session
- If no snapshot found, suggest available ones or tell the sender to run `/context-generate`
