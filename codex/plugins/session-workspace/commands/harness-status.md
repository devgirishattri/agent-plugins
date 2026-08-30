---
description: Show the opt-in session-workspace harness activation and live pane identity
argument-hint: "[--config PATH] [--json]"
---

## Instructions

Resolve `PLUGIN_ROOT` from this installed plugin. Run:

```bash
bash "$PLUGIN_ROOT/scripts/harness-status.sh" $ARGUMENTS
```

This surface is strictly read-only. It reports the normalized active profile,
mode, semantic roles, and gate TTLs.

The `identity:` line checks all six engine-owned `SESSION_WORKSPACE_*`
variables plus `SESSION_CHAT_PANE_NAME` / `KNOWLEDGE_PANE_NAME` aliases:

- `not present` means this process was not workspace-launched.
- `MATCH` means the complete identity and aliases agree with the plan.
- `PARTIAL` means only some identity variables are set; an active policy fails
  closed.
- `MISMATCH` means the identity, config, pane, role, cwd, mode, or alias has
  drifted. Restart the pane through
  `$session-workspace:workspace-restart`; never edit identity variables by
  hand.

The `policy:` line is the live `harness-policy.py` engine verdict for this
process (`no-op`, active/accepted, or `BLOCKING [rule] reason`). It predicts
what the bundled hook will do when that hook is loaded and trusted; it does not
prove that the Codex runtime loaded or trusted the hook. `--json` emits the
same status machine-readably.
