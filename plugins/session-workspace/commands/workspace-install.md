---
description: Install the machine-wide `workspace` dispatcher onto PATH (idempotent; also the refresh)
argument-hint: "[--target PATH] [--dry-run]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/workspace-install.sh" $ARGUMENTS`

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. Report the result above.

`install` copies this plugin's `templates/workspace-dispatcher.sh` to
`~/.local/bin/workspace` (override with `--target`). The dispatcher finds the
plugin at run time. It must live on PATH, not inside a versioned cache. That
makes it a copy that can go stale. This verb is the sanctioned way to create
AND to refresh it.

It is **idempotent**. An identical target reports `already current` and writes
nothing. An external upgrade flow can therefore call it unconditionally after
every plugin update. The copy can never drift from the installed release.

It takes no config and touches no tmux. It works on a fresh machine with no
`.agent-workspace/` anywhere. It treats an existing target as follows:

| Existing target | Action |
|---|---|
| Identical and **executable** | Left untouched (no backup, no write). |
| Identical but **non-executable** | chmod-repaired in place (no backup, no rewrite). |
| **Differing** content | Backed up to `<target>.bak`, then replaced. |

After copying, the command verifies that the installed file answers
`--contract`. It reports whether the target directory is on PATH. It prints the
optional `alias ws=workspace` line. It **never** edits a shell rc file. Relay
the alias line verbatim so the user can add it themselves.

`--dry-run` reports what would happen and writes nothing.

Relay the per-step lines and any `[warn]`. Read the two `[warn]` kinds as follows:

- A `[warn]` about contract resolution means no provider has the plugin installed yet.
- A `[warn]` about PATH means the user must add the target directory to PATH before the command runs.
