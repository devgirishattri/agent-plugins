---
description: Assign a scheduler task to a named pane
argument-hint: <pane-name> <task-id> [--eta MINUTES] [--stage NAME] [--context NAME] [--force] <prompt>
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.2.0}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
   ```

2. Parse `$ARGUMENTS`: first word is target pane, second word is task id, then optional flags, everything after is the prompt. Flags must come before the prompt.
3. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/task-assign.sh" "<pane-name>" "<task-id>" [flags] "<prompt>"
   ```

4. Flags:
   - `--eta MINUTES` — stores `eta_at` (ISO-8601 UTC); tasks past it are flagged `OVERDUE` in `task-status`/`task-board`.
   - `--stage NAME` — set/overwrite the task's stage label (suggested: `plan`, `dispatch`, `execute`, `audit`, `push`).
   - `--context NAME` — attach a session-context snapshot from `<git-root>/tmp/contexts/NAME.md`; errors if missing. The prompt tells the executor to run `$session-context:context-load NAME` first, and `meta.context` is recorded.
   - `--force` — bypass the status-transition check and unmet-dependency gate (records "forced" in history).
5. Assignment is refused if any `depends_on` task is not `done` (the error names the unmet deps) — complete them or use `--force`. Illegal status transitions (e.g. assigning a `done` task) are also refused.
6. On dispatch failure the ledger is NOT updated and the prompt file is rolled back (deleted if new, restored if it was a reassignment overwrite).
7. If dispatch succeeds, report the task id and assignee. First successful assignment stamps `started_at`.
8. If the target pane is missing or duplicated, suggest checking `$session-chat:panes` and `$session-chat:whoami`.
9. Mention that executor panes need `SESSION_CHAT_INCOMING_MODE=auto` or `assist` to act on assigned dispatches.
