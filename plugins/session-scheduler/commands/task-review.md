---
description: Move an assigned task to review; route its audit packet to the reviewer
argument-hint: <id> [--force] <note>
allowed-tools: Bash(bash:*)
---

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. The note is required. Use a commit SHA or a one-line summary of what to audit.

When the work included a consequential choice, write the decision, its reason, the evidence and the observed result in the same single-line note. See "Decision notes" in the `session-scheduler` skill. Pass a note that the user supplied verbatim.

**Draft or submit.** Decide this before you run anything. If the user asked only to draft, write, or show a review note, do not run the helper. Show the note and stop. Run the helper below only when the user asks to move the task to review.

For a task with a verification contract (see the `task-contract` skill), pass `<id> --generation <N> "<note>"` as the assignee. Do this only after a passing `task-contract.sh verify`. `--force` is refused.

`SESSION_SCHEDULER_HOME` must already be present in this session's environment. It is inherited when the agent process started. The pane/session launcher sets it. Never export or derive it here.

Run the helper as exactly one Bash segment. Use no `export` beforehand and no `env` or variable-assignment prefix. Chain, pipe, redirect, or substitute no other command around it:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-review.sh" $ARGUMENTS
```

If the script reports that `SESSION_SCHEDULER_HOME` is not set, stop. Stop also if your inherited value differs from the ledger home stated in your assignment. Ask the user to relaunch this pane/session with the correct environment. Do not derive another ledger.

- Within strict-v1 enforce mode, only the executor may submit review. Ordinary transition and force rules apply to tasks without a verification contract.
- For ordinary reviews the reviewer approves with `/task-done <id> [note]` or rejects with `/task-block <id> <reason>`. A contracted reviewer must pass the current `--generation <N>` after the task ID and provide the approval note or rejection reason.
- On an ordinary task, an eligible assigner gets a one-line "ready for REVIEW" ack. It uses the same durable delivery ladder as `/task-done` and `/task-block`. File-backed dispatch goes first, and a busy assigner gets it queued to its inbox. Inline `/send` is the last-resort fallback. `meta.last_ack` records the outcome. The script sends the ack only the first time the task moves into `review`. A retry (below) never resends it. The ack is independent of reviewer routing. If the ack fails completely, the script emits a WARN, reviewer routing still proceeds, and the task stays in `review`. Never rerun the transition to repair the notification.
- An ordinary review routes to a distinct configured reviewer. It includes the note, shared ledger home and the original assignment when the stored prompt passes the read checks. A queued ordinary reviewer dispatch, including status 4, records `queued`. For status 4, press Enter once in the named pane. The contracted packet contains the task and generation, note, ledger path and review instructions. Its successful dispatch, including status 4, records `contract.review_delivery=delivered`. A reported contract delivery failure marks the task blocked and the phase uncertain. Inspect it and reconcile through the owner.
- Transport and escalation: after the status write, this helper performs nested session-chat/tmux transport (ordinary assigner ack and reviewer dispatch, or reviewer dispatch only for a contracted task). If the runtime sandboxes tmux/socket access, request scoped escalation/approval for this exact installed helper on the first attempt. The command stays one literal Bash segment. Never work around the sandbox with `bash -c`, wrappers, `env`, assignment prefixes, exports, pipelines, chaining, redirection, substitution, or broad provider-home access. Escalation is transport access, not authority. Role, recipient, argument, confirmation, and lifecycle policies remain authoritative.
- Report the actual ledger state, reviewer transport outcome, and any ordinary assigner acknowledgement separately. Verify the reviewer's action through a correlated reply, their receipt or a ledger transition by the bound reviewer. Otherwise report their action as unverified.
- For an ordinary task in `review`, a missing successful dispatch timestamp can also mean delivery succeeded and the timestamp write failed. Check the recipient or outbox before retrying and never duplicate a delivered packet. A dispatch-only retry uses the latest stored review note when present, and the supplied note otherwise. Claude prints `(original review note reused on retry)` only when it actually reuses a stored note. Never use --force to repair a notification. For contracted review, inspect and reconcile an uncertain outcome through the owner.
