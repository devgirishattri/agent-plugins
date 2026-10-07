---
name: task-block
description: "Mark a scheduler task blocked (or reject a review) and notify the assigner when possible."
---

# Task Block

Resolve the absolute plugin root from this selected skill's installed source
path: it is the directory two levels above this `SKILL.md`. Substitute that
absolute path literally for `<PLUGIN_ROOT>` below; never infer it from the
working directory or hardcode a marketplace cache version.

`SESSION_SCHEDULER_HOME` must already be present in this pane's environment,
inherited when the agent process started (the pane/session launcher sets it —
never export or derive it here). Run exactly one Bash segment, with no `export`
beforehand, no `env` or variable-assignment prefix, and no other command
chained, piped, redirected, or substituted around it:

```bash
bash "<PLUGIN_ROOT>/scripts/task-block.sh" "<task-id>" [--force] "<reason>"
```

If the script reports `SESSION_SCHEDULER_HOME` is not set — or the inherited
value differs from the ledger home stated in your assignment — stop and request
a pane relaunch with the correct environment instead of deriving another ledger.

## Transport contract

`task-block` writes the legal `blocked` transition before its nested
session-chat/tmux notification to the assigner. In Codex, request scoped
escalation/approval for the exact installed helper on the first attempt whenever
it may notify. Invoke that helper as one literal Bash segment with raw token zero
still `bash`; never work around the sandbox with `bash -c`, a wrapper, `env`, an
assignment prefix, an export, a pipeline, chaining, redirection, substitution,
or broad provider-home access. Escalation grants transport access only; the
recorded role and recipient, exact arguments, confirmation requirements, and
lifecycle rules remain authoritative.

The lifecycle acknowledgement is a durable file-backed dispatch, queued to the
assigner's inbox when busy. The ledger remains authoritative, and
`meta.last_ack` records whether delivery was `dispatched`, used the
`inline-fallback`, or `failed`. If the helper warns that both delivery paths
failed, the task is already `blocked`: report that partial success and never rerun
the helper. Never use --force to repair an acknowledgement. Only when
authorized, send a separate exact session-chat message to the recorded
recipient.

The transition is legal from `created`, `assigned`, or `review` (review rejection).
Other transitions are rejected unless `--force`.
Unblock by re-running task-assign; blocked → assigned is legal.
Report the task ID, the observed `blocked` state, and the reason.
Report acknowledgement delivery (sent, queued, or failed) separately.
Delivery does not prove that the assigner acted.
Without evidence from the assigner, report that action as unverified.

For a task with a verification contract, read `../task-contract/SKILL.md`.
Contract assignment accepts only pane, id and one prompt. Review, done and block
require `<id> --generation <N> "<note>"`; only the bound reviewer may complete.
Force never bypasses the contract. Inspect the task first to use its generation.

Contracted inline notes remain ledger-only. The `--note-file` form below also
notifies the assigner after the transition is committed.

## Complete verdict from an own draft

Put the complete verdict in your own session-chat draft. Use one of these forms:

```bash
bash "<PLUGIN_ROOT>/scripts/task-block.sh" "<task-id>" --note-file "<own draft>"
bash "<PLUGIN_ROOT>/scripts/task-block.sh" "<task-id>" --generation <N> --note-file "<own draft>"
```

Use the generation form only for a contracted task. Preserve its actor and
admission requirements. Under strict-v1, do not combine an inline note with
`--note-file`. Follow the same scoped transport approval rule above.

The helper checks draft ownership, size, raw UTF-8 and NUL bytes before the
transition. `SESSION_SCHEDULER_NOTE_MAX_BYTES` defaults to 65536. A missing chat
read-check helper refuses this option before reading the draft; update chat.
Legacy inline notes remain compatible.

One ledger save records the transition, verdict event, artifact digest, request
linkage and initial notification state. The assigner receives one normal-path
notification carrying the complete verdict. Do not send a separate correlated
reply. Status links the request and verdict; it does not fabricate a reply row.

Report the event and notification outcome separately. `pending` means the
outcome is unconfirmed. A failed dispatch can fall back to a bounded inline
pointer; transport failure does not prove non-delivery. Never rerun the
transition to repair notification. Read the full verdict with task-status.

The helper removes the draft only after the event commits and only if its
identity and digest still match. A kept-draft note does not undo the verdict.
`SESSION_CHAT_KEEP_DRAFTS=1` retains it. Installation does not guarantee exactly
once delivery or that the assigner observes the notification.
