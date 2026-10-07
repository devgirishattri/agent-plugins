---
description: Create a new task in the scheduler ledger
argument-hint: <name> [--meta key=value ...] [--stage NAME] [--workflow ID] [--reviewer PANE] [--depends-on id1,id2]
allowed-tools: Bash(bash:*)
---

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. Run the script and relay its output.

`SESSION_SCHEDULER_HOME` must already be present in this session's environment. It is inherited when the agent process started. The pane/session launcher sets it. Never export or derive it here.

Run the helper as exactly one Bash segment. Use no `export` beforehand and no `env` or variable-assignment prefix. Chain, pipe, redirect, or substitute no other command around it:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-new.sh" $ARGUMENTS
```

If the script reports that `SESSION_SCHEDULER_HOME` is not set, stop. Ask the user to relaunch this pane/session with the correct environment. Do not derive another ledger.

Options:
- `--meta key=value` — free-form metadata (repeatable).
- `--stage NAME` — optional pipeline stage label. Suggested labels: `plan`, `dispatch`, `execute`, `audit`, `push`. Any alphanumeric/`_`/`-` label works.
- `--workflow ID` — group related tasks under a workflow id (stored as `meta.workflow_id`); list them together with `/task-status --workflow ID`.
- `--reviewer PANE` — record a reviewer pane on the task (stored as `.reviewer`). When the executor runs `/task-review`, the audit request is auto-dispatched to this pane.
- `--depends-on id1,id2` — comma-separated existing task ids this task depends on. Each id must already exist. `/task-assign` refuses to dispatch until every dependency is `done`, unless `--force` is set.

The new task id has the form `task-<epoch>-<8 hex>`. The hex comes from `/dev/urandom` only; with no usable `od`/`/dev/urandom` the command stops with an error and creates nothing. The ledger file is created exclusively, so a colliding id is refused and the existing task stays unchanged. Older bare 8-hex ids remain valid everywhere.

After creation, report the new task id first. Then suggest `/task-assign <pane> <id> <prompt>` to dispatch.
