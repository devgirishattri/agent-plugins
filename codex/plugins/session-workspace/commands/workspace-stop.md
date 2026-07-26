---
description: Tear down session-workspace sessions/panes (destructive; requires --confirmed)
argument-hint: "[TARGET|all] [--config PATH] [--no-save] --confirmed [--all]"
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

4. Safety/behavior:
   - Stop is destructive and must not be run without explicit user intent.
   - It validates config, takes the project lock, and targets tmux sessions by
     exact name.
   - It kills only sessions carrying this project's managed marker. A same-name
     unmanaged session is skipped.
   - When saving is enabled, it preserves retained layouts and invokes
     tmux-resurrect if available. It sends `C-c` to managed non-idle panes,
     waits the configured grace period, then kills the marked session.
