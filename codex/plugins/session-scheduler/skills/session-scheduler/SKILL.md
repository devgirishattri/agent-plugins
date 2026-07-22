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
| Clean old tasks | `$session-scheduler:tasks-clean [--older-than 7d] [--status STATUS] [--apply]` |
| Inspect setup | `$session-scheduler:scheduler-doctor` |

## Lifecycle

Legal status transitions (enforced by every command): `created→assigned`, `created→blocked`, `assigned→review`, `assigned→done`, `assigned→blocked`, `assigned→assigned` (reassignment), `review→done` (approve), `review→blocked` (reject), `blocked→assigned`. Anything else is rejected with the current status and legal next steps; override with `--force` (or `SESSION_SCHEDULER_FORCE=1`), which records "forced" in history.

- First assignment stamps `started_at`; `task-done` records `duration_seconds`.
- `--eta MINUTES` on assign stores `eta_at`; overdue tasks are flagged `OVERDUE`. Tasks in `assigned`/`review` with no update for `SESSION_SCHEDULER_STALE_MINUTES` (default 30) are flagged `STALE`.
- Stages are optional free-form labels (suggested pipeline: `plan`, `dispatch`, `execute`, `audit`, `push`); view grouped output with `task-status --by-stage` or `task-board`.
- `--depends-on` gates assignment until every dependency is `done`.
- `--context NAME` attaches an existing session-context snapshot. `--context auto` creates a private immutable task handoff named `task-<id>-<random>` from the approved prompt and current ledger state, then attaches it.
- `--reviewer PANE` stores the independent reviewer route. When the executor calls `task-review`, the scheduler automatically dispatches the audit packet to that pane. A hard delivery failure leaves the task in review and must be retried with `task-review`; there is no one-line send downgrade.
- `--workflow ID` groups related tasks in canonical `meta.workflow_id`; `--workflow-id` remains an alias. `task-status --by-workflow` shows each complete workflow arc, including done steps, while omitting tasks without a workflow id; `--workflow ID` filters one workflow.
- Every assignment records and embeds the absolute scheduler/context homes so a child checkout does not silently write to a different ledger.
- `tasks-clean` selects task files older than its threshold regardless of status unless `--status` narrows the selection. It is dry-run only unless `--apply` is explicitly requested and confirmed.

## Transport contract

Scheduler helpers can perform nested session-chat/tmux transport: `task-assign`
dispatches before its ledger write, while `task-review`, `task-done`, and
`task-block` can dispatch or notify after a transition is durable. In Codex,
request scoped escalation/approval for the exact installed helper on the first attempt
whenever it may dispatch or notify. Keep raw token zero as `bash` and
invoke the helper as one literal Bash segment; never use `bash -c`, wrappers,
`env`, assignment prefixes, exports, pipelines, chaining, redirection,
substitution, or broad provider-home access to bypass the sandbox.

Escalation is transport access, not authority: recorded roles and recipients,
arguments, confirmations, and lifecycle rules remain in force. A failed
post-transition done/block notification is partial success; inspect
`task-status`, never rerun the completed transition, and never use --force to
repair transport. Send a separate exact session-chat message only when
authorized. `task-review` permits a dispatch-only retry only while the task is
in `review`, has no successful reviewer-dispatch timestamp, and the prior
dispatch is known to have failed. If dispatch succeeded but timestamp
persistence failed, delivery is ambiguous even though a later helper call
cannot distinguish it: do not retry until recipient or outbox evidence proves
no packet was delivered, and never duplicate a delivered packet. A hard
`task-assign` dispatch failure retains its existing rollback behavior and may
be retried only after the transport cause is fixed.

## Scope

Intentionally includes task ids, assignment, explicit reviewer routes, workflow groups, status, review gates, stages, ETAs, dependencies, task-scoped context, done/block reports, cleanup, and diagnostics. It defers a full role registry, fanout, timeout reassignment, priority queues, and daemon behavior.

## Requirements

- `session-chat` 0.13.0 or newer must be available. Its durable inbox means a dispatch or ack to a busy pane is recovered on that pane's next turn rather than lost.
- Executor panes must have unique session-chat names.
- Executor panes should use `SESSION_CHAT_INCOMING_MODE=auto` or `assist` to act on assigned dispatches.
- Task files are stored under `SESSION_SCHEDULER_HOME`, which must already be present in each pane's environment, inherited when the agent process started: the launcher/parent shell establishes it before the agent starts, and every participating pane must be launched with the same absolute value. The `$session-scheduler:*` skills and commands never export or derive it — an already-running agent invokes each helper as exactly one literal Bash segment using the inherited value.
- Scripts require `SESSION_SCHEDULER_HOME` and fail closed without it rather than guessing a cwd/.tmp location; the fix is to relaunch the pane/session with the correct environment. With project-local defaults, recorded provenance looks like `"context_home": "/abs/.../.tmp/contexts"` and `"scheduler_home": "/abs/.../.tmp/scheduler"`. Direct human script use may set the variable in the parent shell before invoking a script, but generated agent instructions never combine environment setup with helper execution.
- `$session-scheduler:task-assign --context` requires `SESSION_CONTEXT_HOME` under the same inherited-at-startup contract. Assignment and review packets repeat both absolute homes as provenance and relaunch guidance.
