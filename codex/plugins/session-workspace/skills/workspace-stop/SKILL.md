---
name: workspace-stop
description: "Tear down session-workspace sessions/panes. Destructive; requires --confirmed. Use when the user asks to stop, tear down, or kill the configured workspace."
---

# workspace-stop

When this skill is invoked, run the script below and report its result,
leading with the outcome.

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
- `SESSION --pane NAME --confirmed` (repeatable `--pane`): stop only the named
  service panes, or on-demand executor/reviewer workers, of one session; the
  session and its other panes keep running. Cannot be combined with `--all` or
  `--no-save`. Prints `stopped: N  not running: N  skipped: N  busy: N`.
- `--force` (with `--pane` only): stop an on-demand worker even while it is
  busy. Use it only when the user asks.

An on-demand worker is stopped only when it is idle. A worker with a task
still `assigned` to it, a task it reviews in `review`, unread session-chat
messages, or a running turn on screen is reported `[busy] ... left running:
<reasons>`, and the command exits 1. Relay the reasons.

Stop is destructive. It validates config, takes the project lock, and targets
tmux sessions by exact name. It kills only sessions carrying this project's
managed marker; same-name unmanaged sessions are skipped. When saving is
enabled, it preserves retained layouts and invokes tmux-resurrect if present.

For schema-v5 `--environment ID` selection, invoke the installed dispatcher as
`bash <PLUGIN_ROOT>/scripts/workspace.sh stop --environment ID [flags]`
instead of the direct session script. Optional `--services` or `--development`
limits the group; no positional session or `--all` may accompany it. Read
`../session-workspace/references/environments.md` for scope and partial-failure
behavior. Existing stop confirmation requirements still apply.
