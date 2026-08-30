---
name: harness-status
description: "Show whether the session-workspace strict-v1 harness is active and whether the current pane identity matches its validated config. Use for harness activation, role, mode, and identity status."
---

# harness-status

When invoked, run the read-only status script and return its result without a
preamble.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Never infer it from cwd or
hardcode a cache version.

```bash
bash "$PLUGIN_ROOT/scripts/harness-status.sh" $ARGUMENTS
```

Flags:

- `--config PATH` selects a workspace config instead of discovery.
- `--json` emits the normalized status object.

The command reports activation, audit/enforce mode, the immutable `strict-v1`
profile, semantic roles, gate TTLs, and live identity matching. It is strictly
read-only.

Interpret `identity:` as follows: `not present` is expected outside a
workspace-launched pane; `MATCH` is complete and alias-consistent; `PARTIAL`
fails closed when active; `MISMATCH` means config, pane, role, cwd, mode, or
pane-name alias drift. The `policy:` line is the live policy-engine verdict
(`no-op`, active/accepted, or `BLOCKING [rule] reason`) assuming the bundled
hook is loaded and trusted; it does not prove runtime hook loading. Never
suggest editing the six `SESSION_WORKSPACE_*` variables or pane aliases by
hand; recommend `$session-workspace:workspace-restart` for active drift.
