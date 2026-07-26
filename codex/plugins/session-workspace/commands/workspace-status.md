---
description: Show current session-workspace lifecycle state
argument-hint: "[TARGET|all] [--config PATH] [--json]"
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

4. Safety/behavior:
   - Status is read-only. It validates config and reads tmux state, but does not
     create sessions, write state files, repair panes, or kill anything.
   - For each planned pane it reports session existence/managed status, pane id,
     role, runtime, configured model, cwd, foreground process, and health
     (`missing`, `dead`, `healthy`, or `unmanaged-occupant`).
   - The current script filters unmatched targets to an empty result rather than
     erroring; use `workspace-plan TARGET` first when you need strict target
     validation.
