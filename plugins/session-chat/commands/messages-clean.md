---
description: Delete old dispatched message files (dry-run by default; pass --apply to actually delete)
argument-hint: [--older-than DAYS] [--from NAME] [--to NAME] [--apply]
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate. Run the script and relay its output.

```
bash ${CLAUDE_PLUGIN_ROOT}/scripts/messages-clean.sh $ARGUMENTS
```

- Default behavior is dry-run with `--older-than 7`. Always show the dry-run output first.
- If the user wants to actually delete, suggest re-running with `--apply`.
- Never auto-add `--apply`. Even if the user says "clean them", show the dry-run, then ask.
