---
name: session-scheduler
description: When and how to track multi-pane orchestrator → executor work with task IDs. Use this skill before invoking /task-* commands so you understand the ledger model and the session-chat prerequisites.
---

# session-scheduler: file-backed task ledger

A thin layer on top of session-chat for orchestrator workflows. Each task gets a JSON file under `~/.claude/scheduler/tasks/<id>.json`; prompts go to `~/.claude/scheduler/prompts/<id>.md`. No daemon, no priority queue, no automatic reassignment — just a ledger you can read with `/task-status`.

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

1. **session-chat ≥ 0.11.0** installed. The lock + retry behavior in 0.11 prevents corrupted dispatches.
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

- **`session-chat dispatch failed; ledger NOT updated`** — fix the dispatch issue first (run `/session-chat:panes`, ensure executor has a name and is responsive), then retry `/task-assign`. The ledger only flips to `assigned` on a successful dispatch.
- **Tasks are `assigned` but executor never acts** — almost always `INCOMING_MODE=notify` on the executor side. Run `/session-chat:incoming-mode auto` in the executor's shell.
- **`jq` missing** — `brew install jq`. The ledger is JSON; jq is a hard dependency.
