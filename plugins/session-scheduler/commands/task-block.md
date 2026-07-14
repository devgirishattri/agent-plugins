---
description: Mark a task blocked; ack the assigner via session-chat
argument-hint: <id> [--force] <reason>
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate. The reason is required.

`SESSION_SCHEDULER_HOME` must already be present in this session's environment, inherited when the agent process started (the pane/session launcher sets it — never export or derive it here). Run the helper as exactly one Bash segment, with no `export` beforehand, no `env` or variable-assignment prefix, and no other command chained, piped, redirected, or substituted around it:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-block.sh" $ARGUMENTS
```

If the script reports `SESSION_SCHEDULER_HOME` is not set — or your inherited value differs from the ledger home stated in your assignment — stop and request that this pane/session be relaunched with the correct environment instead of deriving another ledger.

Legal from `created`, `assigned`, or `review` (review rejection). Other transitions are rejected; `--force` overrides and records "forced" in history. Unblock by re-running `/task-assign` (blocked → assigned is legal).

Transport and escalation: after the ledger write this helper performs nested session-chat/tmux transport (it notifies the assigner). If the runtime sandboxes tmux/socket access, request scoped escalation/approval for this exact installed helper on the first attempt — the command stays one literal Bash segment, and never work around the sandbox with `bash -c`, wrappers, `env`, assignment prefixes, exports, pipelines, chaining, redirection, substitution, or broad provider-home access. Escalation is transport access, not authority: role, recipient, argument, confirmation, and lifecycle policies remain authoritative.

Partial success: if the script warns that the notification failed after the transition, the task is already `blocked` (verify with `/task-status <id>`) — never rerun `task-block`, and never use --force to repair a notification. Report the partial success; only when authorized, send a separate exact session-chat message to the assigner.
