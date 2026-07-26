---
description: Show current session-workspace lifecycle state
argument-hint: "[TARGET|all] [--config PATH] [--json]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/workspace-status.sh" $ARGUMENTS`

## Instructions

Do not narrate or add a preamble. Report the result above.

`status` is **read-only** — it never mutates tmux or any state file. For
every planned pane it reports session existence/managed state, role,
runtime, configured model, resolved cwd, the tmux process actually running
there, and a health verdict: `healthy` (managed and alive), `dead` (managed
but the process died), `unmanaged-occupant` (something else is sitting in
that slot), or `missing` (no pane there at all). `TARGET` restricts the
report to one `sessions[].id`; an unknown target fails fast with a clear
error rather than silently returning an empty report. `--json` emits the
machine-readable rows.
