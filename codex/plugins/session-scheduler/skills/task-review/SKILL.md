---
name: task-review
description: "Move an assigned task to review and auto-dispatch its audit packet to the configured reviewer."
---

# Task Review

For an ordinary dispatch-only retry, supply a note. The helper reuses the latest stored review note when present and otherwise uses the supplied value.
The output labels the note used as `(original review note reused on retry)`.

Resolve the absolute plugin root from this selected skill's installed source
path: it is the directory two levels above this `SKILL.md`. Substitute that
absolute path literally for `<PLUGIN_ROOT>` below; never infer it from the
working directory or hardcode a marketplace cache version.

`SESSION_SCHEDULER_HOME` must already be present in this pane's environment,
inherited when the agent process started (the pane/session launcher sets it —
never export or derive it here). Run exactly one Bash segment (the note is
required — typically a commit SHA or a one-line summary of what to audit), with
no `export` beforehand, no `env` or variable-assignment prefix, and no other
command chained, piped, redirected, or substituted around it:

```bash
bash "<PLUGIN_ROOT>/scripts/task-review.sh" "<task-id>" [--force] "<note>"
```

If the script reports `SESSION_SCHEDULER_HOME` is not set — or the inherited
value differs from the ledger home stated in your assignment — stop and request
a pane relaunch with the correct environment instead of deriving another ledger.

## Transport contract

`task-review` can update the ledger and then perform nested session-chat/tmux
transport to the reviewer and, for an ordinary task, an eligible assigner. In Codex, request scoped
escalation/approval for the exact installed helper on the first attempt whenever
it may dispatch or notify. Invoke that helper as one literal Bash segment with
raw token zero still `bash`; never work around the sandbox with `bash -c`, a
wrapper, `env`, an assignment prefix, an export, a pipeline, chaining,
redirection, substitution, or broad provider-home access.

Escalation grants transport access only. The recorded role and recipient, exact
arguments, confirmation requirements, and lifecycle rules remain authoritative;
never use --force to repair transport. On an ordinary task a dispatch-only retry is legal only while
the task is already in `review`, has no successful reviewer-dispatch timestamp,
and the prior dispatch is known to have failed. If dispatch succeeded but
recording its timestamp failed, delivery is ambiguous even though the helper
cannot distinguish that state on a later call: do not retry until recipient or
outbox evidence proves no packet was delivered; never duplicate a delivered
review packet.

The executor submits review under strict-v1 enforce mode. The ordinary transition requires `assigned`. A contracted review requires the assignee, the current generation and its passing verification. Ambiguous contracted delivery requires inspection and owner reconciliation.
The packet and transport records depend on the task type.
An ordinary review routes to a distinct configured reviewer. It includes the note, shared ledger home and the original assignment when the stored prompt passes the read checks. A queued ordinary reviewer dispatch, including status 4, records `queued`. For status 4, press Enter once in the named pane. The contracted packet contains the task and generation, note, ledger path and review instructions. Its successful dispatch, including status 4, records `contract.review_delivery=delivered`. A reported contract delivery failure marks the task blocked and the phase uncertain. Inspect it and reconcile through the owner.

On an ordinary task an eligible assigner can receive a separate lifecycle acknowledgement.
`meta.last_ack` records the outcome independently of reviewer-dispatch metadata.
A contracted review dispatches to the reviewer only.
An assigner-ack failure does not undo review or authorize rerunning the transition.
Report the task state, reviewer delivery, and assigner acknowledgement separately.
Do not report work as approved merely because it entered `review`.
The reviewer approves with `$session-scheduler:task-done` or rejects with
`$session-scheduler:task-block`.

For a task with a verification contract, read `../task-contract/SKILL.md`.
Contract assignment accepts only pane, id and one prompt. Review, done and block
require `<id> --generation <N> "<note>"`; only the bound reviewer may complete.
Force never bypasses the contract. Inspect the task first to use its generation.
