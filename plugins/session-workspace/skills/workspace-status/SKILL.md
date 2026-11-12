---
name: workspace-status
description: "Show current session-workspace lifecycle state. Use when the user asks whether the workspace is running or what its current pane/session state is."
---

# workspace-status

When this skill is invoked, run the script below and report its result,
leading with the outcome.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it
is the directory two levels above this `SKILL.md`. Use that absolute path;
never infer it from cwd or hardcode a marketplace cache version.

Run:

```bash
bash "$PLUGIN_ROOT/scripts/workspace-status.sh" $ARGUMENTS
```

Real flags:
- `TARGET|all`: optional session id filter; default is `all`.
- `--config PATH`: use a specific workspace config instead of discovery.
- `--json`: emit status rows as JSON.
- `SESSION --pane NAME`: restrict the report to the named service panes or
  on-demand workers.

Status is read-only. It validates config and reads tmux state, but does not
create sessions, write state files, repair panes, or kill anything. For each
planned pane it reports session existence/managed status, pane id, role,
runtime, configured model, cwd, foreground process, and health (`missing`,
`dead`, `healthy`, or `unmanaged-occupant`). An unknown target fails with
an error that lists the known session ids.

Each pane also reports `running=yes|no`, and a pane with `idle_stop_minutes`
shows its watcher and its last stop with the reason. A session with a browser
pane gets one CDP endpoint health line, such as `browser: browser
http://127.0.0.1:9326 — up (Chrome/131.0)  cdp_clients=1`. Check it says `up`
before a browser smoke; when it says `down`, start the pane with
`workspace start SESSION --pane browser`.

An executor/reviewer marked `"launch": "on_demand"` adds a `launch: on demand`
line. While it is down, that line names the `workspace start SESSION --pane
NAME` command that starts it. A down on-demand worker is expected, not a
fault.

For schema-v5 `--environment ID` selection, invoke the installed dispatcher as
`bash <PLUGIN_ROOT>/scripts/workspace.sh status --environment ID [flags]`
instead of the direct session script. Optional `--services` or `--development`
limits the group; no positional session or `--all` may accompany it. Read
`../session-workspace/references/environments.md` for scope and partial-failure
behavior.
