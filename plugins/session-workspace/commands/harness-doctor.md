---
description: Read-only health check for the opt-in session-workspace harness — config validity, activation, hook registration, schema-v3/v4 guards, python3 runtime, and live identity match
argument-hint: "[--config PATH] [--json]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/harness-doctor.sh" $ARGUMENTS`

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. Report the result above.

`harness-doctor` is **strictly read-only**. It diagnoses and never repairs.

Each check reports `OK`, `INFO`, `WARN`, or `ERROR`. The command exits non-zero only when at least one check is `ERROR`. `--json` always emits one structured report, even when config validation itself fails.

The checks:

- `config.validation` — the workspace config validates and a plan resolves. Schema v1 through v4 all pass.
  - A v1 config has no harness.
  - A v3/v4 config without `harness.guards` behaves exactly like v2.
  - A v4 config without `orchestration` behaves exactly like v3.
- `harness.activation` — `OK` when `harness.enabled: true`. `INFO` when inactive.
  - When inactive, the hook is a no-op for panes launched with an empty harness mode.
  - A pane that still carries a stale `audit`/`enforce` mode is drift. `identity.live` reports it.
- `hook.registration` — checks only that the bundled `hooks/hooks.json` parses and carries non-empty hook arrays for `PreToolUse`, `SessionStart`, `UserPromptSubmit`, and `Stop`.
  - It does NOT validate the exact matchers, script targets, or arguments/options.
  - It does NOT verify that the provider has loaded and trusted the hooks. A pane cannot verify that.
  - Codex trusts each hook entry by hash. A plugin upgrade that adds or changes entries needs those hashes re-accepted.
- `guards.configuration` — `OK` when the validated plan exposes schema-v3/v4 `harness.guards` packs. `INFO` when none are configured.
  - The lifecycle and Stop guard hooks are silent no-ops unless two conditions hold. The pane was launched with a guarded v3/v4 config (`SESSION_WORKSPACE_GUARDS_JSON` present). The matching feature flag is on.
  - Stop workspace-health diagnostics emit only from the configured orchestrator pane.
- `runtime.python3` — required only while a harness is active. An active harness without `python3` fails closed: every gated tool call is blocked.
- `identity.env` — whether this process inherits engine identity. `INFO` when none. `OK` when all five core variables are present. `ERROR` when only some are.
  - `identity.live` checks harness mode and guarded-v3/v4 identity separately.
  - An active policy blocks a partial core identity.
- `identity.alias` — `SESSION_CHAT_PANE_NAME` / `KNOWLEDGE_PANE_NAME` agree with `SESSION_WORKSPACE_PANE_NAME`. A disagreement is `ERROR`.
  - An *active* policy blocks a disagreement.
  - An inactive config with an empty launcher mode no-ops before the alias check. There, `identity.live` stays a no-op.
- `identity.live` — the verdict of `harness-policy.py` *itself*. It is probed in this process with a harmless unknown-tool payload. It is the policy engine's decision for this environment. It presumes the bundled hook is loaded and trusted. It is not proof of runtime enforcement. Verdicts:
  - `OK` — active, accepted.
  - `ERROR` — active and blocking every gated call here. The output shows the rule and reason. Restart the pane's configured session via `/session-workspace:workspace-restart <session-id>`. That kills and recreates all of that session's configured panes.
  - `INFO` — the hook is a no-op here.
  - `WARN` — a no-op for one of three reasons. Identity is partial. The inherited identity does not match an *inactive* config. python3 is missing, so the probe could not run.

Relay the per-check lines and the `summary:` line verbatim. Do not run any fix yourself. Restarting sessions and editing the config are the user's decisions.
