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
there, and a health verdict. It locates a slot ONLY by its pane marker: a
pane in the session whose `@session_workspace_pane` marker equals the
planned pane name. Verdicts: `healthy` (marker found, full project/pane
ownership check passes, process alive), `dead` (marked and owned but the
process died), `unmanaged-occupant` (a pane carries the planned name's
marker but fails the full project/pane ownership check — e.g. another
project's or an orphaned session's leftover marker), or `missing` (no pane
carries the planned marker — which is also what an ordinary unmarked pane
sitting in the planned positional slot reports as). Positional gap and
adoption-candidate analysis belongs to `start`/`reconcile`, not to
`status`. `TARGET` restricts the
report to one `sessions[].id`; an unknown target fails fast with a clear
error rather than silently returning an empty report. `--json` emits the
machine-readable rows.
