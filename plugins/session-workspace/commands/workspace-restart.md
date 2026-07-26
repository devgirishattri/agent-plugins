---
description: Stop then start session-workspace sessions/panes (destructive — kills and recreates panes)
argument-hint: "[TARGET|all] [--config PATH] [--no-save] [--no-agents] [--no-services] [--no-attach]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/workspace.sh" restart $ARGUMENTS`

## Instructions

Do not narrate or add a preamble. Report the result above.

`restart` is `stop` (confirmation implicit — this command does not take
`--confirmed` itself) immediately followed by `start`, for the same target.
Only sessions carrying THIS project's managed marker are ever killed; a
same-named session this engine does not own is left untouched. By default
the window layout is saved before stopping and restored after starting
(`retain_layout`); pass `--no-save` to skip that. Make sure the user
actually wants a live pane killed and recreated before running this.
