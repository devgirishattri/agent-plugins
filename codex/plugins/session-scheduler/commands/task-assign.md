---
description: Assign a scheduler task to a named pane
argument-hint: <pane-name> <task-id> [--eta MINUTES] [--stage NAME] [--context NAME|auto] [--reviewer PANE] [--workflow ID] [--force] <prompt>
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Parse `$ARGUMENTS`: first word is target pane, second word is task id, then optional flags, everything after is the prompt. Flags must come before the prompt.
3. Run:

   ```bash
   export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
   export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"
   bash "$PLUGIN_ROOT/scripts/task-assign.sh" "<pane-name>" "<task-id>" [flags] "<prompt>"
   ```

4. Flags:
   - `--eta MINUTES` — stores `eta_at` (ISO-8601 UTC); tasks past it are flagged `OVERDUE` in `task-status`/`task-board`.
   - `--stage NAME` — set/overwrite the task's stage label (suggested: `plan`, `dispatch`, `execute`, `audit`, `push`).
   - `--context NAME|auto` — attach an existing snapshot, or create an immutable task-scoped handoff named `task-<id>-<random>`; the exact generated name is printed.
   - `--reviewer PANE` — set or override automatic independent-review routing.
   - `--workflow ID` — set or override the workflow group; `--workflow-id` is an alias.
   - `--force` — bypass the status-transition check and unmet-dependency gate (records "forced" in history).
5. Assignment is refused if any `depends_on` task is not `done` (the error names the unmet deps) — complete them or use `--force`. Illegal status transitions (e.g. assigning a `done` task) are also refused.
6. On hard dispatch failure the ledger is NOT updated; the prompt and any automatic context are rolled back. A busy target is queued durably and still counts as a successful assignment. Successful dispatch records the absolute shared homes for the recipient.
7. If dispatch succeeds, report the task id and assignee. First successful assignment stamps `started_at`.
8. If the target pane is missing or duplicated, suggest checking `$session-chat:panes` and `$session-chat:whoami`.
9. Mention that executor panes need `SESSION_CHAT_INCOMING_MODE=auto` or `assist` to act on assigned dispatches.
