---
description: Reconcile drifted tmux state against config; only sanctioned path for adopting unmanaged panes
argument-hint: "[TARGET|all] [--apply] [--adopt --confirmed]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/workspace-reconcile.sh" $ARGUMENTS`

## Instructions

Do not narrate or add a preamble. Report the result above.

`reconcile` is **dry-run by default** — it reports what would change
(`[would-create]`, `[would-start]`, `[would-keep]`, `[would-adopt]`,
`[would-fail]`, `[skipped]`) and mutates nothing. Pass `--apply` to actually
perform the repair. Either way it only creates/repairs MISSING managed
resources — a pane that is already healthy and managed is left completely
alone (never respawned).

An unmanaged pane occupying a planned slot is never renamed or claimed
implicitly. `--adopt --confirmed` is the only path to claiming it, and the
adoption-candidate details (current command, existing markers) are printed
**every time** a slot needs adoption — including in dry-run, without
`--apply` — so review the plan before re-running with `--apply --adopt
--confirmed` to actually claim it.

The same applies one level up, to a tmux **session** whose name matches the
config but which carries no managed marker (every session predating the plugin
is in this state). Without `--adopt --confirmed`, `start`/`reconcile` refuse to
touch it. With it, the session adoption plan — name, window, existing pane
count, and any panes already carrying markers — is printed first, and only
`--apply` labels the session managed and proceeds to its panes (which keep
their own per-pane adoption rules). A dry run adopts nothing.

Relay the per-pane report lines and the summary count verbatim.
