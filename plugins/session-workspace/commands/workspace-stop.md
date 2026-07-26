---
description: Tear down session-workspace sessions/panes (destructive; requires --confirmed)
argument-hint: "[TARGET|all] [--config PATH] [--no-save] --confirmed [--all]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/workspace-stop.sh" $ARGUMENTS`

## Instructions

Do not narrate or add a preamble. Report the result above.

`stop` refuses to run at all without `--confirmed` — this kills live tmux
sessions. It kills ONLY tmux sessions carrying THIS project's managed
session marker; a session with the same configured name that this engine
did not create is left completely untouched (exact `=NAME` targeting, never
a prefix match). By default the scope is `behavior.stop_scope` (usually just
the selected TARGET session); pass `--all` to widen to every managed session
for this project regardless of config. The window layout is saved before
killing unless `--no-save` is passed or `behavior.save_before_stop` is
false.

Relay the `killed: N` summary verbatim, and never run this without the user
having asked for it.
