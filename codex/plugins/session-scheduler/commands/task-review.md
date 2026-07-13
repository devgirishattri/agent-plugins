---
description: Move an assigned scheduler task to review
argument-hint: <task-id> [--force] <note>
---

## Instructions

1. Resolve the absolute plugin root from the installed plugin source containing
   this command reference and substitute it literally for `<PLUGIN_ROOT>` below.
   Do not infer it from cwd or hardcode a cache version.

2. `SESSION_SCHEDULER_HOME` must already be present in this pane's environment,
   inherited when the agent process started (the pane/session launcher sets it —
   never export or derive it here). Run exactly one Bash segment (the note is
   required — typically a commit SHA or a one-line summary of what to audit),
   with no `export` beforehand, no `env` or variable-assignment prefix, and no
   other command chained, piped, redirected, or substituted around it:

   ```bash
   bash "<PLUGIN_ROOT>/scripts/task-review.sh" "<task-id>" [--force] "<note>"
   ```

   If the script reports `SESSION_SCHEDULER_HOME` is not set — or the inherited
   value differs from the ledger home stated in your assignment — stop and
   request that this pane be relaunched with the correct environment instead of
   deriving another ledger.

3. The executor (or orchestrator) runs this when work is ready for audit. Legal only from `assigned`; `--force` overrides and records "forced" in history.
4. If the task has a configured reviewer, the script automatically dispatches a private audit packet with the shared ledger homes and original assignment. On hard dispatch failure, the task stays in `review` and the script warns; there is no one-line send downgrade, so fix the target and rerun `task-review`.
5. The reviewer approves with `$session-scheduler:task-done <task-id> <note>` or rejects with `$session-scheduler:task-block <task-id> <reason>`. Review state remains recorded if dispatch needs retrying.
