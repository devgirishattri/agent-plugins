---
description: Check liveness, message backlog, and lock state of named tmux panes
argument-hint: [name] [--all]
---

## Instructions

1. Parse `$ARGUMENTS`: optional pane name (check one pane) or `--all` (every session); no arguments checks the current session.
2. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.15.5}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
   ```

3. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/pane-health.sh" [name] [--all]
   ```

4. Present the tab-separated output as a markdown table: | Name | Pane | Status | Command | Backlog | Send-Lock |
5. `DEAD` means the pane's process exited — sends to it will queue forever; the user should restart it or remove the pane.
6. `DUPLICATE` means two panes share a name and neither is reachable — rename one via `/whoami` in that pane.
7. Backlog `ready/total` > 0 means messages are waiting for that pane's next turn; if it stays non-zero the pane may be stuck.
8. `STALE(pid)` send-lock means a crashed sender left a lock behind; it is reclaimed automatically on the next send.
