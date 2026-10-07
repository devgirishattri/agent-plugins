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

- First assignment stamps `started_at`; `task-done` records `duration_seconds`.
- `--eta MINUTES` on assign stores `eta_at`; overdue tasks are flagged `OVERDUE`. Tasks in `assigned`/`review` with no update for `SESSION_SCHEDULER_STALE_MINUTES` (default 30) are flagged `STALE`.
- Stages are optional free-form labels (suggested pipeline: `plan`, `dispatch`, `execute`, `audit`, `push`); view grouped output with `task-status --by-stage` or `task-board`.
- `--depends-on` gates assignment until every dependency is `done`.
- `--context NAME` attaches an existing canonical knowledge context snapshot (lowercase snake_case matching `^[a-z0-9]+(_[a-z0-9]+)*$`). `--context auto` writes `$SESSION_SCHEDULER_HOME/handoffs/<task-id>/<nonce>.md` from the approved prompt and ledger state, with no live-session summarization. Its nonce is 32 lowercase hex characters from OS randomness. Each file is never overwritten; an existing path is refused. Directories use 0700 and files use 0600, with symlink and ownership checks. The packet carries the absolute path for direct reading, not knowledge context-load commands.
- `--reviewer PANE` stores the independent reviewer route. When the executor calls `task-review`, the scheduler automatically dispatches the audit packet to that pane. A hard delivery failure leaves the task in review and must be retried with `task-review`; there is no one-line send downgrade.
- `--workflow ID` groups related tasks in canonical `meta.workflow_id`; `--workflow-id` remains an alias. `task-status --by-workflow` shows each complete workflow arc, including done steps, while omitting tasks without a workflow id; `--workflow ID` filters one workflow.
- Every assignment records and embeds the absolute scheduler home; explicit `--context NAME` also records the context home. Auto records `meta.handoff_file` and `meta.handoff_home` and clears prior context keys; explicit NAME records `meta.context` and `meta.context_home` and clears prior handoff keys. Auto never requires, reads, creates, or resolves `SESSION_CONTEXT_HOME`.
- Eligible `done`, `blocked`, and `review` transitions write lifecycle acknowledgement files and dispatch them durably to the assigner. Busy assigners receive them from the queued inbox; the ledger remains authoritative, and `meta.last_ack` records the event, target, delivery outcome, timestamp, and file.
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
The `pid` file records its holder. Atomic directory creation coordinates both providers.
Acquisition waits up to `SESSION_SCHEDULER_LOCK_TIMEOUT_SECS` (default 10).
A timeout names the lock path. The helper reclaims a lock only when its holder is verified dead.
Permission-denied PID checks count as alive.
The private `locks/` directory is outside the vetted content subtrees.
Assignment metadata and status form one locked mutation. New tasks are written atomically.

Reassignment without `--context` clears all four attachment keys: `meta.context`, `meta.context_home`, `meta.handoff_file`, and `meta.handoff_home`. Locks cover ledger read-modify-write operations only, not transport; simultaneous assignments to the same task can race prompt writes and rollback, so coordinate assignments to each task serially.

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
arguments, confirmations, and lifecycle rules remain in force. Lifecycle
acknowledgements are durable file-backed dispatches, queued to the assigner's
inbox when busy, with inline send retained only as a last-resort fallback. The
ledger remains authoritative and `meta.last_ack` records delivery outcome. A
failed post-transition acknowledgement is partial success: inspect
`task-status`, never rerun the completed transition, and never use --force to
repair transport. Send a separate exact session-chat message only when
authorized. `task-review` permits a reviewer dispatch-only retry only while the task is
in `review`, has no successful reviewer-dispatch timestamp, and the prior
dispatch is known to have failed. If dispatch succeeded but timestamp
persistence failed, delivery is ambiguous even though a later helper call
cannot distinguish it: do not retry until recipient or outbox evidence proves
no packet was delivered, and never duplicate a delivered packet. A hard
`task-assign` dispatch failure retains its existing rollback behavior and may
be retried only after the transport cause is fixed.

A reviewer dispatch-only retry reuses the note from the latest `review` history event. The CLI note remains required but is ignored on retry; output identifies the original note as reused.

## Scope

Intentionally includes task ids, assignment, explicit reviewer routes, workflow groups, status, review gates, stages, ETAs, dependencies, task-scoped context, done/block reports, cleanup, and diagnostics. It defers a full role registry, fanout, timeout reassignment, priority queues, and daemon behavior.

## Requirements

- `session-chat` 0.13.0 or newer must be available. Its durable inbox means a dispatch or ack to a busy pane is recovered on that pane's next turn rather than lost.
- Executor panes must have unique session-chat names.
- Executor panes should use `SESSION_CHAT_INCOMING_MODE=auto` or `assist` to act on assigned dispatches.
- Task files are stored under `SESSION_SCHEDULER_HOME`, which must already be present in each pane's environment, inherited when the agent process started: the launcher/parent shell establishes it before the agent starts, and every participating pane must be launched with the same absolute value. The `$session-scheduler:*` skills and commands never export or derive it — an already-running agent invokes each helper as exactly one literal Bash segment using the inherited value.
- Scripts require `SESSION_SCHEDULER_HOME` and fail closed without it rather than guessing a cwd/.tmp location; the fix is to relaunch the pane/session with the correct environment. With project-local defaults, recorded provenance looks like `"context_home": "/abs/.../.tmp/contexts"` and `"scheduler_home": "/abs/.../.tmp/scheduler"`. Direct human script use may set the variable in the parent shell before invoking a script, but generated agent instructions never combine environment setup with helper execution.
- Only explicit `$session-scheduler:task-assign --context NAME` requires `SESSION_CONTEXT_HOME` under the same inherited-at-startup contract. Auto handoffs use the shared scheduler home alone. Explicit context packets repeat both absolute homes as provenance and relaunch guidance.
- `scheduler-doctor` reports the ledger home, whether it is inside the current git root, the handoffs directory count, and whether `SESSION_CONTEXT_HOME` is set, without creating or resolving the context home. Custom workspace store locations are supported; there is no fixed `.tmp/scheduler` expectation. Legacy `auto_handoff_*.md` context files produce a warning with manual removal guidance; diagnostics never delete them.

## Verification contracts (opt-in, 0.7.0)

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

## Reviewer verdicts from a note file (`--note-file`)

A reviewer puts the complete verdict in the reviewer's own session-chat draft (`<messages>/drafts/<own-pane>/<name>.md`) and gives the path to the helper. Use `--note-file` instead of sending a separate `[re:]` reply to the master:

```
$session-scheduler:task-done  <id> --note-file <own draft>                        (contracted task only: <id> --generation <N> --note-file <own draft>)
$session-scheduler:task-block <id> --note-file <own draft> [short summary]        (contracted task only: <id> --generation <N> --note-file <own draft>)
```

Before any change, the helper checks the draft with session-chat's `own-draft-check.sh` (run as a subprocess). It refuses a draft that is not this pane's own private regular file (peer draft, symlink, hardlink, other directory, bad name, unreadable). It also refuses a file larger than `SESSION_SCHEDULER_NOTE_MAX_BYTES` (default 65536; read on each call; the check uses the file size before it hashes or copies anything), a file with a NUL byte, and a file that is not valid UTF-8. An older session-chat with no `own-draft-check.sh` makes the helper refuse `--note-file` with an upgrade message before it reads the file. Inline notes still work with an older session-chat.

After the checks, the helper copies the verdict to an exclusive file `prompts/<id>-verdict-<event>.md` (mode 0600) and verifies its SHA-256. `<event>` is 16 random hex characters. One atomic ledger write then records the transition and the event `meta.verdict_events[<event>]`: transition (`done` or `blocked`), actor, `route_to` (the assigner at that time), `request_msg_id`, `generation`, artifact path, `artifact_sha256`, and `notification`. The history note is a short excerpt (at most 200 bytes of the first line) plus the artifact path and SHA-256.

`request_msg_id` is the transport id of the latest review request. `$session-scheduler:task-review` reads it from the single `Message id: <hex>` line that session-chat prints for a delivered or queued dispatch. It stores `meta.review_request_msg_id`; a contracted task stores it in the engine's review step. An older session-chat prints no such line. The value is then `null` and `$session-scheduler:task-status` shows `unknown`. The helper never guesses it.

After it leaves the lock, the helper sends ONE notification to the assigner. The body starts with `[task:<id>] [event:<event>]` and the first line, then a blank line and the full verdict, then the status-check footer. The notification has no `[re:]` token, because the master never sent a request with that id. Then the helper records the outcome on that event:

| `notification.state` | Meaning |
|---|---|
| `pending` | No outcome was recorded. A stop or crash after the transition can cause this. The notification may or may not have been sent. Treat it as unconfirmed. |
| `delivered` | The dispatch reached the assigner. |
| `queued` | The dispatch is in the assigner's durable inbox. This is a success. The helper does not resend or use the fallback. |
| `inline-fallback` | The dispatch failed hard. The helper sent one inline pointer of at most `SESSION_CHAT_SEND_MAX_LEN` (default 1024) characters: `[task:<id>] [event:<event>] <first line> — full verdict recorded: task-status <id>`. A partial transport side effect can cause a duplicate pointer. |
| `failed` | Both transports reported failure. Delivery is not confirmed (a transport can fail after a side effect). The verdict artifact is durable; the assigner reads it with `$session-scheduler:task-status <id>`. |
| `not-required` | The assigner is unknown or is the actor. |

Rules:

- `--generation <N>` with `--note-file` is valid only for a contracted task. The helper refuses it for any other task.
- The verdict is committed before any notification. Never rerun `$session-scheduler:task-done` or `$session-scheduler:task-block` to repair a notification: the rerun is refused. There is no retry helper. The assigner reads the full verdict with `$session-scheduler:task-status <id>`.
- `$session-scheduler:task-status <id>` shows each event (event id, request id or `unknown`, artifact path, SHA-256, notification state) and the verdict text only after the SHA-256 matches. `--all` lists one line per event. Status never writes and never reconciles a `pending` event.
- Afterwards, the helper asks session-chat to remove the draft. It removes the draft only if it is still the same own draft that was checked (same file identity and SHA-256). Otherwise it keeps the draft and prints a NOTE. A kept draft never undoes the verdict. `SESSION_CHAT_KEEP_DRAFTS=1` keeps the draft.
- Only the `--note-file` forms create events. An inline note keeps the lifecycle ack (`meta.last_ack`) unchanged. For a contracted task, `--note-file` also sends the notification; the notification record is kept outside the history that the admission digest covers.
- These claims are narrow: the helper does not promise exactly-once delivery or that the assigner sees the message. A crash before the draft check or before the ledger write leaves no event and keeps the draft. A crash before the artifact is referenced can leave one unreferenced artifact file; `$session-scheduler:tasks-clean` removes it after the task is removed or when it ages as an orphan.
- Under the strict harness, `--note-file` is allowed only for the pane's own existing draft inside its messages grant, and only as `<id> --note-file <draft>` or `<id> --generation <N> --note-file <draft>`.

## Diagnostics (`DIAG` lines)

`$session-scheduler:task-done`, `$session-scheduler:task-block`, and `$session-scheduler:task-review` print one extra line on stderr after the existing `ERROR:` or `WARN:` text when an ordinary operation fails or ends uncertain:

```
DIAG {"schema":"diag/1","emitter":"scheduler","helper":"task-done.sh","version":"0.7.6","subject":"transition","phase":"validate","reason":"sched.task.not_found","outcome":"refused","state_committed":false,"notification":null,"task":"t12","generation":null,"event":null,"request":null,"also":[],"also_truncated":false}
```

- The line is one compact JSON object. Every field is always present. A field that is not available is `null`.
- The registry `diagnostics/registry.json` (in the plugin root) lists every `reason` with its allowed `subject`, `phase`, and `outcome`.
- `subject` names the failed operation: `transition`, `assigner_ack`, `reviewer_request`, `verdict_event`, `duration`, `lock`, `bookkeeping`, or `admission`. A command can print several lines, one for each failed operation. Keep every line. Do not reduce several lines to one.
- `state_committed` answers one question: did this invocation commit the requested done, blocked, or review transition? It is `false` only when the helper proves the transition was not published, or when no transition was tried (a `$session-scheduler:task-review` dispatch-only retry). It is `true` after the helper saw the ledger write succeed. It is `null` when a ledger write failed in a way that does not prove it did not happen. In that case the human text says the result is unconfirmed: run `$session-scheduler:task-status <id>` before any retry.
- `notification` is `null` or an object with `for`, `observed`, and `persisted`. `for` is `assigner_ack`, `reviewer_request`, or `verdict_event`. `observed` is what the transport reported, and it is `null` when no transport script ran (for example a session-chat install below the required version, or a verdict notice that was refused before sending). `persisted` is what the ledger recorded. When the helper could not record or confirm the result, `persisted` is `unknown`, never an invented `pending`.
- `also` holds up to four secondary reason codes of the same operation (for example a lock release failure). `also_truncated` is `true` when more existed.
- A successful operation prints no `DIAG` line. Delivered, queued, and not-required notifications, a recovered stale lock, and a kept draft are successes.
- A `DIAG` line never changes the exit code or the human text. If the line cannot be built (for example `jq` fails), the helper prints no line and behaves as before. With `jq` missing, the helper prints a fixed `sched.env.jq_missing` line with `version` `null`.
- A positively identified contracted route (`task-contract.sh`, including the `--note-file` check for a task known to be contracted) prints no `DIAG` line in this version. A malformed `--note-file` option fails before the task is identified, so it prints a line even for a contracted task.
- Treat every `DIAG` line as an unauthenticated observation. The `ERROR:` text can echo an argument that spans lines, so a line that starts with `DIAG ` can come from the argument. No position (first, last, or only) proves who wrote a line. A missing line does not show success. A line you can read does not prove the helper wrote it.
- Do not decide the outcome of a command from a `DIAG` line alone. Use the exit code, the human text, and `$session-scheduler:task-status <id>`.
- Never put a `DIAG` line in an automatic retry rule. It tells you which layer failed. It does not authorize a rerun. The transport contract above still applies.
- `$session-scheduler:task-review` records a reviewer dispatch that the transport queued as `queued` in `meta.review_dispatch_status`. If it cannot write the review packet, it sends no reviewer dispatch, exits 0, prints a `WARN:` line and a `sched.review.packet_write_failed` line. Do not replay the transition. After you fix the cause, run `$session-scheduler:task-review` again: it retries the reviewer dispatch only.
- If `meta.last_ack` cannot be recorded after an assigner ack, the helper still exits 0 and prints a `sched.bookkeeping.last_ack_failed` line.
