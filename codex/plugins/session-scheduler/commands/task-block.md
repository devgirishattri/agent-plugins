---
description: Mark a scheduler task blocked
argument-hint: <task-id> [--force] <reason>
---

## Instructions

1. Resolve the absolute plugin root from the installed plugin source containing
   this command reference and substitute it literally for `<PLUGIN_ROOT>` below.
   Do not infer it from cwd or hardcode a cache version.

2. `SESSION_SCHEDULER_HOME` must already be present in this pane's environment,
   inherited when the agent process started (the pane/session launcher sets it —
   never export or derive it here). Run exactly one Bash segment, with no
   `export` beforehand, no `env` or variable-assignment prefix, and no other
   command chained, piped, redirected, or substituted around it:

   ```bash
   bash "<PLUGIN_ROOT>/scripts/task-block.sh" "<task-id>" [--force] "<reason>"
   ```

   If the script reports `SESSION_SCHEDULER_HOME` is not set — or the inherited
   value differs from the ledger home stated in your assignment — stop and
   request that this pane be relaunched with the correct environment instead of
   deriving another ledger.

3. Legal from `created`, `assigned`, or `review` (review rejection). Other transitions are rejected; `--force` overrides and records "forced" in history. Unblock by re-running `task-assign` (blocked → assigned is legal).
4. Report that the task was marked blocked. If the ledger has an assigner, the script also attempts a one-line session-chat acknowledgement.
