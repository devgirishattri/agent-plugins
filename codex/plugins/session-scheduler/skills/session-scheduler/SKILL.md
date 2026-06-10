---
name: session-scheduler
description: "Use a file-backed task ledger to coordinate an orchestrator pane with executor or reviewer panes through session-chat."
---

# Session Scheduler

Use this skill when the user asks to coordinate multiple panes, track assigned work, or inspect task state. Session Scheduler is a thin orchestration layer over Session Chat; it is not a daemon or autonomous queue.

## Command Set

| Goal | Command |
| --- | --- |
| Create a task | `$session-scheduler:task-new <name> [--meta k=v] [--stage NAME] [--depends-on id1,id2]` |
| Assign a task | `$session-scheduler:task-assign <pane> <task-id> [--eta MIN] [--stage NAME] [--context NAME] [--force] <prompt>` |
| View tasks | `$session-scheduler:task-status [task-id|--all|--pending|--mine|--by-stage]` |
| Dashboard | `$session-scheduler:task-board` |
| Request review | `$session-scheduler:task-review <task-id> [--force] <note>` |
| Mark done | `$session-scheduler:task-done <task-id> [--force] [note]` |
| Mark blocked | `$session-scheduler:task-block <task-id> [--force] <reason>` |
| Clean old tasks | `$session-scheduler:tasks-clean [--older-than 7d] [--status done] [--apply]` |
| Inspect setup | `$session-scheduler:scheduler-doctor` |

## Lifecycle

Legal status transitions (enforced by every command): `created→assigned`, `created→blocked`, `assigned→review`, `assigned→done`, `assigned→blocked`, `assigned→assigned` (reassignment), `review→done` (approve), `review→blocked` (reject), `blocked→assigned`. Anything else is rejected with the current status and legal next steps; override with `--force` (or `SESSION_SCHEDULER_FORCE=1`), which records "forced" in history.

- First assignment stamps `started_at`; `task-done` records `duration_seconds`.
- `--eta MINUTES` on assign stores `eta_at`; overdue tasks are flagged `OVERDUE`. Tasks in `assigned`/`review` with no update for `SESSION_SCHEDULER_STALE_MINUTES` (default 30) are flagged `STALE`.
- Stages are optional free-form labels (suggested pipeline: `plan`, `dispatch`, `execute`, `audit`, `push`); view grouped output with `task-status --by-stage` or `task-board`.
- `--depends-on` gates assignment until every dependency is `done`.
- `--context NAME` on assign attaches the session-context snapshot at `<git-root>/tmp/contexts/NAME.md` and records `meta.context`.

## Scope

Intentionally includes task ids, assignment, status, review gates, stages, ETAs, dependencies, done/block reports, cleanup, and diagnostics. It defers role registries, fanout, timeout reassignment, priority queues, and daemon behavior.

## Requirements

- `session-chat` 0.13.0 or newer must be available. Its durable inbox means a dispatch or ack to a busy pane is recovered on that pane's next turn rather than lost.
- Executor panes must have unique session-chat names.
- Executor panes should use `SESSION_CHAT_INCOMING_MODE=auto` or `assist` to act on assigned dispatches.
- Task files are stored under the current project at `tmp/scheduler/tasks` by default. Override with `SESSION_SCHEDULER_HOME` when a different shared ledger location is needed.
