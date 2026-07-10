---
description: Check liveness, message backlog, and lock state of named tmux panes
argument-hint: "[name] [--all]"
---

## Instructions

1. Parse `$ARGUMENTS`: optional pane name (check one pane) or `--all` (every session); no arguments checks the current session.
2. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

3. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/pane-health.sh" [name] [--all]
   ```

4. Present the tab-separated output as a markdown table: | Name | Pane | Status | Command | Location | Backlog | Send-Lock |
5. Flag a Location that does not match the intended repo/worktree before dispatch.
6. `DEAD` means the pane's process exited — sends to it will queue forever; the user should restart it or remove the pane.
7. `DUPLICATE` means two panes share a name; rename one with `$session-chat:whoami` in that pane.
8. Backlog `ready/total` > 0 means messages are waiting for that pane's next turn; if it stays non-zero the pane may be stuck.
9. `STALE(pid)` send-lock means a crashed sender left a lock behind; it is reclaimed automatically on the next send.
