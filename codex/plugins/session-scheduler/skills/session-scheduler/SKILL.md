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

For consequential choices in a review or recovery, include the choice,
reason, evidence and observed result in the existing review or reconciliation
note. A handoff can point to that task. Keep routine notes short and preserve
caller-supplied text.

Every command enforces these legal status transitions:

| Current state | Allowed next states |
|---|---|
| `created` | `assigned`, `blocked` |
| `assigned` | `review`, `done`, `blocked`, `assigned` (reassignment) |
| `review` | `done` (approve), `blocked` (reject) |
| `blocked` | `assigned` |

Other transitions are rejected with the current status and legal next steps.
For legacy tasks, `--force` or `SESSION_SCHEDULER_FORCE=1` overrides this gate and records "forced" in history.
These overrides never bypass verification contracts.

- For ordinary tasks, first assignment stamps `started_at`; `task-done` records `duration_seconds`.
- `--eta MINUTES` on assign stores `eta_at`; overdue tasks are flagged `OVERDUE`. Tasks in `assigned`/`review` with no update for `SESSION_SCHEDULER_STALE_MINUTES` (default 30) are flagged `STALE`.
- Stages use one or more ASCII letters, digits, underscores or hyphens (`[A-Za-z0-9_-]+`). `task-status --by-stage` groups all tasks except `done`. `task-board` renders the stage dashboard.
- `--depends-on` gates assignment. An ordinary prerequisite normally needs status `done`. A contracted prerequisite always needs valid admission, including when the dependent task uses `--force`.
- `--context NAME` attaches an existing canonical knowledge context snapshot (lowercase snake_case matching `^[a-z0-9]+(_[a-z0-9]+)*$`). `--context auto` writes `$SESSION_SCHEDULER_HOME/handoffs/<task-id>/<nonce>.md` from the approved prompt and ledger state, with no live-session summarization. Its nonce is 32 lowercase hex characters from OS randomness. Each file is never overwritten; an existing path is refused. Directories use 0700 and files use 0600, with symlink and ownership checks. The packet carries the absolute path for direct reading, not knowledge context-load commands.
- `--reviewer PANE` records where the ordinary audit packet goes. For an ordinary task in `review`, retry reviewer dispatch only if there is no successful dispatch timestamp and independent recipient or outbox evidence confirms the earlier packet did not arrive. A delivery can succeed before its timestamp is saved. Contracted assignments reserve an attempt and generation before dispatch. If assignment or review delivery is uncertain, inspect the task and use the contract owner's reconciliation procedure before any new assignment.
- `--workflow ID` groups related tasks in canonical `meta.workflow_id`; `--workflow-id` remains an alias. `task-status --by-workflow` shows each complete workflow arc, including done steps, while omitting tasks without a workflow id; `--workflow ID` filters one workflow.
- Each ordinary assignment records and embeds the absolute scheduler home; explicit `--context NAME` also records the context home. Auto records `meta.handoff_file` and `meta.handoff_home` and clears prior context keys; explicit NAME records `meta.context` and `meta.context_home` and clears prior handoff keys. Auto never requires, reads, creates, or resolves `SESSION_CONTEXT_HOME`.
- Ordinary eligible inline `done`, `blocked`, and `review` transitions write lifecycle acknowledgement files and dispatch them durably to the assigner. Busy assigners receive them from the queued inbox; the ledger remains authoritative, and `meta.last_ack` records the event, target, delivery outcome, timestamp, and file.
- `task-status --pending` selects only `created` tasks; `--active` selects non-terminal tasks. `--mine` matches the current pane against assigner, assignee, or reviewer. Value-taking flags require a value.
- `tasks-clean` selects task files older than its threshold regardless of status unless `--status` narrows the selection. Bare `--older-than N` means days. It previews by default and deletes only with explicitly requested and confirmed `--apply`. It keeps tasks referenced by tasks outside the deletion set, reporting `kept <id> (referenced by <ids>)`. Cleanup removes the task JSON, exact assignment/review/ack prompt names, per-task handoffs directory, and lock directory. It separately previews and removes old orphan handoff directories and known-suffix prompt files whose task JSON is absent, under `Orphans:`. No wildcard task-prefix deletion is used.

## Shared ledger storage

`tasks/`, `prompts/`, and `handoffs/` are private, vetted subtrees of the shared scheduler home. Reassignment creates another handoff in the same task directory; task cleanup removes all of that task's handoffs. Hard dispatch rollback removes the new handoff file and its directory if empty.

Example auto-handoff ledger metadata (explicit context assignments use `context` and `context_home` instead of the two handoff keys):

```json
{
  "meta": {
    "scheduler_home": "/abs/shared/scheduler",
    "handoff_file": "/abs/shared/scheduler/handoffs/task-id/0123456789abcdef0123456789abcdef.md",
    "handoff_home": "/abs/shared/scheduler/handoffs"
  }
}
```

Every task JSON read-modify-write uses a non-reentrant lock at `$SESSION_SCHEDULER_HOME/locks/<id>.lock/`.
Both providers acquire this lock by exclusively creating the `pid` file inside the directory.
Acquisition waits up to `SESSION_SCHEDULER_LOCK_TIMEOUT_SECS` (default 10).
A timeout names the lock path. The helper reclaims a lock only when its holder is verified dead.
Permission-denied PID checks count as alive.
The private `locks/` directory is outside the vetted content subtrees.
Codex publishes ordinary assignment metadata and status together under this lock. Claude publishes metadata and status separately while holding the same lock. New task files are written atomically.

Reassignment without `--context` clears all four attachment keys: `meta.context`, `meta.context_home`, `meta.handoff_file`, and `meta.handoff_home`. Locks cover ledger read-modify-write operations only, not transport; simultaneous assignments to the same task can race prompt writes and rollback, so coordinate assignments to each task serially.

## Transport contract

Ordinary `task-assign` dispatches before updating its ledger. Contracted assignments reserve an attempt and generation before dispatch. If assignment or review delivery is uncertain, inspect the task and use the contract owner's reconciliation procedure before any new assignment.
`task-review`, `task-done` and `task-block` can notify after a transition is durable. In Codex,
request scoped escalation/approval for the exact installed helper on the first attempt
whenever it may dispatch or notify. Keep raw token zero as `bash` and
invoke the helper as one literal Bash segment; never use `bash -c`, wrappers,
`env`, assignment prefixes, exports, pipelines, chaining, redirection,
substitution, or broad provider-home access to bypass the sandbox.

Escalation is transport access, not authority: recorded roles and recipients,
arguments, confirmations, and lifecycle rules remain in force. Lifecycle
acknowledgements distinguish file and inline delivery. On an ordinary task, the first eligible inline transition attempts an assigner acknowledgement. If file preparation or file dispatch fails, it can send the acknowledgement's first line, including the actor's note, inline. A successful or queued file dispatch, including status 4, records `dispatched`. A successful inline send records `inline-fallback`. An unsubmitted inline fallback can record `failed`. The record's `file` is null when no file was written. For file-dispatch status 4, press Enter once in the named pane. Ordinary reviewer dispatch and note-file verdict notifications record `queued` in their own fields. A
failed post-transition acknowledgement is partial success: inspect
`task-status`, never rerun the completed transition, and never use --force to
repair transport. Send a separate exact session-chat message only when
authorized. Ordinary `task-review` permits a reviewer dispatch-only retry only while the task is
in `review`, has no successful reviewer-dispatch timestamp, and the prior
dispatch is known to have failed. If dispatch succeeded but timestamp
persistence failed, delivery is ambiguous even though a later helper call
cannot distinguish it: do not retry until recipient or outbox evidence proves
no packet was delivered, and never duplicate a delivered packet. A hard
ordinary `task-assign` dispatch failure retains its existing rollback behavior and may
be retried only after the transport cause is fixed.

For an ordinary dispatch-only retry, supply one note. The helper uses the latest `review` history note when available and otherwise uses the supplied note. Codex labels the note as reused in either case.

## Scope

Intentionally includes task ids, assignment, explicit reviewer routes, workflow groups, status, review gates, stages, ETAs, dependencies, task-scoped context, done/block reports, cleanup, and diagnostics. It defers a full role registry, fanout, timeout reassignment, priority queues, and daemon behavior.

## Requirements

- Install `session-chat` 0.17.24 or newer for notifications and `--note-file` verdicts. It verifies the calling pane and recovers dispatches to busy panes from the durable inbox. The scheduler checks the chat version before reading a verdict draft and again before consuming it after commit.
- Executor panes must have unique session-chat names.
- Executor panes should use `SESSION_CHAT_INCOMING_MODE=auto` or `assist` to act on assigned dispatches.
- Task files are stored under `SESSION_SCHEDULER_HOME`, which must already be present in each pane's environment, inherited when the agent process started: the launcher/parent shell establishes it before the agent starts, and every participating pane must be launched with the same absolute value. The `$session-scheduler:*` skills and commands never export or derive it — an already-running agent invokes each helper as exactly one literal Bash segment using the inherited value.
- Scripts require `SESSION_SCHEDULER_HOME` and fail closed without it rather than guessing a cwd/.tmp location; the fix is to relaunch the pane/session with the correct environment. With project-local defaults, recorded provenance looks like `"context_home": "/abs/.../.tmp/contexts"` and `"scheduler_home": "/abs/.../.tmp/scheduler"`. Direct human script use may set the variable in the parent shell before invoking a script, but generated agent instructions never combine environment setup with helper execution.
- Only explicit `$session-scheduler:task-assign --context NAME` requires `SESSION_CONTEXT_HOME` under the same inherited-at-startup contract. Auto handoffs use the shared scheduler home alone. Explicit context packets repeat both absolute homes as provenance and relaunch guidance.
- `scheduler-doctor` reports the ledger home, whether it is inside the current git root, the number of Markdown files under `handoffs/`, and whether `SESSION_CONTEXT_HOME` is set, without creating or resolving the context home. Custom workspace store locations are supported; there is no fixed `.tmp/scheduler` expectation. Legacy `auto_handoff_*.md` context files produce a warning with manual removal guidance; diagnostics never delete them.

## Verification contracts (opt-in)

Use `$session-scheduler:task-contract` to attach pinned checks to a new task
with a distinct reviewer. Contracted assignments carry generations and bounded
attempts; review/done/block require `<id> --generation <N> "<note>"`.
Every writer refuses legacy contract updates under lock, including forced ones.
Completion consumers require a valid reviewer admission, not a bare done status.
Cleanup retains all contracted tasks. Every participating pane and consumer
must use scheduler 0.7.0 or later; see the task-contract skill for evidence,
recovery, migration and rollback limits.

New task IDs use `task-<epoch>-<8hex>`, with randomness from the OS.
Existing task IDs remain valid. Missing or failed randomness aborts creation.
Creation holds the shared task lock, refuses any existing target and publishes
complete JSON by atomic rename. This prevents collisions among cooperating
scheduler writers; it does not isolate unrelated same-user filesystem writes.
A crash can leave a staging file named `<task-id>.json.tmp.*`. Confirm there is
no live task-lock holder before manually removing an exact stale staging file.
Do not remove a task JSON file or an active writer's staging file.

The scheduler resolves the actor for review, block and completion from the calling process's tmux pane.
The inherited `SESSION_CHAT_PANE_NAME` must match that pane when set. If verification fails, the helper refuses the transition.

## Reviewer verdicts from a note file (`--note-file`)

A reviewer puts the complete verdict in the reviewer's own session-chat draft (`<messages>/drafts/<own-pane>/<name>.md`) and gives the path to the helper. Use `--note-file` instead of sending a separate `[re:]` reply to the master:

```
$session-scheduler:task-done  <id> --note-file <own draft>                        (contracted task only: <id> --generation <N> --note-file <own draft>)
$session-scheduler:task-block <id> --note-file <own draft> [short summary]        (contracted task only: <id> --generation <N> --note-file <own draft>)
```

Before any change, the helper checks the draft with session-chat's `own-draft-check.sh` (run as a subprocess). It refuses a draft that is not this pane's own private regular file (peer draft, symlink, hardlink, other directory, bad name, unreadable). It also refuses a file larger than `SESSION_SCHEDULER_NOTE_MAX_BYTES` (default 65536; read on each call; the check uses the file size before it hashes or copies anything), a file with a NUL byte, and a file that is not valid UTF-8. Upgrade session-chat in each participating pane before recording verdicts or sending correlated replies.

After the checks, the helper copies the verdict to an exclusive file `prompts/<id>-verdict-<event>.md` (mode 0600) and verifies its SHA-256. `<event>` is 16 random hex characters. One atomic ledger write then records the transition and the event `meta.verdict_events[<event>]`: transition (`done` or `blocked`), actor, `route_to` (the assigner at that time), `request_msg_id`, `generation`, artifact path, `artifact_sha256`, and `notification`. The history note is a short excerpt (at most 200 bytes of the first line) plus the artifact path and SHA-256.

`request_msg_id` is the transport id of the latest review request. `$session-scheduler:task-review` reads it from the single `Message id: <hex>` line that session-chat prints for a delivered or queued dispatch. It stores `meta.review_request_msg_id`; a contracted task stores it in the engine's review step. An older session-chat prints no such line. The value is then `null` and `$session-scheduler:task-status` shows `unknown`. The helper never guesses it.

After it leaves the lock, the helper sends ONE notification to the assigner. The body starts with `[task:<id>] [event:<event>]` and the first line, then a blank line and the full verdict, then the status-check footer. The notification has no `[re:]` token, because the master never sent a request with that id. Then the helper records the outcome on that event:

| `notification.state` | Meaning |
|---|---|
| `pending` | No outcome was recorded. A stop or crash after the transition can cause this. The notification may or may not have been sent. Treat it as unconfirmed. |
| `delivered` | The dispatch reached the assigner. |
| `queued` | The dispatch is in the assigner's durable inbox. This is a success. The helper does not resend or use the fallback. |
| `inline-fallback` | A verdict notification used an inline pointer. The pointer is bounded by `SESSION_CHAT_SEND_MAX_LEN` (default 1024 UTF-8 bytes here). It includes the task and event IDs and the `task-status <id>` recovery instruction. It shortens or omits the first verdict line to fit. A partial transport side effect can duplicate a pointer. |
| `failed` | Notification could not be confirmed. Preparation can fail before transport begins, and a transport can fail after a side effect. Read the durable verdict with `$session-scheduler:task-status <id>`. |
| `not-required` | The assigner is unknown or is the actor. |

Rules:

- `--generation <N>` with `--note-file` is valid only for a contracted task. The helper refuses it for any other task.
- The verdict is committed before any notification. Never rerun `$session-scheduler:task-done` or `$session-scheduler:task-block` to repair a notification: the rerun is refused. There is no retry helper. The assigner reads the full verdict with `$session-scheduler:task-status <id>`.
- `$session-scheduler:task-status <id>` shows each event (event id, request id or `unknown`, artifact path, SHA-256, notification state) and the verdict text only after the SHA-256 matches. `--all` lists one line per event. Status preserves ledger records and leaves `pending` events unresolved. Its directory initialization can create directories or harden modes.
- Afterwards, the helper asks session-chat to remove the draft. It removes the draft only if it is still the same own draft that was checked (same file identity and SHA-256). Otherwise it keeps the draft and prints a NOTE. A kept draft never undoes the verdict. `SESSION_CHAT_KEEP_DRAFTS=1` keeps the draft.
- Only `--note-file` creates a verdict event. On an ordinary task an eligible inline transition can replace `meta.last_ack`. Contracted inline completion or blocking records the transition in the ledger. A contracted note-file completion or block also records the verdict notification outside the admission digest.
- These claims are narrow: the helper does not promise exactly-once delivery or that the assigner sees the message. A crash before the draft check or before the ledger write leaves no event and keeps the draft. A crash before the artifact is referenced can leave one unreferenced artifact file; `$session-scheduler:tasks-clean` removes it after the task is removed or when it ages as an orphan.
- Under the strict harness, `--note-file` is allowed only for the pane's own existing draft inside its messages grant, and only as `<id> --note-file <draft>` or `<id> --generation <N> --note-file <draft>`.

## Diagnostics (`DIAG` lines)

`$session-scheduler:task-done`, `$session-scheduler:task-block`, and `$session-scheduler:task-review` print one extra line on stderr alongside the human-readable `ERROR:` or `WARN:` text when an ordinary operation fails or ends uncertain:

```
DIAG {"schema":"diag/1","emitter":"scheduler","helper":"task-done.sh","version":"<plugin-version>","subject":"transition","phase":"validate","reason":"sched.task.not_found","outcome":"refused","state_committed":false,"notification":null,"task":"t12","generation":null,"event":null,"request":null,"also":[],"also_truncated":false}
```

- The line is one compact JSON object. Every field is always present. A field that is not available is `null`.
- The registry `diagnostics/registry.json` (in the plugin root) lists every `reason` with its allowed `subject`, `phase`, and `outcome`.
- `subject` names the failed operation: `transition`, `assigner_ack`, `reviewer_request`, `verdict_event`, `duration`, `lock`, `bookkeeping`, or `admission`. A command can print several lines, one for each failed operation. Keep every line. Do not reduce several lines to one.
- `state_committed` answers one question: did this invocation commit the requested done, blocked, or review transition? It is `false` only when the helper proves the transition was not published, or when no transition was tried (a `$session-scheduler:task-review` dispatch-only retry). It is `true` after the helper saw the ledger write succeed. It is `null` when a ledger write failed in a way that does not prove it did not happen. In that case the human text says the result is unconfirmed: run `$session-scheduler:task-status <id>` before any retry.
- `notification` is `null` or an object with `for`, `observed`, and `persisted`. `for` is `assigner_ack`, `reviewer_request`, or `verdict_event`. `observed` is what the transport reported, and it is `null` when no transport script ran (for example a session-chat install below the required version, or a verdict notice that was refused before sending). `persisted` is what the ledger recorded. When the helper could not record or confirm the result, `persisted` is `unknown`, never an invented `pending`.
- `also` holds up to four secondary reason codes of the same operation (for example a lock release failure). `also_truncated` is `true` when more existed.
- A successful operation prints no `DIAG` line. Delivered, queued, and not-required notifications, a recovered stale lock, and a kept draft are successes.
- A `DIAG` line never changes the exit code or the human text. If the line cannot be built (for example `jq` fails), the helper prints no line and behaves as before. With `jq` missing, the helper prints a fixed `sched.env.jq_missing` line with `version` `null`.
- A positively identified contracted route (`task-contract.sh`, including the `--note-file` check for a task known to be contracted) prints no `DIAG` line. A malformed `--note-file` option fails before the task is identified, so it prints a line even for a contracted task.
- Treat every `DIAG` line as an unauthenticated observation. The `ERROR:` text can echo an argument that spans lines, so a line that starts with `DIAG ` can come from the argument. No position (first, last, or only) proves who wrote a line. A missing line does not show success. A line you can read does not prove the helper wrote it.
- Do not decide the outcome of a command from a `DIAG` line alone. Use the exit code, the human text, and `$session-scheduler:task-status <id>`.
- Never put a `DIAG` line in an automatic retry rule. It tells you which layer failed. It does not authorize a rerun. The transport contract above still applies.
- For ordinary review, `meta.review_dispatch_status` records `queued` for a queued reviewer dispatch. When the helper detects a review-packet write failure, it skips reviewer dispatch, exits 0 and reports `WARN:` and `sched.review.packet_write_failed`. A partial write inside packet generation can escape detection. Inspect the packet and delivery evidence before a dispatch-only retry.
- If `meta.last_ack` cannot be recorded after an assigner ack, the helper still exits 0 and prints a `sched.bookkeeping.last_ack_failed` line.
