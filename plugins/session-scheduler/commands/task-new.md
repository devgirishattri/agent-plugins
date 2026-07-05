---
description: Create a new task in the scheduler ledger
argument-hint: <name> [--meta key=value ...] [--stage NAME] [--depends-on id1,id2]
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate. Run the script and relay output.

```
export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
bash ${CLAUDE_PLUGIN_ROOT}/scripts/task-new.sh $ARGUMENTS
```

Options:
- `--meta key=value` — free-form metadata (repeatable).
- `--stage NAME` — optional pipeline stage label (suggested: `plan`, `dispatch`, `execute`, `audit`, `push`; any alphanumeric/`_`/`-` label works).
- `--depends-on id1,id2` — comma-separated existing task ids this task depends on. Each id must already exist; `/task-assign` refuses to dispatch until every dependency is `done` (unless `--force`).

After creation, suggest `/task-assign <pane> <id> <prompt>` to dispatch.
