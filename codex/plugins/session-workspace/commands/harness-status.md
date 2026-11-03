---
description: Show the opt-in session-workspace harness activation, the strict-v1 role floor, and live pane identity
argument-hint: "[--config PATH] [--json] [--probe]"
---

## Instructions

Resolve `PLUGIN_ROOT` from this installed plugin. Run:

```bash
bash "$PLUGIN_ROOT/scripts/harness-status.sh" $ARGUMENTS
```

This surface is strictly read-only. It reports the normalized active profile,
mode, semantic roles, and gate TTLs.

The `floor (strict-v1, not configurable):` lines show the immutable role floor
that `harness-policy.py` enforces, generated from the policy's own tables. In a
pane with an accepted identity, they show that pane's role and an `all roles`
line. Without one, they show every role. `<name> (confined)` is an environment
coordinator whose cwd is not the project root.

The `optional guard packs:` line shows only the configured `harness.guards`
packs, or `none (schema-v2-compatible behavior)`. The packs add to the floor.
They are not the complete list of what is enforced, and "no packs" never means
that reviewer read-only or executor containment is off.

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
prove that the Codex runtime loaded or trusted the hook.

`--probe` adds a `probe` section: the policy decides each built-in floor case
for this pane's own role through the hook's code path. It runs no command and
writes no file. A line that starts with `UNEXPECTED` is a case the policy did
not decide as the floor states, and the script then exits 1. Report those lines
verbatim. Without an accepted identity, the probe is not run.

`--json` emits the same status machine-readably: `floor` holds the role floor,
`guards` holds only the optional packs, and `probe` is `null` without
`--probe`.
