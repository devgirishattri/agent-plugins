---
description: Label this session's tmux pane for messaging
argument-hint: <name>
allowed-tools: Bash(bash:*)
---

## Instructions

1. If $ARGUMENTS is empty, ask the user for a name
2. Validate the name: no spaces, no special characters except hyphens and underscores
3. Run this command to set the pane name:
   ```
   bash -c 'source ${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh && set_pane_name "$TMUX_PANE" "$ARGUMENTS"'
   ```
4. Report: "This pane is now '$ARGUMENTS'. Other sessions can reach you via `/send $ARGUMENTS <message>`."
5. Suggest: "Run `/panes` to see all named panes."
