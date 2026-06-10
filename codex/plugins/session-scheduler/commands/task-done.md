---
description: Mark a scheduler task done
argument-hint: <task-id> [--force] [note]
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.2.0}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
   ```

2. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/task-done.sh" "<task-id>" "<note>"
   ```

3. Legal from `assigned` or `review` (review approval). Other transitions are rejected; `--force` overrides and records "forced" in history.
4. Records `duration_seconds` (done time minus `started_at`) when the task was assigned at some point.
5. Report that the task was marked done (and the duration if printed). If the ledger has an assigner, the script also attempts a one-line session-chat acknowledgement.
