---
description: Reconcile drifted tmux state against config; recommended preview-first path for adopting unmanaged panes
argument-hint: "[TARGET|all] [--config PATH] [--apply] [--adopt --confirmed]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/workspace-reconcile.sh" $ARGUMENTS`

## Instructions

Do not narrate or add a preamble. Report the result above.

`reconcile` is **dry-run by default** — it reports what would change
(`[would-create]`, `[would-start]`, `[would-relaunch]`, `[would-keep]`,
`[would-adopt]`, `[would-fail]`, `[skipped]`) and mutates nothing. A dry
run ends with `(dry run — nothing was changed; re-run with --apply to
perform these repairs)` and prints no numeric summary. Pass `--apply` to
actually perform the repair; only `--apply` emits the summary
`repaired/adopted: N  kept (already healthy): N  failed: N`. Either way it only creates/repairs MISSING managed
resources — a pane that is already healthy and managed is left completely
alone (never respawned).

An unmanaged pane occupying a planned slot is never renamed or claimed
implicitly. Claiming it always requires `--adopt --confirmed`; this verb is
the **recommended preview-first path** because the adoption-candidate details
(current command, existing markers) are printed **every time** a slot needs
adoption — including in dry-run, without `--apply` — so review the plan
before re-running with `--apply --adopt --confirmed` to actually claim it.
(`workspace-start --adopt --confirmed` is the direct lifecycle alternative
when you don't need the preview.)

The same applies one level up, to a tmux **session** whose name matches the
config but which carries no managed marker (every session predating the plugin
is in this state). Without `--adopt --confirmed`, `start`/`reconcile` refuse to
touch it. With it, the session adoption plan — name, window, existing pane
count, and any panes already carrying markers — is printed first, and only
`--apply` labels the session managed and proceeds to its panes (which keep
their own per-pane adoption rules). A dry run adopts nothing.

Relay the per-pane report lines verbatim, plus the dry-run closing line or
the `--apply` summary count as applicable.
