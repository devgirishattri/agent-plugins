---
description: Tear down session-workspace sessions/panes (destructive; requires --confirmed)
argument-hint: "[TARGET|all] [--config PATH] [--no-save] --confirmed [--all] | SESSION --pane NAME [--pane NAME...] --confirmed [--force]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Run:

   ```bash
   ARGUMENTS="${ARGUMENTS:-}"
   bash "$PLUGIN_ROOT/scripts/workspace-stop.sh" $ARGUMENTS
   ```

3. Real interface:
   - `TARGET|all`: optional `sessions[].id` filter; default is `all`.
   - `--config PATH`: use a specific workspace config instead of discovery.
   - `--no-save`: skip layout save and tmux-resurrect save.
   - `--confirmed`: required; without it the command refuses to run.
   - `--all`: widen from configured/selected sessions to every live session
     marked for the current project.
   - `SESSION --pane NAME --confirmed` (repeatable `--pane`): stop only the
     named service panes, or on-demand executor/reviewer workers, of one
     session; the session and its other panes keep running. Cannot be
     combined with `--all` or `--no-save`.
   - `--force` (with `--pane` only): stop an on-demand worker even while it
     is busy. Use it only when the user asks.

4. Safety/behavior:
   - Stop is destructive and must not be run without explicit user intent.
   - It validates config, takes the project lock, and targets tmux sessions by
     exact name.
   - It kills only sessions carrying this project's managed marker. A same-name
     unmanaged session is skipped.
   - When saving is enabled, it preserves retained layouts and invokes
     tmux-resurrect if available. It sends `C-c` to managed non-idle panes,
     waits the configured grace period, then kills the marked session.
   - With `--pane`, it does the same for each named managed pane, records the
     stop in the pane's run record, closes only that pane, and prints
     `stopped: N  not running: N  skipped: N  busy: N`. A pane that is not
     running is reported `[absent]`.
   - An on-demand worker is stopped only when it is idle. A worker with a
     task still `assigned` to it, a task it reviews in `review`, unread
     session-chat messages, or a running turn on screen is reported `[busy]
     ... left running: <reasons>`, and the command exits 1. Relay the
     reasons.
