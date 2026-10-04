---
description: Tear down session-workspace sessions/panes (destructive; requires --confirmed)
argument-hint: "[TARGET|all] [--config PATH] [--no-save] --confirmed [--all]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/workspace.sh" stop $ARGUMENTS`

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. Report the result above.

`stop` refuses to run at all without `--confirmed`, because it kills live tmux sessions.

- It kills ONLY tmux sessions that carry THIS project's managed session marker.
- It leaves a session untouched when this engine did not create it, even if the configured name is the same. It uses exact `=NAME` targeting, never a prefix match.
- By default the scope is `behavior.stop_scope` (usually just the selected TARGET session). Pass `--all` to widen the scope to every managed session for this project, regardless of config.
- The window layout is saved before killing only when ALL three hold: the session has `retain_layout: true`, `behavior.save_before_stop` is `true`, and `--no-save` was not passed.

Relay the `killed: N` summary verbatim. Never run this without the user having asked for it.

Schema v5 accepts `--environment ID` with optional `--services` or `--development`.
Group selection cannot be combined with a positional session or `--all`; it never
attaches automatically. See the session-workspace environment reference.
