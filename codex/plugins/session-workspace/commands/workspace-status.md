---
description: Show current session-workspace lifecycle state
argument-hint: "[TARGET|all] [--config PATH] [--json] [--pane NAME...]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Run:

   ```bash
   ARGUMENTS="${ARGUMENTS:-}"
   bash "$PLUGIN_ROOT/scripts/workspace-status.sh" $ARGUMENTS
   ```

3. Real interface:
   - `TARGET|all`: optional session id filter; default is `all`.
   - `--config PATH`: use a specific workspace config instead of discovery.
   - `--json`: emit the status rows as JSON.
   - `SESSION --pane NAME`: restrict the report to the named service panes.

4. Safety/behavior:
   - Status is read-only. It validates config and reads tmux state, but does not
     create sessions, write state files, repair panes, or kill anything.
   - For each planned pane it reports session existence/managed status, pane id,
     role, runtime, configured model, cwd, foreground process, and health
     (`missing`, `dead`, `healthy`, or `unmanaged-occupant`).
   - Each pane also reports `running=yes|no` (healthy and launched). A pane
     with `idle_stop_minutes` adds an `idle stop:` line (watcher state, what it
     observes such as `connections` or `connections+output`, client count,
     time until it stops) and, after a stop, a `last stop:` line with the time
     and reason.
   - A session with a browser pane gets one CDP endpoint health line, for
     example `browser: browser http://127.0.0.1:9326 — up (Chrome/131.0)
     cdp_clients=1`. Check it says `up` before a browser smoke; when it says
     `down`, run `workspace-start SESSION --pane browser`.
   - An unknown target fails with an error that lists the known session ids.
