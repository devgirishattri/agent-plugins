---
name: whoami
description: "Show or set this Codex session's tmux pane name for session-chat messaging. Use when the user asks whoami, set my pane name, rename this pane, or wants other sessions to message this pane."
---

# Whoami

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from cwd or hardcode a marketplace cache version.

Show the current pane name:

```bash
bash "$PLUGIN_ROOT/scripts/get-my-name.sh"
```

If the user provided a new name, validate that it only contains letters, numbers, hyphens, and underscores, then run:

```bash
bash -lc 'source "$0/scripts/lib.sh" && set_pane_name "$TMUX_PANE" "$1"' "$PLUGIN_ROOT" "<name>"
```

If this is not running inside tmux, explain that pane naming requires tmux and suggest starting one with `tmux new -s <name>`.
If a current name is shown and no new name was provided, report that name and explain that other sessions can message it. If no name is set and no new name was provided, suggest `$session-chat:whoami <name>`.
