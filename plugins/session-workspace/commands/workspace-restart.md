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
same-named session this engine does not own is left untouched. The
layout/resurrect save before stopping happens only when
`behavior.save_before_stop` is `true` (it defaults to `false`), and the
window layout is saved/restored only for a session with
`retain_layout: true`; `--no-save` overrides and skips the save either way. Make sure the user
actually wants a live pane killed and recreated before running this.
