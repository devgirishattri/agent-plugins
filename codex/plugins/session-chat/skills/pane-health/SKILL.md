---
name: pane-health
description: "Check liveness, message backlog, and send-lock state of named tmux panes through session-chat. Use when the user asks whether panes or workers are alive, stuck, unreachable, or have queued messages."
---

# Pane Health

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.16.0}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
```

Parse an optional pane name (check one pane) or `--all` (every session); no arguments checks the current session.

Run:

```bash
bash "$PLUGIN_ROOT/scripts/pane-health.sh" [name] [--all]
```

Present the tab-separated output as a table: Name, Pane, Status, Command, Backlog, Send-Lock.
`DEAD` means the pane's process exited — sends to it will queue forever.
`DUPLICATE` means two panes share a name — rename one with `$session-chat:whoami <name>` in that pane.
Backlog `ready/total` > 0 means messages are waiting for that pane's next turn; if it stays non-zero the pane may be stuck.
`STALE(pid)` send-lock means a crashed sender left a lock behind; it is reclaimed automatically on the next send.
