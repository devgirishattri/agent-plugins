---
description: Move an assigned task to review; ack the assigner via session-chat
argument-hint: <id> [--force] <note>
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate. The note is required — typically a commit SHA or a one-line summary of what to audit.

`SESSION_SCHEDULER_HOME` must already be present in this session's environment, inherited when the agent process started (the pane/session launcher sets it — never export or derive it here). Run the helper as exactly one Bash segment, with no `export` beforehand, no `env` or variable-assignment prefix, and no other command chained, piped, redirected, or substituted around it:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-review.sh" $ARGUMENTS
```

If the script reports `SESSION_SCHEDULER_HOME` is not set — or your inherited value differs from the ledger home stated in your assignment — stop and request that this pane/session be relaunched with the correct environment instead of deriving another ledger.

- The executor (or orchestrator) runs this when work is ready for audit. Legal only from `assigned`; `--force` overrides and records "forced" in history.
- The reviewer then approves with `/task-done <id> [note]` or rejects with `/task-block <id> <reason>`.
- The assigner gets a one-line "ready for REVIEW" ack via session-chat (best-effort).
- If the task was assigned with `--reviewer PANE`, the audit request is auto-dispatched to that reviewer pane (a durable dispatch carrying the review note, the original assignment, and the absolute ledger home; recovered on the reviewer's next turn if busy). On a **hard** dispatch failure there is no `/send` downgrade — the task stays in `review` and a WARN is emitted (no silently half-delivered message); fix the issue (see `/session-chat:panes`) and re-run `/task-review`. The command output reports `routed to reviewer: …` when routing succeeds.
- Transport and escalation: after the status write this helper performs nested session-chat/tmux transport (assigner ack + reviewer dispatch). If the runtime sandboxes tmux/socket access, request scoped escalation/approval for this exact installed helper on the first attempt — the command stays one literal Bash segment, and never work around the sandbox with `bash -c`, wrappers, `env`, assignment prefixes, exports, pipelines, chaining, redirection, substitution, or broad provider-home access. Escalation is transport access, not authority: role, recipient, argument, confirmation, and lifecycle policies remain authoritative.
- Retry rule: re-running `/task-review` after a dispatch failure is a dispatch-only retry, legal only while the task is in `review` with no successful reviewer-dispatch timestamp recorded — never duplicate a delivered review packet (the script refuses), and never use --force to repair a notification.
