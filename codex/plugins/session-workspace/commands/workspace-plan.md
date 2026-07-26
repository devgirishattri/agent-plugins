---
description: Dry-run plan for session-workspace session/pane lifecycle (mutates nothing)
argument-hint: "[TARGET|all] [--config PATH] [--json]"
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

4. Safety/behavior:
   - This command is mutation-free. It validates config, canonicalizes pane
     `cwd` paths, and computes the normalized plan without touching tmux or any
     state directory.
   - Unknown targets exit non-zero with the known session ids.
   - The human report shows env variable names only. It never prints env values
     or secret values.
