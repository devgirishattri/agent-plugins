---
name: workspace-status
description: "Show current session-workspace lifecycle state. Use when the user asks whether the workspace is running or what its current pane/session state is."
---

# workspace-status

When this skill is invoked, do not add a preamble or narrate the plan. Run
the relevant script directly, then return only the formatted result.

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

Status is read-only. It validates config and reads tmux state, but does not
create sessions, write state files, repair panes, or kill anything. For each
planned pane it reports session existence/managed status, pane id, role,
runtime, configured model, cwd, foreground process, and health (`missing`,
`dead`, `healthy`, or `unmanaged-occupant`). The current script filters
unmatched targets to an empty result rather than erroring; use
`workspace-plan TARGET` first when strict target validation matters.
