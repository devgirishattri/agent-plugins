---
description: Create a session-scheduler task
argument-hint: <name> [--meta k=v] [--stage NAME] [--depends-on id1,id2] [--reviewer PANE] [--workflow ID]
---

## Instructions

1. Resolve the absolute plugin root from the installed plugin source containing
   this command reference and substitute it literally for `<PLUGIN_ROOT>` below.
   Do not infer it from cwd or hardcode a cache version.

2. `SESSION_SCHEDULER_HOME` must already be present in this pane's environment,
   inherited when the agent process started (the pane/session launcher sets it —
   never export or derive it here). Run exactly one Bash segment, with no
   `export` beforehand, no `env` or variable-assignment prefix, and no other
   command chained, piped, redirected, or substituted around it:

   ```bash
   bash "<PLUGIN_ROOT>/scripts/task-new.sh" $ARGUMENTS
   ```

   If the script reports `SESSION_SCHEDULER_HOME` is not set, stop and request
   that this pane be relaunched with the correct environment instead of
   deriving another ledger.

3. Options:
   - `--meta k=v` — free-form metadata (repeatable).
   - `--stage NAME` — optional pipeline stage label (suggested: `plan`, `dispatch`, `execute`, `audit`, `push`).
   - `--depends-on id1,id2` — comma-separated existing task ids; `task-assign` refuses to dispatch until every dependency is `done` (unless `--force`).
   - `--reviewer PANE` — independent reviewer automatically dispatched by `task-review`.
   - `--workflow ID` — workflow group; `--workflow-id` is an alias.
4. Report the created task id, name, and stage/dependencies if set.
