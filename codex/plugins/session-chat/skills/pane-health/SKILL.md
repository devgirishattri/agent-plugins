---
name: pane-health
description: "Check liveness, message backlog, and send-lock state of named tmux panes through session-chat. Use when the user asks whether panes or workers are alive, stuck, unreachable, or have queued messages."
---

# Pane Health

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from cwd or hardcode a marketplace cache version.

Parse an optional pane name (check one pane) or `--all` (every session); no arguments checks the current session.

Run:

```bash
bash "$PLUGIN_ROOT/scripts/pane-health.sh" [name] [--all]
```

Present the tab-separated output as a table: Name, Pane, Status, Command, Location, Backlog, Send-Lock.
Flag `Location` when a worker is in an unexpected repo or worktree for the task it is about to receive.
`DEAD` means the pane's process exited — sends to it will queue forever.
`DUPLICATE` means two panes share a name — rename one with `$session-chat:whoami <name>` in that pane.
Backlog `ready/total` > 0 means messages are waiting for that pane's next turn; if it stays non-zero the pane may be stuck.
`STALE(pid)` send-lock means a crashed sender left a lock behind; it is reclaimed automatically on the next send.
