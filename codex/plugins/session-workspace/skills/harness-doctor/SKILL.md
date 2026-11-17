---
name: harness-doctor
description: "Read-only validation for the session-workspace harness config, hook registration, Python runtime, and live pane identity. Use to diagnose harness setup or fail-closed identity errors."
---

# harness-doctor

When invoked, run the read-only doctor and return its result without a
preamble.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Never infer it from cwd or
hardcode a cache version.

```bash
bash "$PLUGIN_ROOT/scripts/harness-doctor.sh" $ARGUMENTS
```

Flags:

- `--config PATH` selects a workspace config instead of discovery.
- `--json` always emits one structured report, even when config validation
  fails.

The doctor never starts, stops, adopts, repairs, or edits a workspace. Relay
its `OK`, `INFO`, `WARN`, and `ERROR` checks plus the summary. The identity
checks are:

- `identity.env` — absent, complete, or partial engine identity.
- `identity.alias` — session-chat and knowledge pane aliases agree with the
  engine pane name.
- `identity.live` — `harness-policy.py`'s own verdict in this process: `OK`
  active/accepted, `ERROR` active/blocking, `INFO` for an ordinary no-op, or `WARN` for an inactive identity mismatch. If the probe cannot run, it reports `WARN` with inherited identity and `INFO` without it. This predicts the bundled
  hook's decision when Codex loads and trusts it; it does not prove runtime
  hook loading. Likewise, `hook.registration` checks the bundled `hooks.json`
  entry, not runtime trust/loading.

Do not apply remediation unless the user separately asks for a change. For an
active identity failure, recommend `$session-workspace:workspace-restart` and
never suggest editing engine identity variables by hand.
