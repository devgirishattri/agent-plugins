---
description: Mark a task blocked; ack the assigner via session-chat
argument-hint: <id> [--force] <reason>
allowed-tools: Bash(bash:*)
---

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. The reason is required.

For a task with a verification contract (see the `task-contract` skill), pass `<id> --generation <N> "<reason>"`. The assignee passes it while the task is assigned. The reviewer passes it while the task is in review. `--force` is refused. The script sends no acknowledgement to the assigner (ledger-only).

`SESSION_SCHEDULER_HOME` must already be present in this session's environment. It is inherited when the agent process started. The pane/session launcher sets it. Never export or derive it here.

Run the helper as exactly one Bash segment. Use no `export` beforehand and no `env` or variable-assignment prefix. Chain, pipe, redirect, or substitute no other command around it:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-block.sh" $ARGUMENTS
```

If the script reports that `SESSION_SCHEDULER_HOME` is not set, stop. Stop also if your inherited value differs from the ledger home stated in your assignment. Ask the user to relaunch this pane/session with the correct environment. Do not derive another ledger.

Legal from `created`, `assigned`, or `review` (review rejection). The script rejects other transitions. `--force` overrides and records "forced" in history. To unblock, re-run `/task-assign` (blocked → assigned is legal).

Transport and escalation: after the ledger write, this helper performs nested session-chat/tmux transport. It acks the assigner with a durable file-backed dispatch first. A busy assigner gets the dispatch queued to its inbox. Inline `/send` is the last-resort fallback.

If the runtime sandboxes tmux/socket access, request scoped escalation/approval for this exact installed helper on the first attempt. The command stays one literal Bash segment. Never work around the sandbox with `bash -c`, wrappers, `env`, assignment prefixes, exports, pipelines, chaining, redirection, substitution, or broad provider-home access. Escalation is transport access, not authority. Role, recipient, argument, confirmation, and lifecycle policies remain authoritative.

Report four facts separately. First, the task state written to the ledger (`blocked`). Second, whether the ack to the assigner was Sent, Queued, or failed. Third, the ack outcome recorded in `meta.last_ack`. Fourth, whether the assigner has acted. Delivery alone is not evidence of that. Report the assigner's action as unverified unless separate evidence from the assigner exists: a correlated reply from the assigner pane, a receipt the assigner authored, or a ledger transition the assigner made. Example: "Task t12 is blocked. The ack to the assigner was queued; the assigner's action is unverified."

Partial success: if the script warns that the durable ack failed after the transition, the task is already `blocked`. Verify with `/task-status <id>`. `meta.last_ack` records the delivery outcome. The transition already succeeded, so never rerun `task-block`. Also never use --force to repair a notification. Report the partial success. Send a separate exact session-chat message to the assigner only when authorized.
