---
description: Remove a context snapshot for the current project
argument-hint: <snapshot-name>
allowed-tools: Bash(bash:*)
---

## Remove Context

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/remove-context.sh $ARGUMENTS`

## Instructions

- If removed successfully, confirm: "Removed context snapshot '<name>'."
- If no snapshot found, suggest `/context-list` to see what's available.
- If no argument was given, ask the user which snapshot to remove and run `/context-list`.
