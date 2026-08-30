---
description: Show the opt-in session-workspace harness state (mode, profile, roles, gates) and whether this pane's engine identity matches the validated plan
argument-hint: "[--config PATH] [--json]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/harness-status.sh" $ARGUMENTS`

## Instructions

Do not narrate or add a preamble. Report the result above.

`harness-status` is **read-only** — it validates the config, computes the
normalized plan, and reports the harness block: `inactive` (schema v1, no
`harness`, or `enabled: false`) or `active` with its `mode` (`audit` |
`enforce`), `profile` (`strict-v1`), semantic `roles`, and `gates`.

The `identity:` line reads this pane's engine-owned environment
(`SESSION_WORKSPACE_CONFIG`, `_PROJECT_ROOT`, `_PANE_NAME`, `_ROLE`,
`_PANE_CWD`, `_HARNESS_MODE`):
- `not present` — this process was not launched by `workspace-start`; the
  PreToolUse hook is a no-op here.
- `MATCH` — identity agrees with the validated plan; an active harness
  enforces the strict-v1 floor for the shown role.
- `PARTIAL` — only some identity variables are set; an active policy
  fails closed on this.
- `MISMATCH` — identity disagrees with the config (drift, a renamed pane, a
  config edited after launch, or a `SESSION_CHAT_PANE_NAME` /
  `KNOWLEDGE_PANE_NAME` alias that disagrees). An **active** harness fails
  closed: every Edit/Write/Bash call is blocked until the pane is restarted
  via `/workspace-restart`. Relay that remedy verbatim.

The `policy:` line is `harness-policy.py`'s own verdict for this process
(`no-op`, `active ... identity accepted`, or `BLOCKING [rule] reason`) —
the policy engine's decision for this environment, assuming the bundled
hook is loaded and trusted by the provider (which cannot be verified from
inside a pane).

`--json` emits the same object machine-readably. Never suggest editing the
identity variables by hand — they are an authorization boundary and are only
ever set by the engine at launch.
