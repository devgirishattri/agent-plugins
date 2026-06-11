---
description: Move an assigned scheduler task to review
argument-hint: <task-id> [--force] <note>
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.2.1}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
   ```

2. Run (the note is required — typically a commit SHA or a one-line summary of what to audit):

   ```bash
   bash "$PLUGIN_ROOT/scripts/task-review.sh" "<task-id>" [--force] "<note>"
   ```

3. The executor (or orchestrator) runs this when work is ready for audit. Legal only from `assigned`; `--force` overrides and records "forced" in history.
4. The reviewer then approves with `$session-scheduler:task-done <task-id> <note>` or rejects with `$session-scheduler:task-block <task-id> <reason>`.
5. Report that the task was moved to review. If the ledger has an assigner, the script also attempts a one-line session-chat acknowledgement.
