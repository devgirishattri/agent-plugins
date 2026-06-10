---
description: Create a session-scheduler task
argument-hint: <name> [--meta k=v] [--stage NAME] [--depends-on id1,id2]
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.2.0}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
   ```

2. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/task-new.sh" $ARGUMENTS
   ```

3. Options:
   - `--meta k=v` — free-form metadata (repeatable).
   - `--stage NAME` — optional pipeline stage label (suggested: `plan`, `dispatch`, `execute`, `audit`, `push`).
   - `--depends-on id1,id2` — comma-separated existing task ids; `task-assign` refuses to dispatch until every dependency is `done` (unless `--force`).
4. Report the created task id, name, and stage/dependencies if set.
