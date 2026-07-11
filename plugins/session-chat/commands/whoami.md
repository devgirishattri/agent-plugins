---
description: Show or set this session's tmux pane name for messaging
argument-hint: "[name]"
allowed-tools: Bash(bash:*)
---

## Current Name

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/get-my-name.sh`

## Instructions

Do not narrate or add a preamble. Run the action directly and report only the result.

1. If the Current Name output above is an `ERROR:` line (e.g. the tmux socket was denied with `Operation not permitted`), do NOT report "No name set" — the query was blocked, not empty. Surface the error verbatim, including its escalated/approved retry hint, and stop.

2. If a current name is shown above (non-empty), and $ARGUMENTS is empty:
   - Report: "This pane is named '**<name>**'. Other sessions can reach you via `/send <name> <message>`."

3. If $ARGUMENTS is provided, set a new name:
   - Validate: only alphanumeric, hyphens, underscores allowed
   - Run: `bash -c 'source ${CLAUDE_PLUGIN_ROOT}/scripts/lib.sh && set_pane_name "$TMUX_PANE" "<name>"'`
   - Report: "Pane renamed to '**<name>**'." If that command instead prints an `ERROR:` about the tmux socket being denied, surface it verbatim with its retry hint rather than claiming the rename succeeded.

4. If both current name and $ARGUMENTS are empty:
   - Report: "No name set. Use `/whoami <name>` to set one."
