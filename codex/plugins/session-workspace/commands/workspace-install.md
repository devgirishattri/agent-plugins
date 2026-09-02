---
description: Install the machine-wide `workspace` dispatcher onto PATH (idempotent; also the refresh)
argument-hint: "[--target PATH] [--dry-run]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Run:

   ```bash
   ARGUMENTS="${ARGUMENTS:-}"
   bash "$PLUGIN_ROOT/scripts/workspace-install.sh" $ARGUMENTS
   ```

3. Real interface:
   - `--target PATH`: install location (default `~/.local/bin/workspace`).
   - `--dry-run`: report what would happen; write nothing.

4. What it does: copies `templates/workspace-dispatcher.sh` from this plugin
   to the target. That dispatcher is what FINDS the plugin at run time, so it
   must live on PATH rather than inside a versioned cache — which makes it a
   copy that can go stale. This verb creates it and is also the sanctioned
   refresh. It is idempotent: an identical executable target reports `already
   current` and writes nothing; an identical target missing its executable bit
   is repaired in place. An external plugin-upgrade flow may call it after every
   update without churn.

5. It needs no config and touches no tmux — it works on a fresh machine with
   no `.agent-workspace/` anywhere. A differing existing target is backed up
   to `<target>.bak` before being overwritten; an identical target is left
   untouched. After copying it verifies the
   installed file answers `--contract`, reports PATH membership, and prints an
   optional `alias ws=workspace` line. It NEVER edits a shell rc file — relay
   that line verbatim for the user to add themselves.

6. Relay the per-step lines and any `[warn]` verbatim. A contract `[warn]`
   means no provider has the plugin installed yet; a PATH `[warn]` means the
   target directory must be added to PATH before the command is runnable.
