---
name: session-scheduler
description: When and how to track multi-pane orchestrator → executor work with task IDs. Use this skill before invoking /task-* commands so you understand the ledger model and the session-chat prerequisites.
---

# session-scheduler: file-backed task ledger

A thin layer on top of session-chat for orchestrator workflows. Each task gets a JSON file under `<project_root>/tmp/scheduler/tasks/<id>.json`; prompts go to `<project_root>/tmp/scheduler/prompts/<id>.md`.

Storage is keyed on `SESSION_SCHEDULER_HOME`, which the `/task-*` commands export automatically (resolving `<git-root>/tmp/scheduler`, or pwd when not in a git repo). The scripts **require** this variable and refuse to run when it is unset — they never guess a cwd/tmp location. Set `SESSION_SCHEDULER_HOME=<dir>` yourself only when invoking the scripts directly or to point at a shared ledger. `/task-assign --context` additionally exports `SESSION_CONTEXT_HOME` so the session-context snapshot resolves the same way.

Project-local storage means **claude and codex panes working in the same project share the same ledger** — orchestrator and reviewer can both read/write the same task list.

No daemon, no priority queue, no automatic reassignment — just a ledger you can read with `/task-status`.

## When to use this plugin

Use it when **you, the orchestrator pane, are coordinating ≥3 panes** (executors / reviewers) and need to answer "what's still in flight, who has it, when did they pick it up?" without manually scrolling each pane.

**Don't use it for** simple peer chat between two panes — `/send` and `/dispatch` from session-chat are enough.

## Lifecycle

```
/task-new        → status=created
  ↓
/task-assign     → status=assigned (stamps started_at), dispatched via session-chat
  ↓ (executor works)
/task-review     → status=review, /send ack to assigner (optional review gate)
  ↓ (reviewer audits)
/task-done       → status=done (records duration_seconds), /send ack to assigner
  or
/task-block      → status=blocked, /send ack to assigner
```

Legal status transitions (enforced by every command):
`created→assigned`, `created→blocked`, `assigned→review`, `assigned→done`, `assigned→blocked`, `assigned→assigned` (reassignment), `review→done` (approve), `review→blocked` (reject), `blocked→assigned`. Anything else is rejected with the current status and legal next steps; override with `--force` (or `SESSION_SCHEDULER_FORCE=1`), which records "forced" in history.

`/tasks-clean` removes old `done`/`blocked` files (dry-run by default).

## Stages, ETAs, and dependencies

- **Stages** are optional free-form labels (`--stage` on `/task-new` or `/task-assign`). Suggested pipeline: `plan`, `dispatch`, `execute`, `audit`, `push`. View grouped output with `/task-status --by-stage` or `/task-board`.
- **ETAs**: `/task-assign --eta MINUTES` stores `eta_at`; tasks past it are flagged `OVERDUE`. Tasks in `assigned`/`review` with no update for `SESSION_SCHEDULER_STALE_MINUTES` (default 30) are flagged `STALE`.
- **Dependencies**: `/task-new --depends-on id1,id2` stores `depends_on`. `/task-assign` refuses to dispatch until every dependency is `done` (the error names the unmet deps) unless `--force`.
- **Context attach**: `/task-assign --context NAME` resolves the session-context snapshot at `<git-root>/tmp/contexts/NAME.md`, records `meta.context`, and tells the executor to `/session-context:context-load NAME` before starting.

## Hard prerequisites

1. **session-chat ≥ 0.12.0** installed. The lock + retry behavior prevents corrupted dispatches, and 0.12's durable inbox means a dispatch or ack to a busy pane is recovered on its next turn rather than lost.
2. **Executor pane has `SESSION_CHAT_INCOMING_MODE=auto`** (or `assist`). Default `notify` tells the executor *not* to read dispatched files — your tasks will be assigned in the ledger but never acted on. Run `/session-chat:incoming-mode auto` in the executor's shell.
3. **All participating panes have run `/whoami <name>`.** Pane names are the addressing scheme.

`/scheduler-doctor` checks all three and warns on misconfiguration.

## Commands

| Command | Purpose |
|---|---|
| `/task-new <name> [--meta k=v] [--stage NAME] [--depends-on id1,id2]` | Create a ledger entry. Returns the new task id. |
| `/task-assign <pane> <id> [--eta MIN] [--stage NAME] [--context NAME] [--force] <prompt>` | Dispatch the task to an executor and update the ledger. |
| `/task-status [<id>\|--all\|--pending\|--mine\|--by-stage]` | Read-only view. Default = active (created+assigned+review). Shows OVERDUE/STALE flags. |
| `/task-review <id> [--force] <note>` | Executor calls this when ready for audit (note = e.g. commit SHA); acks the assigner. |
| `/task-done <id> [--force] [note]` | Executor or reviewer calls this; records duration; auto-acks the assigner via `/send`. |
| `/task-block <id> [--force] <reason>` | Executor or reviewer calls this when blocked/rejecting; reason required. |
| `/task-board` | Stage-grouped dashboard: id, name, status, assignee, age, flags, unmet deps + totals. |
| `/tasks-clean [--older-than DAYS] [--status S] [--apply]` | Dry-run by default. |
| `/scheduler-doctor` | Diagnose dirs, session-chat install, incoming-mode, jq/tmux, date math. |

## Ledger schema

```json
{
  "id": "abcd1234",
  "name": "task name",
  "status": "created|assigned|review|done|blocked",
  "stage": "plan|dispatch|execute|audit|push|... or null",
  "assigner": "orchestrator-pane-name",
  "assignee": "executor-pane-name|null",
  "prompt_file": "/path/to/scheduler/prompts/abcd1234.md|null",
  "depends_on": ["task-id", "..."],
  "created_at": "ISO-8601",
  "updated_at": "ISO-8601",
  "started_at": "ISO-8601 (first assignment) | null",
  "eta_at": "ISO-8601 (from --eta) | null",
  "duration_seconds": 1234,
  "meta": { "free-form": "key/value", "context": "context-snapshot-name" },
  "history": [
    { "ts": "...", "event": "created|assigned|review|done|blocked", "actor": "...", "note": "..." }
  ]
}
```

`started_at`, `eta_at`, `duration_seconds`, `stage`, and `depends_on` are optional — older task files without them still work.

Atomic writes (tmp + mv) — concurrent executors updating different tasks won't conflict.

## Conventions

- **Status updates flow executor → ledger → ack to assigner**. The orchestrator never polls executor panes; it polls the ledger via `/task-status`.
- **Assigner is recorded at `/task-new` time**, derived from the current pane's `@name`. If you create tasks from an unnamed pane, assigner = `?` and the ack will be skipped.
- **Reassign isn't automatic**. If an executor goes silent, run `/task-status <id>` to inspect, then `/task-assign <new-pane> <id> <prompt>` — the prompt file will be regenerated and history will record the reassignment.

## Failure modes

- **`session-chat dispatch failed; ledger NOT updated`** — only happens on a hard failure (no name, unknown/ambiguous target). A *busy* executor is no longer a failure: with session-chat ≥ 0.12.0 the dispatch is queued to the executor's durable inbox and surfaces on its next turn, so the ledger still flips to `assigned`. For a hard failure, fix it (run `/session-chat:panes`, ensure the executor has a name), then retry `/task-assign`.
- **Done/block acks are best-effort** — `/task-done` and `/task-block` always update the ledger first, then send the ack via session-chat. With ≥ 0.12.0 the ack is durably delivered (recovered on the assigner's next turn); if session-chat is missing the ledger is still updated and the ack is skipped with a warning.
- **Tasks are `assigned` but executor never acts** — almost always `INCOMING_MODE=notify` on the executor side. Run `/session-chat:incoming-mode auto` in the executor's shell.
- **`jq` missing** — `brew install jq`. The ledger is JSON; jq is a hard dependency.
