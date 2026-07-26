---
name: workspace-restart
description: "Stop then start session-workspace sessions/panes. Destructive. Use when the user asks to restart or recycle the configured workspace."
---

# workspace-restart

When this skill is invoked, do not add a preamble or narrate the plan. Run
the relevant script directly, then return only the formatted result.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it
is the directory two levels above this `SKILL.md`. Use that absolute path;
never infer it from cwd or hardcode a marketplace cache version.

Run:

```bash
bash "$PLUGIN_ROOT/scripts/workspace.sh" restart $ARGUMENTS
```

Real flags:
- `TARGET|all`: optional `sessions[].id` filter; default is `all`.
- `--config PATH`: use a specific workspace config instead of discovery.
- `--no-save`: skip layout/resurrect save during stop.
- `--no-agents`, `--no-services`, `--no-attach`: pass through to start.

Restart is destructive because it stops the selected managed session(s) before
starting them again. The script passes `--confirmed` internally to
`workspace-stop.sh` after restart is invoked; `--confirmed` is not a
user-facing restart flag. If stop fails, start is not run.
