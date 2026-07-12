---
description: Assign a task to an executor pane and dispatch via session-chat
argument-hint: <pane> <id> [--eta MINUTES] [--stage NAME] [--context NAME|auto] [--reviewer PANE] [--workflow ID] [--force] <prompt>
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
- `--context NAME` — attach a session-context snapshot (`<git-root>/tmp/contexts/NAME.md`). Errors if the snapshot is missing. The generated prompt tells the executor to run `/session-context:context-load NAME` first (with the absolute context store embedded), and `meta.context` is recorded on the task.
- `--context auto` — instead of requiring a pre-existing snapshot, generate a private, **immutable** handoff (`auto-<id>-<random>.md`, chmod 400) derived from the approved prompt + ledger state, attach it, and record `meta.context = auto-<id>-<random>` (the exact name is printed in the command output). It is removed automatically if the dispatch rolls back. No live-session summarization — safe to generate from the assignment itself.
- `--reviewer PANE` — record a reviewer pane. When the executor runs `/task-review`, the audit request is auto-dispatched to this pane (durable; recovered on their next turn if busy). Recorded as `.reviewer` on the task.
- `--workflow ID` — group this assignment under a workflow id (`meta.workflow_id`); list the group with `/task-status --workflow ID`.
- `--force` — bypass the status-transition check and unmet-dependency gate (records "forced" in history).

Behavior notes:
- Assignment is refused if any `depends_on` task is not `done` (the error names the unmet deps) — complete them or use `--force`.
- If the script reports session-chat dispatch failed, the ledger was NOT updated and the prompt file was rolled back (deleted if new, restored if it was a reassignment overwrite). This happens only on a **hard failure** (no /whoami, unknown/ambiguous target). A **busy** recipient is *not* a failure — the dispatch is durably queued and the ledger still flips to `assigned` — so do not treat busy as a rollback cause. Fix the hard cause and retry. Remind the user that the executor pane needs `SESSION_CHAT_INCOMING_MODE=auto` (or `assist`) for the task to actually be acted on.
- First successful assignment stamps `started_at` on the task.
- The dispatched prompt embeds the **absolute** shared ledger home (and context store, with `--context`) so an executor sitting in a different worktree/checkout targets THIS ledger instead of silently resolving its own git-root default. The absolute home is also recorded as `meta.scheduler_home`.
- Dispatch is refused if the installed session-chat is below the required floor (durable inbox); update session-chat or override with `SESSION_SCHEDULER_SKIP_VERSION_CHECK=1`.
