---
description: Move an assigned scheduler task to review
argument-hint: <task-id> [--force] <note>
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Run (the note is required — typically a commit SHA or a one-line summary of what to audit):

   ```bash
   export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
   bash "$PLUGIN_ROOT/scripts/task-review.sh" "<task-id>" [--force] "<note>"
   ```

3. The executor (or orchestrator) runs this when work is ready for audit. Legal only from `assigned`; `--force` overrides and records "forced" in history.
4. If the task has a configured reviewer, the script automatically dispatches a private audit packet with the shared ledger homes and original assignment.
5. The reviewer approves with `$session-scheduler:task-done <task-id> <note>` or rejects with `$session-scheduler:task-block <task-id> <reason>`. Review state remains recorded if dispatch needs retrying.
