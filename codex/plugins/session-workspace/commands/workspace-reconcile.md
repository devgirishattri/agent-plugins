---
description: Reconcile drifted tmux state against config; only sanctioned path for adopting unmanaged panes
argument-hint: "[TARGET|all] [--config PATH] [--apply] [--adopt --confirmed]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Run:

   ```bash
   ARGUMENTS="${ARGUMENTS:-}"
   bash "$PLUGIN_ROOT/scripts/workspace-reconcile.sh" $ARGUMENTS
   ```

3. Real interface:
   - `TARGET|all`: optional `sessions[].id` filter; default is `all`.
   - `--config PATH`: use a specific workspace config instead of discovery.
   - `--apply`: perform repairs. Without it, reconcile is a dry run.
   - `--adopt --confirmed`: allow an occupied unmanaged pane to be claimed.

4. Safety/behavior:
   - Dry-run mode mutates nothing and prints that `--apply` is required to act.
   - Applying takes the project lock, validates config, and repairs missing or
     unhealthy managed slots without restarting healthy panes.
   - Adoption is refused unless both `--adopt` and `--confirmed` are present.
     When applying an adoption, the command prints the occupant details before
     claiming the pane.
   - Unknown targets exit non-zero.
