---
description: Diagnostic check for scheduler dirs, session-chat, jq, tmux, incoming-mode, and date math
allowed-tools: Bash(bash:*)
---

## Diagnostic

!`export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"; bash ${CLAUDE_PLUGIN_ROOT}/scripts/scheduler-doctor.sh`

## Instructions

Relay the diagnostic output as-is. Highlight any `WARN` or `MISSING` lines and suggest the matching fix (install jq, install session-chat, run `/session-chat:incoming-mode auto`). The `date math` line verifies the ISO/epoch arithmetic used by `--eta`, OVERDUE/STALE flags, and duration tracking — a WARN there means those features will silently no-op on this platform.
