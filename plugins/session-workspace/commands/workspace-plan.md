---
description: Dry-run plan for session-workspace session/pane lifecycle (mutates nothing)
argument-hint: "[TARGET|all] [--config PATH] [--json]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/workspace-plan.sh" $ARGUMENTS`

## Instructions

Do not narrate or add a preamble. Report the result above.

`plan` resolves the project config (loading, token-interpolating, and
validating `.agent-workspace/workspace.json`) and shows exactly what
`workspace-start`/`workspace-reconcile` would do — sessions, panes, roles,
runtimes, resolved cwds, agent flags, grants, and env var names (never
values or secrets) — without touching tmux or writing any state. `TARGET`
restricts the plan to one `sessions[].id`; an unknown target fails fast with
the list of known ids. `--json` emits the machine-readable plan consumed by
the other verbs.

An optional pane whose declared `cwd` does not resolve on disk (an
un-cloned child repo) is shown marked `[SKIPPED: cwd unavailable — will not
be launched]` — that is expected, not a config error, and mirrors what the
lifecycle verbs will actually do with it.
