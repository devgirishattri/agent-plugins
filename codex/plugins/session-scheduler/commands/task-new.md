---
description: Create a session-scheduler task
argument-hint: <name> [--meta k=v] [--stage NAME] [--depends-on id1,id2] [--reviewer PANE] [--workflow ID]
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Run:

   ```bash
   export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
   bash "$PLUGIN_ROOT/scripts/task-new.sh" $ARGUMENTS
   ```

3. Options:
   - `--meta k=v` — free-form metadata (repeatable).
   - `--stage NAME` — optional pipeline stage label (suggested: `plan`, `dispatch`, `execute`, `audit`, `push`).
   - `--depends-on id1,id2` — comma-separated existing task ids; `task-assign` refuses to dispatch until every dependency is `done` (unless `--force`).
   - `--reviewer PANE` — independent reviewer automatically dispatched by `task-review`.
   - `--workflow ID` — workflow group; `--workflow-id` is an alias.
4. Report the created task id, name, and stage/dependencies if set.
