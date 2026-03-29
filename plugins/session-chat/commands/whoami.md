---
description: Show or set this session's tmux pane name for messaging
argument-hint: [name]
allowed-tools: Bash(bash:*)
---

## Current Name

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/get-my-name.sh`

## Instructions

1. If a current name is shown above (non-empty), and $ARGUMENTS is empty:
   - Report: "This pane is named '**<name>**'. Other sessions can reach you via `/send <name> <message>`."

2. If $ARGUMENTS is provided, set a new name:
   - Validate: only alphanumeric, hyphens, underscores allowed
   - Run: `bash -c 'source ${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh && set_pane_name "$TMUX_PANE" "<name>"'`
   - Report: "Pane renamed to '**<name>**'."

3. If both current name and $ARGUMENTS are empty:
   - Report: "No name set. Use `/whoami <name>` to set one, or `/rename <name>` and it will sync automatically."
