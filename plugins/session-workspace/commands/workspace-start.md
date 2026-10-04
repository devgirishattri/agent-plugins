---
description: Bring up session-workspace sessions/panes/agents/services
argument-hint: "[TARGET|all] [--config PATH] [--no-agents] [--no-services] [--no-attach] [--adopt --confirmed]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/workspace.sh" start $ARGUMENTS`

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. Report the result above.

`start` creates only MISSING managed topology for the resolved plan (sessions, windows, panes, runtime argv/env). A second run against an already-healthy workspace is a no-op. It reports every already-managed, alive pane as `[kept]` and never respawns it. It reports an optional pane whose `cwd` did not resolve (un-cloned child repo) as `[skipped]` and never launches it.

An unmanaged pane that occupies a planned slot always FAILS. A same-named tmux session that carries no managed marker also always FAILS. The engine never silently renames, respawns, or claims either one without explicit adoption. Adopt directly with `workspace-start --adopt --confirmed`. The recommended preview-first route has two steps:

1. Run `/session-workspace:workspace-reconcile --adopt --confirmed`. It prints the adoption plan and mutates nothing.
2. Run `--apply --adopt --confirmed`.

`--no-agents`/`--no-services` skip launching the corresponding pane's runtime. The pane is still created and marked. The command reports such a pane as `[claimed]`, not healthy. A later `start` without the flag launches its runtime.

`--no-attach` suppresses the post-start attach. Otherwise `start` attaches per `behavior.attach` and prints one `attach: ...` line that says what it did. With no positional `TARGET`, the target is `behavior.default_start_target` (default `all`).

Relay the per-pane report lines and the summary count (`started/adopted: N  kept (already healthy): N  failed: N`) verbatim.

| Exit | Meaning | Your report |
|---|---|---|
| 0 | No slot failed. | Report the result above. |
| Non-zero | At least one slot failed. | Do not claim the workspace is fully up. Name the failed slots. |

Schema v5 accepts `--environment ID` with optional `--services` or `--development`.
Group selection cannot be combined with a positional session or `--all`; it never
attaches automatically. See the session-workspace environment reference.
