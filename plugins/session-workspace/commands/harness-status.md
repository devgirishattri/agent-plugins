---
description: Show the opt-in session-workspace harness state (mode, profile, roles, gates, schema-v3/v4 guards) and whether this pane's engine identity matches the validated plan
argument-hint: "[--config PATH] [--json]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/harness-status.sh" $ARGUMENTS`

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. Report the result above.

`harness-status` is **read-only**. It validates the config, computes the normalized plan, and reports the harness block. The block is either `inactive` (schema v1, no `harness`, or `enabled: false`) or `active`. An `active` block shows its `mode` (`audit` | `enforce`), `profile` (`strict-v1`), semantic `roles`, and `gates`.

A `guards:` line follows. It shows the schema-v3/v4 `harness.guards` packs as canonical JSON, or `none (schema-v2-compatible behavior)`.

The `identity:` line reads this pane's engine-owned environment. The variables are `SESSION_WORKSPACE_CONFIG`, `_PROJECT_ROOT`, `_PANE_NAME`, `_ROLE`, `_PANE_CWD`, and `_HARNESS_MODE`. A guarded schema-v3/v4 launch adds `_GUARDS_JSON`, which must equal the validated `harness.guards` exactly. The line shows one of these values:

- `not present` — `workspace-start` did not launch this process. The PreToolUse hook is a no-op here.
- `MATCH` — identity agrees with the validated plan. An active harness enforces the strict-v1 floor for the shown role.
- `PARTIAL` — only some identity variables are set. An active policy fails closed on this.
- `MISMATCH` — identity disagrees with the config. Causes: drift, a renamed pane, a config edited after launch (including any change to `harness.guards`), or a `SESSION_CHAT_PANE_NAME` / `KNOWLEDGE_PANE_NAME` alias that disagrees.

An **active** harness fails closed on `MISMATCH`. Every Edit/Write/Bash call is blocked until the user restarts the configured session that contains this pane. The remedy is `/session-workspace:workspace-restart <session-id>`. It kills and recreates all of that session's configured panes, not just this one. Relay that remedy verbatim.

The `policy:` line is `harness-policy.py`'s own verdict for this process: `no-op`, `active ... identity accepted`, or `BLOCKING [rule] reason`. It is the policy engine's decision for this environment. It assumes the provider has loaded and trusted the bundled hook. A pane cannot verify that.

`--json` emits the same object machine-readably.

Never suggest editing the identity variables by hand. They are an authorization boundary. Only the engine sets them, at launch.
