---
description: Delete old task files past a threshold — any status by default, narrow with --status (dry-run by default; --apply to actually delete)
argument-hint: "[--older-than DAYS] [--status STATUS] [--apply]"
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate. This is a destructive command — deletion is gated behind an explicit confirmation. Default behavior is dry-run with `--older-than 7`.

`SESSION_SCHEDULER_HOME` must already be present in this session's environment, inherited when the agent process started (the pane/session launcher sets it — never export or derive it here). Every invocation below must be exactly one Bash segment, with no `export` beforehand, no `env` or variable-assignment prefix, and no other command chained, piped, redirected, or substituted around it. If the script reports the variable is not set, stop and request that this pane/session be relaunched with the correct environment instead of deriving another ledger.

1. **Always run the dry-run FIRST**, regardless of whether the user passed `--apply`. Run the script with `--apply` stripped from `$ARGUMENTS`:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/tasks-clean.sh" <ARGUMENTS without --apply>
   ```
   Relay the dry-run output so the user sees the exact task files that would be deleted.

2. **If the dry-run lists zero candidates**, report that nothing matches and stop — do not prompt.

3. **If (and only if) `--apply` was in `$ARGUMENTS`** and there is at least one candidate, use **AskUserQuestion** to confirm, with options **"No, cancel" (default)** and **"Yes, delete"**. State how many task files will be permanently deleted.
   - On **No/cancel** (or any non-Yes answer): report that deletion was cancelled. Do not run with `--apply`.
   - On **Yes**: re-run with `--apply` appended:
     ```
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/tasks-clean.sh" <ARGUMENTS with --apply>
     ```
     then relay the result.

4. If `--apply` was NOT passed, this is a plain preview — after the dry-run, tell the user to re-run with `--apply` to delete (which will still prompt for confirmation). Never auto-add `--apply` yourself.
