---
name: session-scheduler
description: When and how to track multi-pane orchestrator → executor work with task IDs. Use this skill before invoking /task-* commands so you understand the ledger model and the session-chat prerequisites.
---

# session-scheduler: file-backed task ledger

A thin layer on top of session-chat for orchestrator workflows. Each task gets a JSON file under `<project_root>/tmp/scheduler/tasks/<id>.json`; prompts go to `<project_root>/tmp/scheduler/prompts/<id>.md`. Project root resolves via `git rev-parse --show-toplevel` (or pwd). Override via `SESSION_SCHEDULER_HOME=<dir>`.

Project-local storage means **claude and codex panes working in the same project share the same ledger** — orchestrator and reviewer can both read/write the same task list.

No daemon, no priority queue, no automatic reassignment — just a ledger you can read with `/task-status`.

## When to use this plugin

Use it when **you, the orchestrator pane, are coordinating ≥3 panes** (executors / reviewers) and need to answer "what's still in flight, who has it, when did they pick it up?" without manually scrolling each pane.

**Don't use it for** simple peer chat between two panes — `/send` and `/dispatch` from session-chat are enough.

## Lifecycle

```
/task-new        → status=created
  ↓
/task-assign     → status=assigned, dispatched via session-chat
  ↓ (executor works)
/task-done       → status=done, /send ack to assigner
  or
/task-block      → status=blocked, /send ack to assigner
```

`/tasks-clean` removes old `done`/`blocked` files (dry-run by default).

## Hard prerequisites

1. **session-chat ≥ 0.12.0** installed. The lock + retry behavior prevents corrupted dispatches, and 0.12's durable inbox means a dispatch or ack to a busy pane is recovered on its next turn rather than lost.
2. **Executor pane has `SESSION_CHAT_INCOMING_MODE=auto`** (or `assist`). Default `notify` tells the executor *not* to read dispatched files — your tasks will be assigned in the ledger but never acted on. Run `/session-chat:incoming-mode auto` in the executor's shell.
3. **All participating panes have run `/whoami <name>`.** Pane names are the addressing scheme.

`/scheduler-doctor` checks all three and warns on misconfiguration.

## Commands

| Command | Purpose |
|---|---|
| `/task-new <name> [--meta k=v]` | Create a ledger entry. Returns the new task id. |
| `/task-assign <pane> <id> <prompt>` | Dispatch the task to an executor and update the ledger. |
| `/task-status [<id>\|--all\|--pending\|--mine]` | Read-only view. Default = active (created+assigned). |
| `/task-done <id> [note]` | Executor calls this; auto-acks the assigner via `/send`. |
| `/task-block <id> <reason>` | Executor calls this when blocked; reason required. |
| `/tasks-clean [--older-than DAYS] [--status S] [--apply]` | Dry-run by default. |
| `/scheduler-doctor` | Diagnose dirs, session-chat install, incoming-mode, jq/tmux. |

## Ledger schema

```json
{
  "id": "abcd1234",
  "name": "task name",
  "status": "created|assigned|done|blocked",
  "assigner": "orchestrator-pane-name",
  "assignee": "executor-pane-name|null",
  "prompt_file": "/Users/.../scheduler/prompts/abcd1234.md|null",
  "created_at": "ISO-8601",
  "updated_at": "ISO-8601",
  "meta": { "free-form": "key/value" },
  "history": [
    { "ts": "...", "event": "created|assigned|done|blocked", "actor": "...", "note": "..." }
  ]
}
```

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
