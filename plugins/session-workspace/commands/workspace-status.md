---
description: Show current session-workspace lifecycle state
argument-hint: "[TARGET|all] [--config PATH] [--json]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/workspace.sh" status $ARGUMENTS`

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. Report the result above.

`status` is **read-only**. It never mutates tmux or any state file. For every planned pane it reports:

- session existence and managed state
- role, runtime, and configured model
- resolved cwd
- the tmux process actually running there
- a health verdict

It locates a slot ONLY by its pane marker: a pane in the session whose `@session_workspace_pane` marker equals the planned pane name.

| Verdict | Meaning |
|---|---|
| `healthy` | Marker found, full project/pane ownership check passes, process alive. |
| `dead` | Marked and owned, but the process died. |
| `unmanaged-occupant` | A pane carries the planned name's marker but fails the full project/pane ownership check. Example: another project's or an orphaned session's leftover marker. |
| `missing` | No pane carries the planned marker. An ordinary unmarked pane in the planned positional slot also reports `missing`. |

Positional gap and adoption-candidate analysis belongs to `start`/`reconcile`, not to `status`.

`TARGET` restricts the report to one `sessions[].id`. An unknown target fails fast with a clear error. It does not silently return an empty report. `--json` emits the machine-readable rows.

Schema v5 accepts `--environment ID` with optional `--services` or `--development`.
Group selection cannot be combined with a positional session or `--all`; it never
attaches automatically. See the session-workspace environment reference.
