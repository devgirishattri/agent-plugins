---
description: Load a session context summary to continue where another session left off
argument-hint: <snapshot-name>
allowed-tools: Bash(bash:*), Read
---

## Session Context

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/load-context.sh $ARGUMENTS`

## Instructions

- If the context was loaded successfully, internalize it:
  - What was done, what files were changed
  - Key decisions and their reasoning
  - Open issues and where they left off
  - Notes and gotchas
- Summarize: "Loaded context from '<name>'. They were working on X, left off at Y."
- This context should inform your work going forward
- If no snapshot found, suggest `/context-list` to see available ones
