---
description: Reconcile drifted tmux state against config; recommended preview-first path for adopting unmanaged panes
argument-hint: "[TARGET|all] [--config PATH] [--apply] [--adopt --confirmed]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/workspace.sh" reconcile $ARGUMENTS`

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. Report the result above.

`reconcile` is **dry-run by default**. It mutates nothing. It reports what would change with these markers: `[would-create]`, `[would-start]`, `[would-relaunch]`, `[would-keep]`, `[would-adopt]`, `[would-fail]`, `[skipped]`.

| Run | Closing output |
|---|---|
| Dry run | `(dry run — nothing was changed; re-run with --apply to perform these repairs)`. No numeric summary. |
| With `--apply` | The summary `repaired/adopted: N  kept (already healthy): N  failed: N`. |

`--apply` performs the repair. Either way, the command only creates or repairs MISSING managed resources. It leaves a healthy, managed pane completely alone (never respawned).

The command never renames or claims an unmanaged pane that occupies a planned slot implicitly. Claiming it always requires `--adopt --confirmed`. This verb is the **recommended preview-first path**. It prints the adoption-candidate details (current command, existing markers) **every time** a slot needs adoption, including in dry-run without `--apply`. Review the plan. Then re-run with `--apply --adopt --confirmed` to claim the pane. (`workspace-start --adopt --confirmed` is the direct lifecycle alternative when you do not need the preview.)

The same rule applies one level up. It covers a tmux **session** whose name matches the config but which carries no managed marker. Every session that predates the plugin is in this state.

- Without `--adopt --confirmed`, `start`/`reconcile` refuse to touch such a session.
- With `--adopt --confirmed`, the command first prints the session adoption plan: name, window, existing pane count, and any panes that already carry markers.
- Only `--apply` labels the session managed and proceeds to its panes. The panes keep their own per-pane adoption rules.
- A dry run adopts nothing.

Relay the per-pane report lines verbatim. Add the dry-run closing line or the `--apply` summary count, as applicable.

Schema v5 accepts `--environment ID` with optional `--services` or `--development`.
Group selection cannot be combined with a positional session or `--all`; it never
attaches automatically. See the session-workspace environment reference.
