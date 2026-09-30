---
description: Remove a context snapshot (and its history) for the current project
argument-hint: "<snapshot-name>"
allowed-tools: Bash(bash:*)
---

## Instructions

Removing a snapshot is **destructive** — it deletes the snapshot AND all of its archived history versions, with no restore path. Gate it behind an explicit confirmation; the script itself refuses the destructive path without a `--confirmed` capability flag. The `--dry-run` preview never deletes, so it is allowed before confirmation; only the confirmed removal is gated.

1. If no snapshot name was given in `$ARGUMENTS`, run `/context-list` and ask the user which snapshot to remove; then stop.

   `SESSION_CONTEXT_HOME` must already be present in this session's environment, inherited when the agent process started (never export or derive it here). Every invocation below must be exactly one Bash segment, with no `export` beforehand, no `env` or variable-assignment prefix, and no other command chained, piped, redirected, or substituted around it. If it is unset, stop and request that this pane/session be relaunched with the correct environment instead of deriving another context store.

2. **Validate, then preview** — require `<name>` to match `^[a-z0-9]+(_[a-z0-9]+)*$` before interpolating it into any path; reject any other value without previewing or removing anything. Then produce a point-in-time preview of exactly what will be deleted with the script's `--dry-run` preview — do NOT pass `--confirmed` yet:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/remove-context.sh" "<name>" --dry-run
   ```
   Relay the listed paths (the current snapshot, if any, plus its archived history versions), the orphan notice when the helper prints one (history exists but the current snapshot is gone), and the "Would delete N file(s)" count: tell the user exactly which files will be permanently deleted. The dry run leaves snapshot/history files and their permissions unchanged (store bootstrap and lock bookkeeping may still occur). The confirmed run later rechecks under its writer lock, so a concurrent overwrite may add history after this preview — the confirmed run's final removal count is authoritative. If the dry run exits 1, relay the helper's actual error output; only when that output says no current or archived snapshot was found, also relay the available-snapshots list it printed, suggest `/context-list`, and stop. For any other failure, relay it and stop.

3. Confirm with **AskUserQuestion**, listing **"No, cancel (Recommended)" FIRST as the default**, then "Yes, delete" — any answer other than an explicit "Yes, delete" cancels.
   - On **No/cancel** (or any non-Yes answer): report that removal was cancelled. Do NOT run the confirmed removal.
   - On **Yes**: run the removal with the capability flag:
     ```
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/remove-context.sh" "<name>" --confirmed
     ```
     Relay the helper's actual result line and final count (for an orphan-only removal that is the "Removed N orphaned history file(s) for '<name>' (no current snapshot)." line).
