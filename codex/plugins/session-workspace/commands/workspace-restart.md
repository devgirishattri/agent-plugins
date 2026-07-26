---
description: Stop then start session-workspace sessions/panes
argument-hint: "[TARGET|all] [--config PATH] [--no-save] [--no-agents] [--no-services] [--no-attach]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Run:

   ```bash
   ARGUMENTS="${ARGUMENTS:-}"
   bash "$PLUGIN_ROOT/scripts/workspace.sh" restart $ARGUMENTS
   ```

3. Real interface:
   - `TARGET|all`: optional `sessions[].id` filter; default is `all`.
   - `--config PATH`: use a specific workspace config instead of discovery.
   - `--no-save`: pass through to stop so layout/resurrect save is skipped.
   - `--no-agents`, `--no-services`, `--no-attach`: pass through to start.

4. Safety/behavior:
   - Restart is destructive because it stops the selected managed session(s)
     before starting them again.
   - The script calls `workspace-stop.sh ... --confirmed` internally after the
     restart command is invoked; `--confirmed` is not a user-facing restart
     flag.
   - If stop fails, start is not run.
   - Stop still kills only sessions carrying this project's managed marker, and
     start still refuses adoption without `--adopt --confirmed`.
