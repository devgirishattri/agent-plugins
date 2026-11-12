---
description: Tear down session-workspace sessions/panes (destructive; requires --confirmed)
argument-hint: "[TARGET|all] [--config PATH] [--no-save] --confirmed [--all] | SESSION --pane NAME [--pane NAME...] --confirmed [--force]"
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

`SESSION --pane NAME --confirmed` (repeatable `--pane`) stops only the named service panes, or on-demand executor/reviewer workers, of one session and leaves the session and every other pane running. It sends `C-c`, waits the grace period, closes the pane, and records the stop in the pane's run record. A pane that is not running is reported `[absent]`. `--pane` cannot be combined with `--all` or `--no-save`. Relay its `stopped: N  not running: N  skipped: N  busy: N` summary verbatim.

An on-demand worker is stopped only when it is idle. A worker with a task still `assigned` to it, a task it reviews in `review`, unread session-chat messages, or a running turn on screen is reported `[busy] ... left running: <reasons>`, and the command exits 1. Relay the reasons. `--force` stops a busy worker anyway; use it only when the user asks.

Relay the `killed: N` summary verbatim. Never run this without the user having asked for it.

Schema v5 accepts `--environment ID` with optional `--services` or `--development`.
Group selection cannot be combined with a positional session or `--all`; it never
attaches automatically. See the session-workspace environment reference.
