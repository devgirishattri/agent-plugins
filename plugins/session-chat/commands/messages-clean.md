---
description: Delete old dispatched message files (dry-run by default; pass --apply to actually delete)
argument-hint: "[--older-than DAYS] [--from NAME] [--to NAME] [--apply]"
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate. This is a destructive command — deletion is gated behind an explicit confirmation.

1. **Always run the dry-run FIRST**, regardless of whether the user passed `--apply`. Run the script with `--apply` stripped from `$ARGUMENTS`:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/messages-clean.sh <ARGUMENTS without --apply>
   ```
   Relay the dry-run output so the user sees the exact candidate files that would be deleted.

2. **If the dry-run lists zero candidates**, report that nothing matches and stop — do not prompt.

3. **If (and only if) `--apply` was in `$ARGUMENTS`** and there is at least one candidate, use **AskUserQuestion** to confirm, with options **"No, cancel" (default)** and **"Yes, delete"**. State how many files will be permanently deleted.
   - On **No/cancel** (or any non-Yes answer): report that deletion was cancelled. Do not run with `--apply`.
   - On **Yes**: re-run with `--apply` appended:
     ```
     bash ${CLAUDE_PLUGIN_ROOT}/scripts/messages-clean.sh <ARGUMENTS with --apply>
     ```
     then relay the result.

4. If `--apply` was NOT passed, this is a plain preview — after the dry-run, tell the user to re-run with `--apply` to delete (which will still prompt for confirmation). Never auto-add `--apply` yourself.
