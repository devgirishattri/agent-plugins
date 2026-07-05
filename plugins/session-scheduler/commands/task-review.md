---
description: Move an assigned task to review; ack the assigner via session-chat
argument-hint: <id> [--force] <note>
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate. The note is required — typically a commit SHA or a one-line summary of what to audit.

```
export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
bash ${CLAUDE_PLUGIN_ROOT}/scripts/task-review.sh $ARGUMENTS
```

- The executor (or orchestrator) runs this when work is ready for audit. Legal only from `assigned`; `--force` overrides and records "forced" in history.
- The reviewer then approves with `/task-done <id> [note]` or rejects with `/task-block <id> <reason>`.
- The assigner gets a one-line "ready for REVIEW" ack via session-chat (best-effort).
