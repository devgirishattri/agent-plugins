---
description: Load a session context summary to continue where another session left off
argument-hint: <snapshot-name>
allowed-tools: Bash(bash:*), Read
---

## Session Context

!`export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"; bash ${CLAUDE_PLUGIN_ROOT}/scripts/load-context.sh $ARGUMENTS`

## Instructions

- If the context was loaded successfully, internalize it:
  - What was done, what files were changed
  - Key decisions and their reasoning
  - Open issues and where they left off
  - Notes and gotchas
- Summarize: "Loaded context from '<name>'. They were working on X, left off at Y."
- This context should inform your work going forward
- If a staleness WARNING appears at the end of the output, surface it to the user and
  suggest regenerating the snapshot with `/context-generate <name>` — treat the loaded
  content as potentially out of date
- If no snapshot found, suggest `/context-list` to see available ones
