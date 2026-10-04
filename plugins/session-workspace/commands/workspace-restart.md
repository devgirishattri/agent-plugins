---
description: Stop then start session-workspace sessions/panes (destructive — kills and recreates panes)
argument-hint: "[TARGET|all] [--config PATH] [--no-save] [--no-agents] [--no-services] [--no-attach]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/workspace.sh" restart $ARGUMENTS`

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. Report the result above.

`restart` is `stop` immediately followed by `start`, for the same target. The stop confirmation is implicit. This command does not take `--confirmed` itself.

Before you run this, confirm that the user wants a live pane killed and recreated.

- The command kills only sessions that carry THIS project's managed marker. It leaves a same-named session that this engine does not own untouched.
- The layout/resurrect save before stopping happens only when `behavior.save_before_stop` is `true`. It defaults to `false`.
- The window layout is saved and restored only for a session with `retain_layout: true`.
- `--no-save` overrides both and skips the save.

Schema v5 accepts `--environment ID` with optional `--services` or `--development`.
Group selection cannot be combined with a positional session or `--all`; it never
attaches automatically. See the session-workspace environment reference.
