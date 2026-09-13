---
description: Diagnostic check for scheduler dirs (tasks, prompts, handoffs, locks), session-chat, context home, jq, tmux, incoming-mode, and date math
allowed-tools: Bash(bash:*)
---

## Diagnostic

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/scheduler-doctor.sh"`

## Instructions

`SESSION_SCHEDULER_HOME` must already be present in this session's environment, inherited when the agent process started. If the output above reports it is not set, stop and request that this pane/session be relaunched with the correct environment — do not export the variable or derive another ledger.

Relay the diagnostic output as-is. Highlight any `WARN` or `MISSING` lines and suggest the matching fix (install jq, install session-chat, run `/session-chat:incoming-mode auto`). The `context home` block only *reports* `SESSION_CONTEXT_HOME` (needed by `--context NAME` alone); it never creates it. A WARN there listing legacy `auto_handoff_*.md` files means a pre-0.6.0 scheduler wrote handoffs into the live knowledge store — they are not swept by `/tasks-clean`; remove each with `/knowledge:context-remove <name>` once nobody needs it. The `ledger home` line says whether the inherited home sits inside this pane's project root (a home elsewhere is expected for a shared workspace ledger). The `date math` line verifies the ISO/epoch arithmetic used by `--eta`, OVERDUE/STALE flags, and duration tracking — a WARN there means those features will silently no-op on this platform.
