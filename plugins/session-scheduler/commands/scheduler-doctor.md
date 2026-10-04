---
description: Diagnostic check for scheduler dirs (tasks, prompts, handoffs, locks), session-chat, context home, jq, tmux, incoming-mode, and date math
allowed-tools: Bash(bash:*)
---

## Diagnostic

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/scheduler-doctor.sh"`

## Instructions

`SESSION_SCHEDULER_HOME` must already be present in this session's environment. It is inherited when the agent process started. If the output above reports that it is not set, stop. Ask the user to relaunch this pane/session with the correct environment. Do not export the variable or derive another ledger.

Relay the diagnostic output as-is. Highlight any `WARN` or `MISSING` lines. For each one, suggest the matching fix: install jq, install session-chat, or run `/session-chat:incoming-mode auto`.

The diagnostic has these blocks and lines:

- The `context home` block only *reports* `SESSION_CONTEXT_HOME`. Only `--context NAME` needs it. The block never creates it. A WARN there that lists legacy `auto_handoff_*.md` files means a pre-0.6.0 scheduler wrote handoffs into the live knowledge store. `/tasks-clean` does not sweep them. Remove each with `/knowledge:context-remove <name>` once nobody needs it.
- The `ledger home` line says whether the inherited home is inside this pane's project root. A home elsewhere is expected for a shared workspace ledger.
- The `date math` line verifies the ISO/epoch arithmetic that `--eta`, OVERDUE/STALE flags, and duration tracking use. A WARN there means those features silently do nothing on this platform.
- The `contracts` block reports verification-contract tasks. It shows how many exist and how many are done without admission (`closed-unadmitted`, e.g. closed by a pre-0.7.0 helper). It WARNs when python3 or task-contract.sh is missing.
