---
description: Diagnostic check for scheduler dirs, session-chat, jq, tmux, and incoming-mode
allowed-tools: Bash(bash:*)
---

## Diagnostic

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/scheduler-doctor.sh`

## Instructions

Relay the diagnostic output as-is. Highlight any `WARN` or `MISSING` lines and suggest the matching fix (install jq, install session-chat, run `/session-chat:incoming-mode auto`).
