---
description: Mark a scheduler task blocked
argument-hint: <task-id> [--force] <reason>
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.4.0}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
   ```

2. Run:

   ```bash
   export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
   bash "$PLUGIN_ROOT/scripts/task-block.sh" "<task-id>" "<reason>"
   ```

3. Legal from `created`, `assigned`, or `review` (review rejection). Other transitions are rejected; `--force` overrides and records "forced" in history. Unblock by re-running `task-assign` (blocked → assigned is legal).
4. Report that the task was marked blocked. If the ledger has an assigner, the script also attempts a one-line session-chat acknowledgement.
