---
description: Create a new task in the scheduler ledger
argument-hint: <name> [--meta key=value ...]
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate. Run the script and relay output.

```
bash ${CLAUDE_PLUGIN_ROOT}/scripts/task-new.sh $ARGUMENTS
```

After creation, suggest `/task-assign <pane> <id> <prompt>` to dispatch.
