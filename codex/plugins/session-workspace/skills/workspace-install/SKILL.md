---
name: workspace-install
description: "Install the machine-wide `workspace` dispatcher onto PATH. Use when the user asks to set up the workspace command on a new machine, install or refresh the workspace dispatcher, or make `ws`/`workspace` available outside a project."
---

# workspace-install

When this skill is invoked, do not add a preamble or narrate the plan. Run
the relevant script directly, then return only the formatted result.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it
is the directory two levels above this `SKILL.md`. Use that absolute path;
never infer it from cwd and never hardcode a cache version.

Run:

```bash
ARGUMENTS="${ARGUMENTS:-}"
bash "$PLUGIN_ROOT/scripts/workspace-install.sh" $ARGUMENTS
```

Interface:

- `--target PATH` — install location (default `~/.local/bin/workspace`).
- `--dry-run` — report what would happen; write nothing.

What it does, and why it exists: the dispatcher must live on PATH rather than
inside a versioned plugin cache, because it is the thing that FINDS the plugin.
That makes it a copy, and a copy goes stale silently. This verb creates it and
is also its refresh — it is idempotent, so an identical target reports
`already current` and writes nothing, letting `upgrade.sh` call it after every
plugin update so the copy cannot drift from the installed release.

It requires no config and touches no tmux, so it works on a fresh machine with
no `.agent-workspace/` anywhere. An existing target is backed up to
`<target>.bak` before being overwritten. After copying it verifies the installed
file answers `--contract`, reports whether the target directory is on PATH, and
prints an optional `alias ws=workspace` line.

It NEVER edits a shell rc file. Relay the alias line verbatim so the user adds
it themselves; do not offer to write it for them.

Relay the per-step lines and any `[warn]`. A contract `[warn]` means no provider
has the plugin installed yet. A PATH `[warn]` means the target directory must be
added to PATH before the command is runnable.
