---
description: Remove a context snapshot (and its history) for the current project
argument-hint: "<snapshot-name>"
allowed-tools: Bash(bash:*)
---

## Instructions

Removing a snapshot is **destructive**. It deletes the snapshot AND all of its archived history versions. There is no restore path. Gate the removal behind an explicit confirmation. The script itself refuses the destructive path without a `--confirmed` capability flag. The `--dry-run` preview never deletes, so you can run it before confirmation. Only the confirmed removal is gated.

1. If `$ARGUMENTS` has no snapshot name, run `/context-list`. Ask the user which snapshot to remove. Then stop.

   `SESSION_CONTEXT_HOME` must already be present in this session's environment, inherited when the agent process started. Never export or derive it here. Make every invocation below exactly one Bash segment. Use no `export` beforehand, no `env` or variable-assignment prefix, and no other command chained, piped, redirected, or substituted around it. If the variable is unset, stop. Ask the user to relaunch this pane or session with the correct environment. Do not derive another context store.

2. **Validate, then preview.**
   - Require `<name>` to match `^[a-z0-9]+(_[a-z0-9]+)*$` before you interpolate it into any path. Reject any other value. Do not preview or remove anything.
   - Produce a point-in-time preview of exactly what the removal will delete. Use the `--dry-run` preview of the script. Do NOT pass `--confirmed` yet:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/remove-context.sh" "<name>" --dry-run
   ```
   - Relay these items to tell the user exactly which files the removal will permanently delete:
     - the listed paths (the current snapshot, if any, plus its archived history versions)
     - the orphan notice, when the helper prints one (history exists but the current snapshot is gone)
     - the "Would delete N file(s)" count
   - The dry run leaves snapshot and history files and their permissions unchanged. Store bootstrap and lock bookkeeping can still occur.
   - The confirmed run rechecks under its writer lock. A concurrent overwrite can add history after this preview. The final removal count of the confirmed run is authoritative.
   - If the dry run exits 1, relay the helper's actual error output.
     - If that output says no current or archived snapshot was found, also relay the available-snapshots list that the helper printed. Suggest `/context-list`. Stop.
     - For any other failure, relay it and stop.

3. Confirm with **AskUserQuestion**. List **"No, cancel (Recommended)" FIRST as the default**. List "Yes, delete" second. Any answer other than an explicit "Yes, delete" cancels.
   - On **No/cancel** (or any non-Yes answer): report that the removal was cancelled. Do NOT run the confirmed removal.
   - On **Yes**: run the removal with the capability flag:
     ```
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/remove-context.sh" "<name>" --confirmed
     ```
     Relay the helper's actual result line and final count. For an orphan-only removal, that is the "Removed N orphaned history file(s) for '<name>' (no current snapshot)." line.
