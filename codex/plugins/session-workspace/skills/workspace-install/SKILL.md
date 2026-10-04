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

The dispatcher lives on PATH and locates the installed plugin.
Install it outside any versioned plugin cache. A stale dispatcher copy can fail silently.
This command installs or refreshes that copy.
If the target is identical, it reports `already current` and writes nothing.
`upgrade.sh` calls it after each plugin update to keep the copy current.

It requires no config and does not touch tmux.
It works on a fresh machine without `.agent-workspace/`.
Before overwriting an existing target, it backs up the file to `<target>.bak`.
After copying, it verifies that the installed file answers `--contract`.
It reports whether the target directory is on PATH and prints an optional
`alias ws=workspace` line.

It NEVER edits a shell rc file. Relay the alias line verbatim so the user adds
it themselves; do not offer to write it for them.

Relay the per-step lines and any `[warn]`. A contract `[warn]` means no provider
has the plugin installed yet. A PATH `[warn]` means the target directory must be
added to PATH before the command is runnable.
