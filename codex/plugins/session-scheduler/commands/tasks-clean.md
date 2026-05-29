---
description: Dry-run or delete scheduler task records
argument-hint: [--older-than 7d] [--status done] [--apply]
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.1.2}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
   ```

2. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/tasks-clean.sh" $ARGUMENTS
   ```

3. Without `--apply`, report that the output is a dry run.
4. With `--apply`, report the deleted count.
