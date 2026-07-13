---
description: Create a new task in the scheduler ledger
argument-hint: <name> [--meta key=value ...] [--stage NAME] [--workflow ID] [--reviewer PANE] [--depends-on id1,id2]
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate. Run the script and relay output.

`SESSION_SCHEDULER_HOME` must already be present in this session's environment, inherited when the agent process started (the pane/session launcher sets it — never export or derive it here). Run the helper as exactly one Bash segment, with no `export` beforehand, no `env` or variable-assignment prefix, and no other command chained, piped, redirected, or substituted around it:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-new.sh" $ARGUMENTS
```

If the script reports `SESSION_SCHEDULER_HOME` is not set, stop and request that this pane/session be relaunched with the correct environment instead of deriving another ledger.

Options:
- `--meta key=value` — free-form metadata (repeatable).
- `--stage NAME` — optional pipeline stage label (suggested: `plan`, `dispatch`, `execute`, `audit`, `push`; any alphanumeric/`_`/`-` label works).
- `--workflow ID` — group related tasks under a workflow id (stored as `meta.workflow_id`); list them together with `/task-status --workflow ID`.
- `--reviewer PANE` — record a reviewer pane on the task (stored as `.reviewer`); when the executor runs `/task-review`, the audit request is auto-dispatched to this pane.
- `--depends-on id1,id2` — comma-separated existing task ids this task depends on. Each id must already exist; `/task-assign` refuses to dispatch until every dependency is `done` (unless `--force`).

After creation, suggest `/task-assign <pane> <id> <prompt>` to dispatch.
