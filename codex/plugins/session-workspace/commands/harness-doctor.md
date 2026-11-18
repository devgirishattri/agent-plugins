---
description: Validate session-workspace harness config, hook runtime, and live identity
argument-hint: "[--config PATH] [--json]"
---

## Instructions

Resolve `PLUGIN_ROOT` from this installed plugin. Run:

```bash
bash "$PLUGIN_ROOT/scripts/harness-doctor.sh" $ARGUMENTS
```

This surface is strictly read-only. It never starts, stops, adopts, repairs,
or edits a workspace. Each check reports `OK`, `INFO`, `WARN`, or `ERROR`; the
command exits non-zero only when a check is `ERROR`. `--json` always emits one
structured report, including when config validation fails.

Relay these checks and the summary without applying fixes:

- `config.validation` and `harness.activation` cover the normalized plan and
  explicit opt-in state.
- `hook.registration` checks the bundled `hooks.json` entry only; it cannot
  prove that Codex loaded or trusted the hook. `runtime.python3` covers the
  active-policy runtime.
- `guards.configuration` reports `OK` when the plan exposes guard packs and `INFO` when none are configured.
- `identity.env` distinguishes absent, complete, and partial engine identity.
- `identity.alias` checks the session-chat and knowledge pane aliases.
- `identity.live` is a live probe of `harness-policy.py` in this process: `OK`
  means active/accepted, `ERROR` means an active blocking rule, `INFO` means a
  true no-op, and `WARN` describes an inactive identity mismatch. If the probe cannot run, it reports `WARN` with inherited identity and `INFO` without it. It predicts the bundled hook's decision when that hook is
  loaded and trusted; it does not verify runtime hook loading.

For an active identity error, relay the rule and reason and recommend
`$session-workspace:workspace-restart <session-id>` for the session containing the pane. Check `behavior.stop_scope` first. If it is `all`, a targeted restart stops all project-marked sessions and starts only the named session. A full start leaves on-demand workers down. Leave engine identity variables to the launcher.
