---
description: Remove a context snapshot for the current project
argument-hint: <snapshot-name>
allowed-tools: Bash(bash:*)
---

## Remove Context

!`export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"; bash ${CLAUDE_PLUGIN_ROOT}/scripts/remove-context.sh $ARGUMENTS`

## Instructions

- If removed successfully, confirm: "Removed context snapshot '<name>'."
- If no snapshot found, suggest `/context-list` to see what's available.
- If no argument was given, ask the user which snapshot to remove and run `/context-list`.
