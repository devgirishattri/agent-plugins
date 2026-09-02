---
description: Bring up session-workspace sessions/panes/agents/services
argument-hint: "[TARGET|all] [--config PATH] [--no-agents] [--no-services] [--no-attach] [--adopt --confirmed]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/workspace-start.sh" $ARGUMENTS`

## Instructions

Do not narrate or add a preamble. Report the result above.

`start` creates only MISSING managed topology for the resolved plan
(sessions, windows, panes, runtime argv/env). A second run against an
already-healthy workspace is a no-op — every already-managed, alive pane is
reported `[kept]`, never respawned. An optional pane whose `cwd` did not
resolve (un-cloned child repo) is reported `[skipped]` and never launched.

An unmanaged pane occupying a planned slot — or a same-named tmux session
carrying no managed marker — always FAILS rather than being silently
renamed/respawned/claimed without explicit adoption. Adopting is supported
directly with `workspace-start --adopt --confirmed`; the recommended
preview-first route is `/session-workspace:workspace-reconcile --adopt --confirmed` (which
prints the adoption plan and mutates nothing) followed by
`--apply --adopt --confirmed`.

`--no-agents`/`--no-services` skip launching the corresponding pane's runtime
while still creating/marking the pane; such a pane is reported `[claimed]`,
not healthy, and a later `start` without the flag launches its runtime.
`--no-attach` suppresses the post-start attach; otherwise `start` attaches per
`behavior.attach` and prints one `attach: ...` line saying what it did. With no
positional `TARGET`, the target is `behavior.default_start_target`
(default `all`).

Relay the per-pane report lines and the summary count
(`started/adopted: N  kept (already healthy): N  failed: N`) verbatim. A non-zero exit means
at least one slot failed — do not claim the workspace is fully up.
