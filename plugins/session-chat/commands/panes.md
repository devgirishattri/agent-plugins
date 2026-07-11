---
description: List named tmux panes in the current tmux session, or all sessions
argument-hint: "[all]"
allowed-tools: Bash(bash:*)
---

## Named Panes

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/list-panes.sh" "$ARGUMENTS"`

## Instructions

Do not narrate or add a preamble. Render the table directly.

Present the tab-separated data above as a markdown table:

| Name | Pane | Command | Location |

Rules:
- If the output is an `ERROR:` line (e.g. the tmux socket was denied with `Operation not permitted`), do NOT report "no named panes" — surface the error verbatim, including its escalated/approved retry hint, so the user knows the listing was blocked rather than empty
- If no panes are listed (and there was no error), tell the user no named panes were found
- Suggest `/whoami <name>` to name the current pane
- Suggest `/send <name> <message>` to message a pane
- Mention `/panes all` only when the user needs panes from every tmux session
