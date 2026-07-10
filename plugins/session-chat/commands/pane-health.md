---
description: Check liveness, message backlog, and lock state of named tmux panes
argument-hint: "[name] [--all]"
allowed-tools: Bash(bash:*)
---

## Pane Health

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/pane-health.sh" $ARGUMENTS`

## Instructions

Do not narrate or add a preamble. Render the result directly.

Present the tab-separated data above as a markdown table:

| Name | Pane | Status | Command | Location | Backlog | Send-Lock |

Rules:
- `DEAD` means the pane's process exited — sends to it will queue forever; the user should restart it or remove the pane
- `DUPLICATE` means two panes share a name and neither is reachable — rename one via `/whoami` in that pane
- `Location` is the pane's working directory — flag it if a worker is in an unexpected repo/worktree for the task it's about to receive
- Backlog `ready/total` > 0 means messages are waiting for that pane's next turn; if it stays non-zero the pane may be stuck
- `STALE(pid)` send-lock means a crashed sender left a lock behind; it is reclaimed automatically on the next send, or can be removed manually
- With no arguments this checks the current session; pass a name to check one pane, or `--all` for every session
