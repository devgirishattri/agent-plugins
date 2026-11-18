---
description: Check liveness, unsubmitted input, message backlog, and lock state of named tmux panes
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
- `UNSUBMITTED` means unsubmitted input: a session-chat message sits in that pane's input line and its agent never submitted it, so an idle pane will not act on it. Tell the user to press Enter in that pane (`tmux send-keys -t <pane> Enter`). Do not resend the message: its durable copy is still queued, and a resend duplicates it.
- `Location` is the pane's working directory. Flag it if a worker is in an unexpected repo or worktree for the task it is about to receive.
- Backlog `ready/total` > 0 means messages are waiting for that pane's next turn. If it stays non-zero, the pane may be stuck.
- `STALE(pid)` means the recorded PID is no longer live. A subsequent send can reclaim a lock with a recorded dead PID. `STALE(?)` means the PID is missing or unreadable and leaves ownership unresolved.
- With no arguments, the check covers the current session. Pass a name to check one pane. Pass `--all` for every session.
