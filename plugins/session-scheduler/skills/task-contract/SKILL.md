---
name: task-contract
description: Opt-in verification contracts for scheduler tasks — attach pinned checks to a new task, verify as the executor with a receipt bound to the exact source, and admit completion only through the bound reviewer. Use when a task's completion must rest on executed, source-bound evidence rather than a done status.
---

# task-contract

A verification contract is an optional root `contract` object in an existing
scheduler task. It adds assignment generations, a bounded attempt budget,
pinned repository checks, a local receipt bound to the verified source, and a
reviewer admission. Tasks without a contract behave exactly as before. There is
no new store, status value, or approval ledger: receipts and logs live in the
task's existing `$SESSION_SCHEDULER_HOME/handoffs/<id>/` directory.

Resolve `<PLUGIN_ROOT>` from this skill's installed path: the directory two
levels above this `SKILL.md`. Substitute that absolute path literally into the
commands below. It is not a shell variable to export. Run every helper as
exactly one literal Bash segment using the inherited `SESSION_SCHEDULER_HOME`.
Never export, derive, or prefix store variables. The engine needs `python3`, `jq`, and `git`. When any of them
is missing, contracted operations fail closed with exit 2 and legacy tasks are
unaffected.

## Roles and lifecycle

1. **Attach (assigner, task still `created`).** Create the task with a distinct
   `--reviewer`, then write a spec file and attach it:

   ```bash
   bash "<PLUGIN_ROOT>/scripts/task-contract.sh" attach <id> --spec <spec.json>
   ```

   The spec is a closed JSON object:
   `{"schema_version": 1, "repository": "<absolute git root>", "checks": [{"id":
   "unit", "script": "<repo-relative .sh or .py>", "args": ["literal", ...],
   "timeout_seconds": 1-600}], "ttl_seconds": 1-86400, "max_attempts": 1-10}`.
   Check scripts must already be tracked and unchanged from `HEAD`. Attach
   pins their bytes. An executor therefore cannot alter a pinned check script.
   An orchestrator cannot introduce new code through a spec.

   Attach does not pin files that a check sources or imports (helpers,
   fixtures, config). Changing them changes the bound source digest. The
   reviewer must inspect that change.
2. **Assign (assigner).** Use the normal `/task-assign <pane> <id> <prompt>`.
   For a contracted task the scheduler hands the command to the engine. It takes
   only `pane id prompt`: context, stage, and reviewer options must already be
   task metadata before attach. Each assignment increments the generation and
   consumes one attempt. The executor must be distinct from the owner and the
   reviewer.
3. **Verify (assignee).** First show the user the exact checks and spec digest:

   ```bash
   bash "<PLUGIN_ROOT>/scripts/task-contract.sh" inspect <id>
   ```

   Then run them, binding the approved command to that digest:

   ```bash
   bash "<PLUGIN_ROOT>/scripts/task-contract.sh" verify <id> --generation <N> --spec-digest <sha256>
   ```

   Checks run with a private temporary `HOME`, no inherited store, pane, or
   credential variables, cwd set to the repository root, and their own timeout.
   This is environment isolation, not an OS or network sandbox. The receipt
   records the source (`HEAD`, tracked and untracked non-ignored file digests,
   index, spec), each check's real exit code, and log digests. A source change
   during the run makes the result `stale`, a timeout makes it `inconclusive`,
   and a nonzero exit makes it `failed`. Only `passed` can be reviewed.
4. **Review, done, block.** Use the normal commands. Give each one the
   generation and one note argument:
   - `/task-review <id> --generation <N> "<note>"` (assignee)
   - `/task-done <id> --generation <N> "<note>"` (bound reviewer only, after an
     independent review)
   - `/task-block <id> --generation <N> "<reason>"` (assignee while assigned,
     reviewer while in review)

   A report with an obsolete generation is rejected. `--force` and
   `SESSION_SCHEDULER_FORCE` never bypass a contract. Contracted done and block
   are ledger-only. Unlike the legacy commands, they send no acknowledgement to
   the assigner. The orchestrator reads the outcome with `inspect` or
   `/task-status`. Review still dispatches the review packet to the bound
   reviewer.
5. **Reconcile (assigner).** After an ambiguous delivery, an interrupted
   operation, or a block, the owner records what actually happened before any
   reassignment:

   ```bash
   bash "<PLUGIN_ROOT>/scripts/task-contract.sh" reconcile <id> --generation <N> --note "<observed outcome and recovery rationale>"
   ```

   An in-flight reservation must have expired first. Reconcile never undoes
   external effects; stop or fence the old worker before reassigning. Nothing
   is retried automatically.

## Reading the state

`inspect <id>` prints one JSON object. Its exit code gives the state:

| Exit | State | Meaning |
|---|---|---|
| 0 | `admitted` | The task is done with a reviewer admission matching the current generation. The receipt was fresh when it was admitted. |
| 1 | `active` | The task is not done yet. |
| 1 | `closed-unadmitted` | The task is done without a valid admission, for example closed by an older scheduler or a hand edit. |
| 2 | `invalid` | The contract is invalid or unavailable. |

The admission stays valid as the repository moves on. Later work does not
invalidate dependent tasks. A consumer that is about to act on the source adds
a freshness mode:

| Command | It also requires | Use as the gate before |
|---|---|---|
| `inspect <id> --fresh` | The current source and time still match the receipt. | A commit preflight. |
| `inspect <id> --committed` | A clean tree holds exactly the reviewed bytes. The check specification is unchanged. The verified base is an ancestor of `HEAD`. | Push or deployment. |

A failed freshness check reports `closed-unadmitted` for that use.

A done task cannot be reopened. When its evidence is stale or expired, create
a new task for fresh verification and review. Never rewrite an admission.

`/task-status` and `/task-board` show `CONTRACT:<state>` in the flags column.
`/task-assign` refuses to start a task whose contracted dependency is not
admitted (even with `--force`). `/scheduler-doctor` reports contracted tasks,
closed-unadmitted counts, and missing prerequisites. A `done` status alone is
closure, not acceptance.

## Under the strict-v1 harness

Attach, assign, and reconcile are orchestrator operations; verify and review
belong to the executor; done belongs to the bound reviewer; inspect is open to
every role. The harness also checks that the acting pane is the task's bound
actor. Immediately before each check runs, verify asks the selected harness
policy whether this pane could run that exact command directly, and re-checks
the pinned script. A denial, an unresolvable policy, or a stale identity stops
the verification before that check runs, so no denied check is ever executed.
Earlier checks in the same run may already have executed, and the run then
yields no passing receipt. An interrupted run leaves its reservation in place
until the owner reconciles it. Direct calls to `task-contract.sh` for a
transition are not allowed. Use the normal task commands.

## Limits

Receipts, digests, and admissions establish local consistency on this host.
They are not signatures, do not resist tampering by the same user, do not
authenticate an external CI runner, and do not authorize commit, push, merge,
or release. Pane identity outside the harness is self-asserted. A repository
containing tracked symlinks or hard-linked files cannot be bound in v1. The
assignment prompt is stored in the task JSON, where every pane that can read
the ledger can see it.

## Mixed versions, migration, and rollback

Contracts need session-scheduler 0.7.0 or later in every pane that shares the
ledger. An older copy preserves the `contract` object but can still mark the
task done. Every 0.7.0 consumer then reports it as `closed-unadmitted` and
refuses to treat it as complete, and the old copy cannot fabricate an admission.
No data migration is needed: existing tasks have no contract and are unchanged.
To roll back, finish or block contracted tasks first, and stop or fence their
workers. Never resume a contracted task with an older helper. Cleanup never
deletes a contracted task in v1, so its evidence stays in place until a later
scoped retirement feature exists.
