---
description: Dry-run plan for session-workspace session/pane lifecycle (mutates nothing)
argument-hint: "[TARGET|all] [--config PATH] [--json]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/workspace.sh" plan $ARGUMENTS`

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. Report the result above.

`plan` resolves the project config. It loads, token-interpolates, and validates `.agent-workspace/workspace.json`. It then shows exactly what `workspace-start`/`workspace-reconcile` would do. The plan lists sessions, panes, roles, runtimes, resolved cwds, agent flags, grants, and env var names (never values or secrets). It touches no tmux and writes no state.

- `TARGET` restricts the plan to one `sessions[].id`. An unknown target fails fast with the list of known ids.
- `--json` emits the machine-readable plan that the other verbs consume.

The plan marks an optional pane whose declared `cwd` does not resolve on disk (an un-cloned child repo) as `[SKIPPED: cwd unavailable — will not be launched]`. This is expected, not a config error. It mirrors what the lifecycle verbs will actually do with the pane.

Schema v5 accepts `--environment ID` with optional `--services` or `--development`.
Group selection cannot be combined with a positional session or `--all`; it never
attaches automatically. See the session-workspace environment reference.
