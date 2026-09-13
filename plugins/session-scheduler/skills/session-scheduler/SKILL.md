---
name: session-scheduler
description: When and how to track multi-pane orchestrator → executor work with task IDs. Use this skill before invoking /task-* commands so you understand the ledger model and the session-chat prerequisites.
---

# session-scheduler: file-backed task ledger

A thin layer on top of session-chat for orchestrator workflows. Each task gets a JSON file under `$SESSION_SCHEDULER_HOME/tasks/<id>.json`; prompts and lifecycle packets go to `$SESSION_SCHEDULER_HOME/prompts/`; auto handoffs go to `$SESSION_SCHEDULER_HOME/handoffs/<task-id>/<nonce>.md`; per-task mutation locks live in `$SESSION_SCHEDULER_HOME/locks/<id>.lock/`.

Storage is keyed on `SESSION_SCHEDULER_HOME`, which must already be present in each pane's environment, **inherited when the agent process started** — the launcher/parent shell establishes it before the agent starts, and every participating pane must be launched with the same absolute value. The `/task-*` commands and the scripts never export or derive it (there is no git-root/cwd fallback); they **fail closed** when it is unset, and the fix is to relaunch the pane/session with the correct environment. Direct human script use may set `SESSION_SCHEDULER_HOME=<dir>` in the parent shell beforehand, but agent-facing instructions never combine environment setup with helper execution — an already-running agent invokes each helper as exactly one literal Bash segment using the inherited value. `/task-assign --context NAME` (an explicit knowledge snapshot) requires `SESSION_CONTEXT_HOME` under the same inherited-at-startup contract; `--context auto` does not.

Launching every pane with the same shared home means **claude and codex panes working in the same project share the same ledger** — orchestrator and reviewer can both read/write the same task list.

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
/task-review     → status=review, durable ack to assigner (optional review gate)
  ↓ (reviewer audits)
/task-done       → status=done (records duration_seconds), durable ack to assigner
  or
/task-block      → status=blocked, durable ack to assigner
```

Legal status transitions (enforced by every command):
`created→assigned`, `created→blocked`, `assigned→review`, `assigned→done`, `assigned→blocked`, `assigned→assigned` (reassignment), `review→done` (approve), `review→blocked` (reject), `blocked→assigned`. Anything else is rejected with the current status and legal next steps; override with `--force` (or `SESSION_SCHEDULER_FORCE=1`), which records "forced" in history.

`/tasks-clean` removes tasks past `--older-than DAYS` (default 7; a bare integer is days on both providers) — **any status** by default; narrow with `--status done|blocked`. Dry-run by default. It deletes every artifact the task owns by exact name (base prompt, review packet, ack packets, `handoffs/<id>/`, leftover lock), keeps a task that a surviving task still lists in `depends_on` (reported as `kept … (referenced by …)`), and sweeps aged **orphans** (handoff dirs / known-suffix prompt files with no task JSON).

## Stages, ETAs, and dependencies

- **Stages** are optional free-form labels (`--stage` on `/task-new` or `/task-assign`). Suggested pipeline: `plan`, `dispatch`, `execute`, `audit`, `push`. View grouped output with `/task-status --by-stage` or `/task-board`.
- **ETAs**: `/task-assign --eta MINUTES` stores `eta_at`; tasks past it are flagged `OVERDUE`. Tasks in `assigned`/`review` with no update for `SESSION_SCHEDULER_STALE_MINUTES` (default 30) are flagged `STALE`.
- **Dependencies**: `/task-new --depends-on id1,id2` stores `depends_on`. `/task-assign` refuses to dispatch until every dependency is `done` (the error names the unmet deps) unless `--force`.
- **Context attach (explicit)**: `/task-assign --context NAME` resolves the knowledge context snapshot at `$SESSION_CONTEXT_HOME/NAME.md`, records `meta.context` + `meta.context_home`, and tells the executor to `/knowledge:context-load NAME` before starting. Snapshot names follow the knowledge context store's contract — canonical `snake_case` (`^[a-z0-9]+(_[a-z0-9]+)*$`); a non-canonical `NAME` is rejected before any side effect.
- **Auto handoff**: `/task-assign --context auto` writes a **scheduler-owned** handoff at `handoffs/<task-id>/<nonce>.md` under the shared scheduler home (the nonce is 32 lowercase hex digits from OS randomness — never the task id or a timestamp), mode 0600, derived from the approved prompt + ledger state. It is never overwritten: each assignment adds a new file; the current one is recorded as `meta.handoff_file` (with `meta.handoff_home`). The packet carries the absolute path under `## Handoff` ("read it first"). The knowledge context store is never written and `SESSION_CONTEXT_HOME` is not needed. Handoffs are swept with the task by `/tasks-clean`. A reassignment with no `--context` clears all four attachment keys.

## Concurrency

Every ledger write is atomic (tmp + mv), and every read-modify-write (status transitions, history, metadata, acks, durations) runs under the per-task lock `locks/<id>.lock/` (mkdir-atomic; `pid` inside; `SESSION_SCHEDULER_LOCK_TIMEOUT_SECS`, default 10; a lock whose holder pid is dead is reclaimed). Both providers use the identical lock path, so Claude and Codex panes sharing one ledger exclude each other. The lock is never held across session-chat transport. Known limitation: two simultaneous *reassignments of the same task* still race on the prompt file; coordinate those serially.

## Nested transport and escalation

`/task-assign`, `/task-review`, `/task-done`, and `/task-block` perform nested session-chat/tmux transport (dispatch or notification) in addition to their ledger writes. Transport contract:

1. Invoke exactly one literal Bash segment: `bash "<canonical installed helper>" <arguments>`.
2. In a sandboxed runtime (e.g. Codex), request scoped escalation/approval for that exact installed helper on the first attempt whenever it may dispatch or notify through session-chat/tmux.
3. Never work around the sandbox with `bash -c`, wrappers, `env`, assignment prefixes, exports, pipelines, chaining, redirection, substitution, or broad provider-home access.
4. Escalation is transport access, not authority: role, recipient, argument, confirmation, and lifecycle policies remain authoritative.
5. If transport fails **after** a state transition, inspect `/task-status <id>` before acting: never rerun `task-done`/`task-block` once the task is done/blocked; never use --force to repair a notification; report the partial success and, only when authorized, send a separate exact session-chat message. `/task-review` retries dispatch only while the task is in `review` with no successful reviewer-dispatch timestamp (never duplicate a delivered packet); `/task-assign` keeps its rollback on hard dispatch failure.

## Hard prerequisites

1. **session-chat ≥ 0.13.0** installed. Its send lock and retries prevent corrupted dispatches, and its durable inbox means a dispatch or ack to a busy pane is recovered on its next turn rather than lost.
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

## Conventions

- **Status updates flow executor → ledger → durable ack to assigner**. The orchestrator never polls executor panes; it polls the ledger via `/task-status`.
- **Assigner is recorded at `/task-new` time**, derived from the current pane's `@name`. If you create tasks from an unnamed pane, assigner = `?` and the ack will be skipped.
- **Reassign isn't automatic**. If an executor goes silent, run `/task-status <id>` to inspect, then `/task-assign <new-pane> <id> <prompt>` — the prompt file will be regenerated and history will record the reassignment.

## Failure modes

- **`session-chat dispatch to '<pane>' failed; ledger NOT updated, prompt file rolled back`** — only happens on a hard failure (no name, unknown/ambiguous target). A *busy* executor is not a failure: the dispatch is queued to the executor's durable inbox and surfaces on its next turn, so the ledger still flips to `assigned`. For a hard failure, fix it (run `/session-chat:panes`, ensure the executor has a name), then retry `/task-assign`.
- **Lifecycle acks are durable, not best-effort transport** — `/task-done`, `/task-block`, and `/task-review`'s assigner ack always update the ledger first, then ack via a delivery ladder: file-backed dispatch (queued to the assigner's durable inbox when busy, recovered on their next turn), falling back to inline `/send` only if dispatch fails, falling back to a recorded failure only if both fail. `meta.last_ack` records `status` (`dispatched`/`inline-fallback`/`failed`) and `file` for every attempt. A `failed` ack is a **partial success**: the transition already happened, so never rerun the helper and never use --force to repair the notification — follow the transport contract above.
- **Tasks are `assigned` but executor never acts** — almost always `INCOMING_MODE=notify` on the executor side. Run `/session-chat:incoming-mode auto` in the executor's shell.
- **`jq` missing** — `brew install jq`. The ledger is JSON; jq is a hard dependency.
