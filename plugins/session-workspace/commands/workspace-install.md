---
description: Install the machine-wide `workspace` dispatcher onto PATH (idempotent; also the refresh)
argument-hint: "[--target PATH] [--dry-run]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/workspace-install.sh" $ARGUMENTS`

## Instructions

Do not narrate or add a preamble. Report the result above.

`install` copies this plugin's `templates/workspace-dispatcher.sh` to
`~/.local/bin/workspace` (override with `--target`). That dispatcher is what
finds the plugin at run time, so it has to live on PATH rather than inside a
versioned cache — which makes it a copy that can go stale. This verb is the
sanctioned way to create AND to refresh it.

It is **idempotent**: an identical target reports `already current` and writes
nothing, so an external upgrade flow may call it unconditionally after every
plugin update and the copy can never drift from the installed release.

It takes no config and touches no tmux — it works on a fresh machine with no
`.agent-workspace/` anywhere. An identical **executable** target is left
untouched (no backup, no write); an identical but **non-executable** target
is chmod-repaired in place (no backup, no rewrite); **differing** existing
content is backed up to `<target>.bak` and replaced. After copying it verifies the installed file answers
`--contract`, reports whether the target directory is on PATH, and prints the
optional `alias ws=workspace` line. It **never** edits a shell rc file; relay
the alias line verbatim so the user can add it themselves.

`--dry-run` reports what would happen and writes nothing.

Relay the per-step lines and any `[warn]`. A `[warn]` about contract resolution
means no provider has the plugin installed yet; a `[warn]` about PATH means the
target directory needs adding to PATH before the command is runnable.
