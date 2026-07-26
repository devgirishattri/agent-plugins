---
name: workspace-reconcile
description: "Reconcile drifted tmux state against config; the only sanctioned path for adopting unmanaged panes. Use when the user asks to reconcile, repair, or adopt workspace panes."
---

# workspace-reconcile

When this skill is invoked, do not add a preamble or narrate the plan. Run
the relevant script directly, then return only the formatted result.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it
is the directory two levels above this `SKILL.md`. Use that absolute path;
never infer it from cwd or hardcode a marketplace cache version.

Run:

```bash
bash "$PLUGIN_ROOT/scripts/workspace-reconcile.sh" $ARGUMENTS
```

Real flags:
- `TARGET|all`: optional `sessions[].id` filter; default is `all`.
- `--config PATH`: use a specific workspace config instead of discovery.
- `--apply`: perform repairs. Without it, reconcile is a dry run.
- `--adopt --confirmed`: allow an occupied unmanaged pane to be claimed.

Safety gates: dry-run mode mutates nothing; applying takes the project lock;
unknown targets fail; adoption is refused unless both `--adopt` and
`--confirmed` are present. Applying repairs missing or unhealthy managed slots
without restarting healthy panes. When applying adoption, occupant details are
printed before the pane is claimed.
