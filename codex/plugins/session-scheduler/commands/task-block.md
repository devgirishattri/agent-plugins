---
description: Mark a scheduler task blocked
argument-hint: <task-id> <reason>
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.1.2}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
   ```

2. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/task-block.sh" "<task-id>" "<reason>"
   ```

3. Report that the task was marked blocked. If the ledger has an assigner, the script also attempts a one-line session-chat acknowledgement.
