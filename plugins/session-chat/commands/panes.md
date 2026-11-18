---
description: List named tmux panes in the current tmux session, or all sessions
argument-hint: "[all]"
allowed-tools: Bash(bash:*)
---

## Named Panes

Requested scope: `$ARGUMENTS`

If the requested scope above is empty, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/list-panes.sh"` with no arguments. If it is `all`, append the single literal argument `all`. Reject any other value.

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. Render the table directly.

Present the tab-separated result as a markdown table:

| Name | Pane | Command | Location |

Rules:
- If the output is an `ERROR:` line (e.g. the tmux socket was denied with `Operation not permitted`), do NOT report "no named panes". Surface the error verbatim, including its escalated/approved retry hint. The user must know that the listing was blocked, not empty.
- If no panes are listed and there was no error, tell the user that no named panes were found.
- Suggest `/whoami <name>` to name the current pane
- Suggest `/send <name> <message>` to message a pane
- Mention `/panes all` only when the user needs panes from every tmux session
