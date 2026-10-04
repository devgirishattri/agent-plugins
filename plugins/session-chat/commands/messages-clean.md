---
description: Delete old dispatched message files (dry-run by default; pass --apply to actually delete)
argument-hint: "[--older-than DAYS] [--from NAME] [--to NAME] [--apply]"
allowed-tools: Bash(bash:*)
---

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. This command is destructive. Deletion needs an explicit user confirmation.

1. **Always run the dry-run FIRST**, even when the user passed `--apply`. Run the script with `--apply` stripped from `$ARGUMENTS`:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/messages-clean.sh <ARGUMENTS without --apply>
   ```
   Relay the dry-run output. The user must see the exact candidate files that deletion would remove.

2. **If the dry-run lists zero candidates**, report that nothing matches and stop. Do not prompt.

3. **If (and only if) `--apply` was in `$ARGUMENTS`** and there is at least one candidate, use **AskUserQuestion** to confirm. Offer the options **"No, cancel" (default)** and **"Yes, delete"**. State how many files the command will delete permanently.
   - On **No/cancel** (or any non-Yes answer): report that deletion was cancelled. Do not run with `--apply`.
   - On **Yes**: re-run with `--apply` appended:
     ```
     bash ${CLAUDE_PLUGIN_ROOT}/scripts/messages-clean.sh <ARGUMENTS with --apply>
     ```
     Then relay the result.

4. If `--apply` was NOT passed, the run is a plain preview. After the dry-run, tell the user to re-run with `--apply` to delete. That run still asks for confirmation. Never add `--apply` yourself.
