---
name: workspace-plan
description: "Dry-run plan for session-workspace session/pane lifecycle. Use when the user wants to preview what workspace start would do without mutating anything."
---

# workspace-plan

When this skill is invoked, do not add a preamble or narrate the plan. Run
the relevant script directly, then return only the formatted result.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it
is the directory two levels above this `SKILL.md`. Use that absolute path;
never infer it from cwd or hardcode a marketplace cache version.

Run:

```bash
bash "$PLUGIN_ROOT/scripts/workspace-plan.sh" $ARGUMENTS
```

Real flags:
- `TARGET|all`: optional `sessions[].id` filter; default is `all`.
- `--config PATH`: use a specific workspace config instead of discovery.
- `--json`: emit the resolved plan as JSON.

This command is mutation-free. It validates config, resolves pane cwd paths,
and prints the normalized plan without touching tmux or any state directory.
Unknown targets fail with the known session ids. The human report shows env
variable names only and never prints env values or secret values.
