---
description: Check liveness, message backlog, and lock state of named tmux panes
argument-hint: "[name] [--all]"
allowed-tools: Bash(bash:*)
---

## Pane Health

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/pane-health.sh" $ARGUMENTS`

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. Render the result directly.

Present the tab-separated data above as a markdown table:

| Name | Pane | Status | Command | Location | Backlog | Send-Lock |

Rules:
- If the output is an `ERROR:` line (e.g. the tmux socket was denied with `Operation not permitted`), do NOT report "no named panes". Surface the error verbatim, including its escalated/approved retry hint. The user must know that the health check was blocked, not clean.
- `DEAD` means the pane's process exited. Sends to it queue forever. The user should restart the pane or remove it.
- `DUPLICATE` means two panes share a name and neither is reachable. Rename one via `/whoami` in that pane.
- `Location` is the pane's working directory. Flag it if a worker is in an unexpected repo or worktree for the task it is about to receive.
- Backlog `ready/total` > 0 means messages are waiting for that pane's next turn. If it stays non-zero, the pane may be stuck.
- `STALE(pid)` send-lock means a crashed sender left a lock behind. The next send reclaims it automatically. You can also remove it manually.
- With no arguments, the check covers the current session. Pass a name to check one pane. Pass `--all` for every session.
