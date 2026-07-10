---
name: panes
description: "List named tmux panes in the current tmux session, or all sessions when the user asks for all panes. Use when the user asks to list panes, show available sessions, find targets, or use panes."
---

# Panes

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from cwd or hardcode a marketplace cache version.

Run:

```bash
ARGUMENTS="${ARGUMENTS:-}"
bash "$PLUGIN_ROOT/scripts/list-panes.sh" "$ARGUMENTS"
```

By default, list named panes in the current tmux session only. If the user passes `all` or explicitly asks for all tmux sessions, pass `all` to the script.

Present tab-separated output as:

```text
| Name | Pane | Command | Location |
```

If the command says tmux is required or not active, explain that this action must run inside tmux. If no panes are listed, say no named panes were found and suggest `$session-chat:whoami <name>`. If panes are listed, mention that `$session-chat:send <name> <message>` can message a pane. Mention `$session-chat:panes all` only when the user needs panes from every tmux session.
