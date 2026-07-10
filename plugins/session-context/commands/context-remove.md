---
description: Remove a context snapshot (and its history) for the current project
argument-hint: "<snapshot-name>"
allowed-tools: Bash(bash:*)
---

## Instructions

Removing a snapshot is **destructive** — it deletes the snapshot AND all of its archived history versions, with no restore path. Gate it behind an explicit confirmation; the script itself refuses without a `--confirmed` capability flag.

1. If no snapshot name was given in `$ARGUMENTS`, run `/context-list` and ask the user which snapshot to remove; then stop.

2. **Preview** exactly what will be deleted — do NOT pass `--confirmed` yet:
   ```
   export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"
   ls -1 "$SESSION_CONTEXT_HOME/<name>.md" "$SESSION_CONTEXT_HOME/.history/<name>."*.md 2>/dev/null
   ```
   Tell the user exactly which files (the snapshot + N history versions) will be permanently deleted. If the snapshot doesn't exist, say so, suggest `/context-list`, and stop.

3. Confirm with **AskUserQuestion**, listing **"No, cancel (Recommended)" FIRST as the default**, then "Yes, delete" — any answer other than an explicit "Yes, delete" cancels.
   - On **No/cancel** (or any non-Yes answer): report that removal was cancelled. Do NOT run the removal script.
   - On **Yes**: run the removal with the capability flag:
     ```
     export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"
     bash ${CLAUDE_PLUGIN_ROOT}/scripts/remove-context.sh "<name>" --confirmed
     ```
     Relay the "N file(s) deleted" result.
