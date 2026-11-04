---
description: Show the opt-in session-workspace harness state (mode, profile, roles, gates, the strict-v1 role floor, optional guard packs) and whether this pane's engine identity matches the validated plan
argument-hint: "[--config PATH] [--json] [--probe]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/harness-status.sh" $ARGUMENTS`

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. Report the result above.

`harness-status` is **read-only**. It validates the config, computes the normalized plan, and reports the harness block. The block is either `inactive` (schema v1, no `harness`, or `enabled: false`) or `active`. An `active` block shows its `mode` (`audit` | `enforce`), `profile` (`strict-v1`), semantic `roles`, and `gates`.

The `floor (strict-v1, not configurable):` lines follow. They show the immutable role floor that `harness-policy.py` enforces. The lines are generated from the policy's own tables:

- In a pane with an accepted identity, one line shows that pane's role. An `all roles ->` line follows it.
- Without an accepted identity, one line shows each role.
- `<name> (confined)` is an environment coordinator whose cwd is not the project root.
- A bracketed count, such as `[31 read commands]`, is the size of the policy table behind that clause.

The `optional guard packs:` line follows the floor. It shows the configured schema-v3–v5 `harness.guards` packs as canonical JSON, or `none (schema-v2-compatible behavior)`. The packs add to the floor. They are not the complete list of what is enforced. "No packs" never means that reviewer read-only or executor containment is off.

The `identity:` line reads this pane's engine-owned environment. The variables are `SESSION_WORKSPACE_CONFIG`, `_PROJECT_ROOT`, `_PANE_NAME`, `_ROLE`, `_PANE_CWD`, and `_HARNESS_MODE`. A guarded schema-v3–v5 launch adds `_GUARDS_JSON`, which must equal the validated `harness.guards` exactly. The line shows one of these values:

- `not present` — `workspace-start` did not launch this process. The PreToolUse hook is a no-op here.
- `MATCH` — identity agrees with the validated plan. An active harness enforces the strict-v1 floor for the shown role.
- `PARTIAL` — only some identity variables are set. An active policy fails closed on this.
- `MISMATCH` — identity disagrees with the config. Causes: drift, a renamed pane, a config edited after launch (including any change to `harness.guards`), or a `SESSION_CHAT_PANE_NAME` / `KNOWLEDGE_PANE_NAME` alias that disagrees.

An **active** harness fails closed on `MISMATCH`. Every Edit/Write/Bash call is blocked until the user restarts the configured session that contains this pane. The remedy is `/session-workspace:workspace-restart <session-id>`. It kills and recreates all of that session's configured panes, not just this one. Relay that remedy verbatim.

The `policy:` line is `harness-policy.py`'s own verdict for this process: `no-op`, `active ... identity accepted`, or `BLOCKING [rule] reason`. It is the policy engine's decision for this environment. It assumes the provider has loaded and trusted the bundled hook. A pane cannot verify that.

`--probe` adds a `probe` section. The policy decides each built-in floor case for this pane's own role, through the same code path as the hook. It runs no command and writes no file. Each line shows the decision (`deny`, `allow`, or `audit`, which means "would deny in enforce mode"), the rule, and the case. A line that starts with `UNEXPECTED` is a case that the policy did not decide as the floor states. The script then exits 1. Report every `UNEXPECTED` line verbatim. Without an accepted identity, the probe is not run.

`--json` emits the same object machine-readably. `floor` holds the role floor, `guards` holds only the optional packs, and `probe` is `null` without `--probe`.

To judge one command for a role without a live pane, use the policy's read-only test mode: `python3 <plugin>/scripts/harness-policy.py --decision-json --as-role reviewer|executor --as-cwd DIR < payload.json`. It decides the stdin hook payload as that role working in `DIR` (a checkout) under enforce, with no read grants, message stores or workspace identity, and prints the same decision object as `--decision-json`. It reads no `SESSION_WORKSPACE_*` variable and never changes a live decision. The hook cannot reach it: `harness-hook.sh` refuses every argument except `--codex-hook-output` (`runtime.args`). `harness-status.sh --help` prints the exact line.

Never suggest editing the identity variables by hand. They are an authorization boundary. Only the engine sets them, at launch.
