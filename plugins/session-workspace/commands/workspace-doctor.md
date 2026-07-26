---
description: Dependency/config health check for the session-workspace engine
argument-hint: "[--config PATH] [--json]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/workspace-doctor.sh" $ARGUMENTS`

## Instructions

Do not narrate or add a preamble. Report the result above.

`workspace-doctor` is **strictly read-only** — it diagnoses and never repairs,
creates, or kills anything. Each check reports `OK`, `INFO`, `WARN`, or
`ERROR` with remediation text; the command exits non-zero only when at least
one check is `ERROR` (a `WARN` alone still exits 0).

Relay the per-check statuses and their remediation lines. Do not run the
suggested fixes yourself unless the user asks — several of them (`chmod`,
`.gitignore` edits, plugin reinstalls) are the user's call.
