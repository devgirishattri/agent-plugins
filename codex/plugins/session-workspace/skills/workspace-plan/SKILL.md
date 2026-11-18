---
name: workspace-plan
description: "Dry-run plan for session-workspace session/pane lifecycle. Use when the user wants to preview what workspace start would do without mutating anything."
---

# workspace-plan

When this skill is invoked, run the script below and report its result,
leading with the outcome.

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
- `--running`: add a read-only `running` field to each pane (true when the
  managed pane is alive and launched, `null` without tmux).

The plan reads the config, resolves pane working directories, and applies worker names from the project's `labels.json` when present. It writes no state.
Only `--running` reads tmux.
Unknown targets fail with the known session ids. The human report shows env
variable names only and never prints env values or secret values.

For schema-v5 `--environment ID` selection, invoke the installed dispatcher as
`bash <PLUGIN_ROOT>/scripts/workspace.sh plan --environment ID [flags]`
instead of the direct session script. Optional `--services` or `--development`
limits the group; no positional session or `--all` may accompany it. Read
`../session-workspace/references/environments.md` for scope and partial-failure
behavior.
