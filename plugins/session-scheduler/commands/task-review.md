---
description: Move an assigned task to review; ack the assigner via session-chat
argument-hint: <id> [--force] <note>
allowed-tools: Bash(bash:*)
---

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. The note is required. Use a commit SHA or a one-line summary of what to audit.

For a task with a verification contract (see the `task-contract` skill), pass `<id> --generation <N> "<note>"` as the assignee. Do this only after a passing `task-contract.sh verify`. `--force` is refused.

`SESSION_SCHEDULER_HOME` must already be present in this session's environment. It is inherited when the agent process started. The pane/session launcher sets it. Never export or derive it here.

Run the helper as exactly one Bash segment. Use no `export` beforehand and no `env` or variable-assignment prefix. Chain, pipe, redirect, or substitute no other command around it:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-review.sh" $ARGUMENTS
```

If the script reports that `SESSION_SCHEDULER_HOME` is not set, stop. Stop also if your inherited value differs from the ledger home stated in your assignment. Ask the user to relaunch this pane/session with the correct environment. Do not derive another ledger.

- The executor (or orchestrator) runs this when work is ready for audit. Legal only from `assigned`. `--force` overrides and records "forced" in history.
- The reviewer then approves with `/task-done <id> [note]` or rejects with `/task-block <id> <reason>`.
- The assigner gets a one-line "ready for REVIEW" ack. It uses the same durable delivery ladder as `/task-done` and `/task-block`. File-backed dispatch goes first, and a busy assigner gets it queued to its inbox. Inline `/send` is the last-resort fallback. `meta.last_ack` records the outcome. The script sends the ack only the first time the task moves into `review`. A retry (below) never resends it. The ack is independent of reviewer routing. If the ack fails completely, the script emits a WARN, reviewer routing still proceeds, and the task stays in `review`. Never rerun the transition to repair the notification.
- If the task was assigned with `--reviewer PANE`, the script auto-dispatches the audit request to that reviewer pane. The dispatch is durable. It carries the review note, the original assignment, and the absolute ledger home. A busy reviewer recovers it on its next turn. The command output reports `routed to reviewer: …` when routing succeeds. On a **hard** dispatch failure there is no `/send` downgrade. The task stays in `review` and the script emits a WARN. It never half-delivers a message silently. Fix the cause (see `/session-chat:panes`), then re-run `/task-review`.
- Transport and escalation: after the status write, this helper performs nested session-chat/tmux transport (assigner ack and reviewer dispatch). If the runtime sandboxes tmux/socket access, request scoped escalation/approval for this exact installed helper on the first attempt. The command stays one literal Bash segment. Never work around the sandbox with `bash -c`, wrappers, `env`, assignment prefixes, exports, pipelines, chaining, redirection, substitution, or broad provider-home access. Escalation is transport access, not authority. Role, recipient, argument, confirmation, and lifecycle policies remain authoritative.
- Report four facts separately. First, the task state written to the ledger (`review`). Second, whether the ack to the assigner and the dispatch to the reviewer were Sent, Queued, or failed. Third, the ack outcome recorded in `meta.last_ack`. Fourth, whether the reviewer has acted. Delivery alone is not evidence of that. Only evidence from the reviewer counts: a correlated reply from the reviewer pane, a receipt the reviewer authored, or a ledger transition the reviewer made (for example, done or blocked by the bound reviewer). A transition by the executor proves only that the executor acted. Otherwise report the reviewer's action as unverified. Example: "Task t12 is in review. The dispatch to the reviewer was queued; the reviewer's action is unverified."
- Retry rule: re-running `/task-review` after a dispatch failure is a dispatch-only retry. It is legal only while the task is in `review` with no successful reviewer-dispatch timestamp recorded. The script refuses to resend a delivered review packet, so never duplicate one. Never use --force to repair a notification. A retry re-sends the **original** review note: the one recorded in history when the task entered review, e.g. the commit SHA. The note typed on the retry is syntactically required but ignored. The output says `(original review note reused on retry)`.
