---
description: Diagnostic check for scheduler dirs, session-chat, jq, tmux, incoming-mode, and date math
allowed-tools: Bash(bash:*)
---

## Diagnostic

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/scheduler-doctor.sh"`

## Instructions

`SESSION_SCHEDULER_HOME` must already be present in this session's environment, inherited when the agent process started. If the output above reports it is not set, stop and request that this pane/session be relaunched with the correct environment — do not export the variable or derive another ledger.

Relay the diagnostic output as-is. Highlight any `WARN` or `MISSING` lines and suggest the matching fix (install jq, install session-chat, run `/session-chat:incoming-mode auto`). The `date math` line verifies the ISO/epoch arithmetic used by `--eta`, OVERDUE/STALE flags, and duration tracking — a WARN there means those features will silently no-op on this platform.
