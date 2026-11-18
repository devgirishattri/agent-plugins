---
description: Dry-run plan for session-workspace session/pane lifecycle (mutates nothing)
argument-hint: "[TARGET|all] [--config PATH] [--json] [--running]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Run:

   ```bash
   ARGUMENTS="${ARGUMENTS:-}"
   bash "$PLUGIN_ROOT/scripts/workspace-plan.sh" $ARGUMENTS
   ```

3. Real interface:
   - `TARGET|all`: optional `sessions[].id` filter; default is `all`.
   - `--config PATH`: use a specific workspace config instead of discovery.
   - `--json`: emit the resolved plan as JSON instead of the human report.
   - `--running`: add a read-only `running` field to each pane (true when the
     managed pane is alive and launched, `null` without tmux).

4. Safety/behavior:
   - The plan reads the config, resolves pane working directories, and applies worker names from the project's `labels.json` when present. It writes no state. Only `--running` reads tmux.
   - Unknown targets exit non-zero with the known session ids.
   - An executor/reviewer with `"launch": "on_demand"` is marked `(on demand:
     a full start leaves it down; start it with --pane)`, and its `--json`
     pane carries `"launch": "on_demand"` (every other pane `"always"`).
   - The human report shows env variable names only. It never prints env values
     or secret values.
