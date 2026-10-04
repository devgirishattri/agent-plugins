---
name: session-scheduler
description: When and how to track multi-pane orchestrator → executor work with task IDs. Use this skill before invoking /task-* commands so you understand the ledger model and the session-chat prerequisites.
---

# session-scheduler: file-backed task ledger

A thin layer on top of session-chat for orchestrator workflows. Each task gets a JSON file under `$SESSION_SCHEDULER_HOME/tasks/<id>.json`. Prompts and lifecycle packets go to `$SESSION_SCHEDULER_HOME/prompts/`. Auto handoffs go to `$SESSION_SCHEDULER_HOME/handoffs/<task-id>/<nonce>.md`. Per-task mutation locks live in `$SESSION_SCHEDULER_HOME/locks/<id>.lock/`.

Storage is keyed on `SESSION_SCHEDULER_HOME`. It must already be present in each pane's environment, **inherited when the agent process started**. The launcher or parent shell sets it before the agent starts. Launch every participating pane with the same absolute value.

The `/task-*` commands and the scripts never export or derive it. There is no git-root/cwd fallback. They **fail closed** when it is unset. To fix this, relaunch the pane or session with the correct environment.

Direct human script use may set `SESSION_SCHEDULER_HOME=<dir>` in the parent shell beforehand. Agent-facing instructions never combine environment setup with helper execution. An already-running agent invokes each helper as exactly one literal Bash segment using the inherited value.

`/task-assign --context NAME` (an explicit knowledge snapshot) requires `SESSION_CONTEXT_HOME` under the same inherited-at-startup contract. `--context auto` does not.

Launch every pane with the same shared home. Then **claude and codex panes working in the same project share the same ledger**. The orchestrator and the reviewer can both read and write the same task list.

No daemon, no priority queue, no automatic reassignment — just a ledger you can read with `/task-status`.

## When to use this plugin

Use it when **you, the orchestrator pane, coordinate ≥3 panes** (executors and reviewers). It answers three questions without scrolling each pane: what is still in flight, who has it, and when they picked it up.

**Don't use it for** simple peer chat between two panes — `/send` and `/dispatch` from session-chat are enough.

## Lifecycle

```
/task-new        → status=created
  ↓
/task-assign     → status=assigned (stamps started_at), dispatched via session-chat
  ↓ (executor works)
/task-review     → status=review, durable ack to assigner (optional review gate)
  ↓ (reviewer audits)
/task-done       → status=done (records duration_seconds), durable ack to assigner
  or
/task-block      → status=blocked, durable ack to assigner
```

Legal status transitions (enforced by every command):
`created→assigned`, `created→blocked`, `assigned→review`, `assigned→done`, `assigned→blocked`, `assigned→assigned` (reassignment), `review→done` (approve), `review→blocked` (reject), `blocked→assigned`. Anything else is rejected with the current status and legal next steps; override with `--force` (or `SESSION_SCHEDULER_FORCE=1`), which records "forced" in history.

`/tasks-clean` removes tasks past `--older-than DAYS` (default 7; a bare integer is days on both providers). It removes **any status** by default; narrow with `--status done|blocked`. It is a dry run by default.

- It deletes every artifact the task owns, by exact name: base prompt, review packet, ack packets, `handoffs/<id>/`, and any leftover lock.
- It keeps a task that a surviving task still lists in `depends_on`. It reports this as `kept … (referenced by …)`.
- It sweeps aged **orphans**: handoff dirs and known-suffix prompt files with no task JSON.

## Stages, ETAs, and dependencies

- **Stages** are optional free-form labels (`--stage` on `/task-new` or `/task-assign`). Suggested pipeline: `plan`, `dispatch`, `execute`, `audit`, `push`. View grouped output with `/task-status --by-stage` or `/task-board`.
- **ETAs**: `/task-assign --eta MINUTES` stores `eta_at`; tasks past it are flagged `OVERDUE`. Tasks in `assigned`/`review` with no update for `SESSION_SCHEDULER_STALE_MINUTES` (default 30) are flagged `STALE`.
- **Dependencies**: `/task-new --depends-on id1,id2` stores `depends_on`. `/task-assign` refuses to dispatch until every dependency is `done` (the error names the unmet deps) unless `--force`.
- **Context attach (explicit)**: `/task-assign --context NAME` resolves the knowledge context snapshot at `$SESSION_CONTEXT_HOME/NAME.md`. It records `meta.context` + `meta.context_home`. It tells the executor to `/knowledge:context-load NAME` before starting. Snapshot names follow the knowledge context store's contract — canonical `snake_case` (`^[a-z0-9]+(_[a-z0-9]+)*$`); a non-canonical `NAME` is rejected before any side effect.
- **Auto handoff**: `/task-assign --context auto` writes a **scheduler-owned** handoff at `handoffs/<task-id>/<nonce>.md` under the shared scheduler home. The handoff derives from the approved prompt and ledger state, and its mode is 0600. The nonce is 32 lowercase hex digits from OS randomness — never the task id or a timestamp. The file is never overwritten: each assignment adds a new file. The current file is recorded as `meta.handoff_file` (with `meta.handoff_home`). The packet carries the absolute path under `## Handoff` ("read it first"). The knowledge context store is never written, and `SESSION_CONTEXT_HOME` is not needed. `/tasks-clean` sweeps handoffs with the task. A reassignment with no `--context` clears all four attachment keys.

## Concurrency

Every ledger write is atomic (tmp + mv). Every read-modify-write (status transitions, history, metadata, acks, durations) runs under the per-task lock `locks/<id>.lock/`. The lock is mkdir-atomic, with a `pid` inside. `SESSION_SCHEDULER_LOCK_TIMEOUT_SECS` sets the wait (default 10). A lock whose holder pid is dead is reclaimed. Both providers use the identical lock path, so Claude and Codex panes sharing one ledger exclude each other. The lock is never held across session-chat transport.

Known limitation: two simultaneous *reassignments of the same task* still race on the prompt file. Coordinate those serially.

## Nested transport and escalation

`/task-assign`, `/task-review`, `/task-done`, and `/task-block` perform nested session-chat/tmux transport (dispatch or notification) in addition to their ledger writes. Transport contract:

1. Invoke exactly one literal Bash segment: `bash "<canonical installed helper>" <arguments>`.
2. In a sandboxed runtime (e.g. Codex), request scoped escalation/approval for that exact installed helper on the first attempt whenever it may dispatch or notify through session-chat/tmux.
3. Never work around the sandbox with `bash -c`, wrappers, `env`, assignment prefixes, exports, pipelines, chaining, redirection, substitution, or broad provider-home access.
4. Escalation is transport access, not authority: role, recipient, argument, confirmation, and lifecycle policies remain authoritative.
5. If transport fails **after** a state transition, inspect `/task-status <id>` before acting. Then follow these rules:
   - Never rerun `task-done`/`task-block` once the task is done/blocked.
   - Never use --force to repair a notification.
   - Report the partial success. Send a separate exact session-chat message only when authorized.
   - `/task-review` retries dispatch only while the task is in `review` with no successful reviewer-dispatch timestamp. It never duplicates a delivered packet.
   - `/task-assign` keeps its rollback on hard dispatch failure.

## Hard prerequisites

1. **session-chat ≥ 0.13.0** installed. Its send lock and retries prevent corrupted dispatches. Its durable inbox recovers a dispatch or ack to a busy pane on its next turn, so the message is not lost.
2. **Executor pane has `SESSION_CHAT_INCOMING_MODE=auto`** (or `assist`). Default `notify` tells the executor *not* to read dispatched files — your tasks will be assigned in the ledger but never acted on. Run `/session-chat:incoming-mode auto` in the executor's shell.
3. **All participating panes have unique registered names** (via `/whoami <name>` or SessionStart auto-naming). Pane names are the addressing scheme.

`/scheduler-doctor` checks the session-chat install/version (#1) and incoming-mode (#2), warning on misconfiguration, and reports the current pane name (it cannot inspect other panes for #3).

## Commands

| Command | Purpose |
|---|---|
| `/task-new <name> [--meta k=v] [--stage NAME] [--workflow ID] [--reviewer PANE] [--depends-on id1,id2]` | Create a ledger entry. Returns the new task id. |
| `/task-assign <pane> <id> [--eta MIN] [--stage NAME] [--context NAME] [--reviewer PANE] [--workflow ID] [--force] <prompt>` | Dispatch the task to an executor and update the ledger. |
| `/task-status [<id>\|--all\|--pending\|--mine\|--by-stage\|--by-workflow\|--workflow ID]` | Read-only view. Default = active (created+assigned+review); `--pending` = created only; `--mine` = assigner, assignee, or reviewer is me. Shows OVERDUE/STALE flags. |
| `/task-review <id> [--force] <note>` | Executor calls this when ready for audit (note = e.g. commit SHA); durably acks the assigner. A dispatch-only retry reuses the original note. |
| `/task-done <id> [--force] [note]` | Executor or reviewer calls this; records duration; durably acks the assigner. |
| `/task-block <id> [--force] <reason>` | Executor or reviewer calls this when blocked/rejecting; reason required. |
| `/task-board` | Stage-grouped dashboard: id, name, status, assignee, age, flags, unmet deps + totals. |
| `/tasks-clean [--older-than DAYS] [--status S] [--apply]` | Dry-run by default. Removes owned prompt/packet/handoff files too; keeps referenced prerequisites; sweeps aged orphans. |
| `/session-scheduler:task-contract` | Opt-in verification contracts (0.7.0): pinned checks, generation-bound receipts, reviewer admission. Contracted tasks reject `--force` and route through the engine. |
| `/scheduler-doctor` | Diagnose dirs (tasks/prompts/handoffs/locks), session-chat install, incoming-mode, context home (reported, never created), legacy knowledge-store residue, jq/tmux, date math. |

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
  "reviewer": "reviewer-pane-name|null",
  "depends_on": ["task-id", "..."],
  "created_at": "ISO-8601",
  "updated_at": "ISO-8601",
  "started_at": "ISO-8601 (first assignment) | null",
  "eta_at": "ISO-8601 (from --eta) | null",
  "duration_seconds": 1234,
  "meta": {
    "free-form": "key/value",
    "context": "context_snapshot_name (explicit --context NAME only)",
    "context_home": "/abs/.../.tmp/contexts (explicit --context NAME only)",
    "handoff_file": "/abs/.../scheduler/handoffs/<id>/<nonce>.md (--context auto only)",
    "handoff_home": "/abs/.../scheduler/handoffs (--context auto only)",
    "workflow_id": "workflow-group-id",
    "scheduler_home": "/abs/.../.tmp/scheduler",
    "review_...": "reviewer-routing bookkeeping (review_dispatch_status, review_dispatched_at, …)",
    "last_ack": {"event": "done|blocked|review", "target": "assigner-pane", "status": "dispatched|inline-fallback|failed", "at": "ISO-8601", "file": "/abs/.../prompts/<id>-ack-<event>.md|null"}
  },
  "history": [
    { "ts": "...", "event": "created|assigned|review|done|blocked", "actor": "...", "note": "..." }
  ]
}
```

`started_at`, `eta_at`, `duration_seconds`, `stage`, `reviewer`, and `depends_on` are optional — older task files without them still work.

Atomic writes (tmp + mv) plus the per-task lock — concurrent actors updating the same task won't lose an update; different tasks never contend.

## Verification contracts (opt-in, 0.7.0)

A task carrying a root `contract` object is owned by `scripts/task-contract.sh`.
`/task-assign`, `/task-review`, `/task-done`, and `/task-block` hand such a task
to the engine before writing anything. Every legacy writer re-checks for a
contract under the task lock and refuses, even with `--force`. Contracted
transitions take `<id> --generation <N> "<note>"`. A contracted task counts as
complete only when `task-contract.sh inspect` reports `admitted`; a bare `done`
is `closed-unadmitted`. Cleanup keeps contracted tasks. Every pane sharing the
ledger needs 0.7.0 or later, because older copies can close a contracted task
without admission. See the `task-contract` skill for roles, the spec format,
harness behavior, and limits.

## Conventions

- **Status updates flow executor → ledger → durable ack to assigner**. The orchestrator never polls executor panes; it polls the ledger via `/task-status`.
- **Assigner is recorded at `/task-new` time**, derived from the current pane's `@name`. If you create tasks from an unnamed pane, assigner = `?` and the ack will be skipped.
- **Reassign isn't automatic**. If an executor goes silent, run `/task-status <id>` to inspect. Then run `/task-assign <new-pane> <id> <prompt>`. The script regenerates the prompt file and history records the reassignment.

## Failure modes

- **`session-chat dispatch to '<pane>' failed; ledger NOT updated, prompt file rolled back`** — this happens only on a hard failure (no name, unknown/ambiguous target). A *busy* executor is not a failure. The dispatch is queued to the executor's durable inbox and surfaces on its next turn, so the ledger still flips to `assigned`. After a hard failure, run `/session-chat:panes` and ensure the executor has a name. Then retry `/task-assign`.
- **Lifecycle acks are durable, not best-effort transport.** `/task-done`, `/task-block`, and `/task-review` always update the ledger first. Then each acks the assigner through a delivery ladder:
  1. File-backed dispatch. A busy assigner recovers it from the durable inbox on the next turn.
  2. Inline `/send`, only if dispatch fails.
  3. A recorded failure, only if both fail.

  `meta.last_ack` records `status` (`dispatched`/`inline-fallback`/`failed`) and `file` for every attempt.

  A `failed` ack is a **partial success**: the transition already happened. Never rerun the helper. Never use --force to repair the notification. Follow the transport contract above.
- **Keep four facts apart in every result.** (a) The task state in the ledger. (b) Message delivery to the assigner or reviewer: Sent, Queued, or failed. (c) The ack outcome in `meta.last_ack`. (d) Whether the recipient has acted. Delivery alone does not show that. Only evidence from that same actor counts: a correlated reply from its pane, a receipt it authored, or a ledger transition it made. An executor transition proves only that the executor acted, not the reviewer. Otherwise report the action as unverified. Example: "Task t12 is in review. The ack to the reviewer was queued; the reviewer's action is unverified."
- **Tasks are `assigned` but executor never acts** — almost always `INCOMING_MODE=notify` on the executor side. Run `/session-chat:incoming-mode auto` in the executor's shell.
- **`jq` missing** — `brew install jq`. The ledger is JSON; jq is a hard dependency.
