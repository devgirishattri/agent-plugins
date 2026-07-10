---
name: session-scheduler
description: "Use a file-backed task ledger to coordinate an orchestrator pane with executor or reviewer panes through session-chat."
---

# Session Scheduler

Use this skill when the user asks to coordinate multiple panes, track assigned work, or inspect task state. Session Scheduler is a thin orchestration layer over Session Chat; it is not a daemon or autonomous queue.

## Command Set

| Goal | Command |
| --- | --- |
| Create a task | `$session-scheduler:task-new <name> [--meta k=v] [--stage NAME] [--depends-on id1,id2] [--reviewer PANE] [--workflow ID]` |
| Assign a task | `$session-scheduler:task-assign <pane> <task-id> [--eta MIN] [--stage NAME] [--context NAME\|auto] [--reviewer PANE] [--workflow ID] [--force] <prompt>` |
| View tasks | `$session-scheduler:task-status [task-id\|--all\|--pending\|--mine\|--by-stage\|--by-workflow\|--workflow ID]` |
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
- `--context NAME` attaches an existing session-context snapshot. `--context auto` creates a private immutable task handoff from the approved prompt and current ledger state, then attaches it.
- `--reviewer PANE` stores the independent reviewer route. When the executor calls `task-review`, the scheduler automatically dispatches the audit packet to that pane and preserves the review state even if delivery needs retrying.
- `--workflow ID` groups related tasks in canonical `meta.workflow_id`; `--workflow-id` remains an alias. `task-status --by-workflow` shows each complete workflow arc, including done steps, while omitting tasks without a workflow id; `--workflow ID` filters one workflow.
- Every assignment records and embeds the absolute scheduler/context homes so a child checkout does not silently write to a different ledger.

## Scope

Intentionally includes task ids, assignment, explicit reviewer routes, workflow groups, status, review gates, stages, ETAs, dependencies, task-scoped context, done/block reports, cleanup, and diagnostics. It defers a full role registry, fanout, timeout reassignment, priority queues, and daemon behavior.

## Requirements

- `session-chat` 0.13.0 or newer must be available. Its durable inbox means a dispatch or ack to a busy pane is recovered on that pane's next turn rather than lost.
- Executor panes must have unique session-chat names.
- Executor panes should use `SESSION_CHAT_INCOMING_MODE=auto` or `assist` to act on assigned dispatches.
- Task files are stored under `SESSION_SCHEDULER_HOME`, which the `$session-scheduler:*` commands export automatically to `<git-root>/tmp/scheduler` (or pwd when not in a git repo) unless already set. In a multi-checkout workspace, start every pane with the same root-level value; assignment and review packets repeat that absolute value.
- Scripts require `SESSION_SCHEDULER_HOME` and refuse to run without it rather than guessing a cwd/tmp location. Set it yourself only for direct script use or to point at a shared ledger.
- `$session-scheduler:task-assign --context` also exports `SESSION_CONTEXT_HOME` to `<git-root>/tmp/contexts` unless already set, so attached context snapshots resolve consistently.
