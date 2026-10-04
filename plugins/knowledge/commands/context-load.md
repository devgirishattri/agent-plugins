---
description: Load a session context summary to continue where another session left off
argument-hint: <snapshot-name>
allowed-tools: Bash(bash:*), Read
---

## Session Context

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/load-context.sh" $ARGUMENTS`

## Instructions

`SESSION_CONTEXT_HOME` must already be present in this session's environment, inherited when the agent process started. If the output above reports that it is not set, stop. Ask the user to relaunch this pane or session with the correct environment. Do not export the variable. Do not derive another context store.

If the context loaded successfully:
1. Internalize it:
   - what was done and which files changed
   - key decisions and their reasoning
   - open issues and where the previous session left off
   - notes and gotchas
2. Report the result in one line: "Loaded context from '<name>'. They were working on X, left off at Y."
3. Use the context to inform your work from now on.

If a staleness WARNING appears at the end of the output:
1. Show the warning to the user.
2. Suggest that the user regenerate the snapshot with `/context-generate <name>`.
3. Treat the loaded content as potentially out of date.

If no snapshot is found, suggest `/context-list` to see the available snapshots.
