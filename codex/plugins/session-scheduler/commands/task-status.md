---
description: Show scheduler task status
argument-hint: [task-id|--all|--pending|--mine]
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.1.0}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
   ```

2. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/task-status.sh" $ARGUMENTS
   ```

3. Present the tab-separated output as id, status, assignee, assigner, updated time, and name.
4. Default output is active tasks; `--all` includes done and blocked tasks.
