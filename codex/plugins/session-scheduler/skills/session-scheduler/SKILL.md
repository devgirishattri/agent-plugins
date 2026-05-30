---
name: session-scheduler
description: "Use a file-backed task ledger to coordinate an orchestrator pane with executor or reviewer panes through session-chat."
---

# Session Scheduler

Use this skill when the user asks to coordinate multiple panes, track assigned work, or inspect task state. Session Scheduler is a thin orchestration layer over Session Chat; it is not a daemon or autonomous queue.

## Command Set

| Goal | Command |
| --- | --- |
| Create a task | `$session-scheduler:task-new <name> [--meta k=v]` |
| Assign a task | `$session-scheduler:task-assign <pane> <task-id> <prompt>` |
| View tasks | `$session-scheduler:task-status [task-id|--all|--pending|--mine]` |
| Mark done | `$session-scheduler:task-done <task-id> [note]` |
| Mark blocked | `$session-scheduler:task-block <task-id> <reason>` |
| Clean old tasks | `$session-scheduler:tasks-clean [--older-than 7d] [--status done] [--apply]` |
| Inspect setup | `$session-scheduler:scheduler-doctor` |

## Scope

Intentionally includes task ids, assignment, status, done/block reports, cleanup, and diagnostics. It defers role registries, fanout, review gates, timeout reassignment, priority queues, and daemon behavior.

## Requirements

- `session-chat` 0.13.0 or newer must be available. Its durable inbox means a dispatch or ack to a busy pane is recovered on that pane's next turn rather than lost.
- Executor panes must have unique session-chat names.
- Executor panes should use `SESSION_CHAT_INCOMING_MODE=auto` or `assist` to act on assigned dispatches.
- Task files are stored under the current project at `tmp/scheduler/tasks` by default. Override with `SESSION_SCHEDULER_HOME` when a different shared ledger location is needed.
