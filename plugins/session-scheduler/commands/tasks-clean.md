---
description: Delete old finished tasks (dry-run by default; --apply to actually delete)
argument-hint: [--older-than DAYS] [--status STATUS] [--apply]
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate. Default behavior is dry-run with `--older-than 7`.

```
bash ${CLAUDE_PLUGIN_ROOT}/scripts/tasks-clean.sh $ARGUMENTS
```

Always show the dry-run output first; never auto-add `--apply`. If the user wants to delete, suggest re-running with `--apply`.
