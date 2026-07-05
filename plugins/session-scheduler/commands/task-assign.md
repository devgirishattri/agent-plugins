---
description: Assign a task to an executor pane and dispatch via session-chat
argument-hint: <pane> <id> [--eta MINUTES] [--stage NAME] [--context NAME] [--force] <prompt>
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate. Parse `$ARGUMENTS` as: first word = pane, second = task id, then optional flags, rest = prompt. Flags must come before the prompt text.

```
export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"
bash ${CLAUDE_PLUGIN_ROOT}/scripts/task-assign.sh "<pane>" "<id>" [flags] "<prompt>"
```

Flags:
- `--eta MINUTES` — expected completion window; stores `eta_at` (ISO-8601 UTC). Tasks past their ETA show an `OVERDUE` flag in `/task-status` and `/task-board`.
- `--stage NAME` — set/overwrite the task's stage label (suggested: `plan`, `dispatch`, `execute`, `audit`, `push`).
- `--context NAME` — attach a session-context snapshot (`<git-root>/tmp/contexts/NAME.md`). Errors if the snapshot is missing. The generated prompt tells the executor to run `/session-context:context-load NAME` first, and `meta.context` is recorded on the task.
- `--force` — bypass the status-transition check and unmet-dependency gate (records "forced" in history).

Behavior notes:
- Assignment is refused if any `depends_on` task is not `done` (the error names the unmet deps) — complete them or use `--force`.
- If the script reports session-chat dispatch failed, the ledger was NOT updated and the prompt file was rolled back (deleted if new, restored if it was a reassignment overwrite) — fix the dispatch issue (recipient busy, no /whoami, etc.) and retry. Remind the user that the executor pane needs `SESSION_CHAT_INCOMING_MODE=auto` (or `assist`) for the task to actually be acted on.
- First successful assignment stamps `started_at` on the task.
