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
