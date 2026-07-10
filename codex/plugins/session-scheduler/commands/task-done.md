---
description: Mark a scheduler task done
argument-hint: <task-id> [--force] [note]
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Run:

   ```bash
   export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
   bash "$PLUGIN_ROOT/scripts/task-done.sh" "<task-id>" "<note>"
   ```

3. Legal from `assigned` or `review` (review approval). Other transitions are rejected; `--force` overrides and records "forced" in history.
4. Records `duration_seconds` (done time minus `started_at`) when the task was assigned at some point.
5. Report that the task was marked done (and the duration if printed). If the ledger has an assigner, the script also attempts a one-line session-chat acknowledgement.
