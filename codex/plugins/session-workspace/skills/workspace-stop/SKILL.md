---
name: workspace-stop
description: "Tear down session-workspace sessions/panes. Destructive; requires --confirmed. Use when the user asks to stop, tear down, or kill the configured workspace."
---

# workspace-stop

When this skill is invoked, do not add a preamble or narrate the plan. Run
the relevant script directly, then return only the formatted result.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it
is the directory two levels above this `SKILL.md`. Use that absolute path;
never infer it from cwd or hardcode a marketplace cache version.

Run:

```bash
bash "$PLUGIN_ROOT/scripts/workspace-stop.sh" $ARGUMENTS
```

Real flags:
- `TARGET|all`: optional `sessions[].id` filter; default is `all`.
- `--config PATH`: use a specific workspace config instead of discovery.
- `--no-save`: skip layout save and tmux-resurrect save.
- `--confirmed`: required; without it the command refuses to run.
- `--all`: widen from configured/selected sessions to every live session
  marked for the current project.

Stop is destructive. It validates config, takes the project lock, and targets
tmux sessions by exact name. It kills only sessions carrying this project's
managed marker; same-name unmanaged sessions are skipped. When saving is
enabled, it preserves retained layouts and invokes tmux-resurrect if present.
