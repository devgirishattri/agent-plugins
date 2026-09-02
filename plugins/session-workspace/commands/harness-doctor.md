---
description: Read-only health check for the opt-in session-workspace harness — config validity, activation, hook registration, schema-v3/v4 guards, python3 runtime, and live identity match
argument-hint: "[--config PATH] [--json]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/harness-doctor.sh" $ARGUMENTS`

## Instructions

Do not narrate or add a preamble. Report the result above.

`harness-doctor` is **strictly read-only** — it diagnoses and never repairs.
Each check reports `OK`, `INFO`, `WARN`, or `ERROR`; the command exits
non-zero only when at least one check is `ERROR`, and `--json` always emits
one structured report (even when config validation itself fails):

- `config.validation` — the workspace config validates and a plan resolves
  (schema v1 through v4 all pass; a v1 config simply has no harness, a
  v3/v4 config without `harness.guards` behaves exactly like v2, and a v4
  config without `orchestration` behaves exactly like v3).
- `harness.activation` — `OK` when `harness.enabled: true`, `INFO` when
  inactive (the hook is then a no-op for panes launched with an empty
  harness mode; a pane still carrying a stale `audit`/`enforce` mode is
  drift and `identity.live` reports it).
- `hook.registration` — checks only that the bundled `hooks/hooks.json`
  parses and carries non-empty hook arrays for `PreToolUse`, `SessionStart`,
  `UserPromptSubmit`, and `Stop`. It does NOT validate the exact matchers,
  script targets, arguments/options, or whether the provider has actually
  loaded and trusted the hooks (that cannot be verified from inside a pane —
  Codex trusts each hook entry by hash, so a plugin upgrade that adds or
  changes entries needs those hashes re-accepted).
- `guards.configuration` — `OK` when the validated plan exposes schema-v3/v4
  `harness.guards` packs, `INFO` when none are configured. The lifecycle and
  Stop guard hooks are silent no-ops unless the pane was launched with a
  guarded v3/v4 config (`SESSION_WORKSPACE_GUARDS_JSON` present) and the
  matching feature flag is on; Stop workspace-health diagnostics emit only
  from the configured orchestrator pane.
- `runtime.python3` — required only while a harness is active; an active
  harness without `python3` fails closed (every gated tool call is blocked).
- `identity.env` — whether this process inherits engine identity:
  `INFO` when none, `OK` when all five core variables are present, `ERROR`
  when only some are. Harness mode and guarded-v3/v4 identity are checked
  separately by `identity.live`; a partial core identity is blocked by an
  active policy.
- `identity.alias` — `SESSION_CHAT_PANE_NAME` / `KNOWLEDGE_PANE_NAME` agree
  with `SESSION_WORKSPACE_PANE_NAME`; a disagreement is `ERROR`, and an
  *active* policy blocks it (an inactive config with an empty launcher mode
  no-ops before the alias check, so there `identity.live` stays a no-op).
- `identity.live` — the verdict of `harness-policy.py` *itself*, probed in
  this process with a harmless unknown-tool payload: the policy engine's
  decision for this environment (it presumes the bundled hook is loaded and
  trusted; it is not proof of runtime enforcement): `OK` (active, accepted), `ERROR`
  (active and blocking every gated call here — the rule and reason are
  shown; restart the pane's configured session via
  `/session-workspace:workspace-restart <session-id>`, which kills and
  recreates all of that session's configured panes), `INFO` (the hook is a
  no-op here), or `WARN` (no-op only because identity is partial, or the
  inherited identity does not match an *inactive* config, or python3 is
  missing so it could not be probed).

Relay the per-check lines and the `summary:` line verbatim. Do not run any
fix yourself — restarting sessions and editing the config are the user's call.
