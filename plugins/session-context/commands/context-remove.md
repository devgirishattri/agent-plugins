---
description: "[DEPRECATED — superseded by knowledge] Remove a context snapshot (and its history) for the current project"
argument-hint: "<snapshot-name>"
allowed-tools: Bash(bash:*)
---

## Instructions

Removing a snapshot is **destructive** — it deletes the snapshot AND all of its archived history versions, with no restore path. Gate it behind an explicit confirmation; the script itself refuses without a `--confirmed` capability flag.

1. If no snapshot name was given in `$ARGUMENTS`, run `/context-list` and ask the user which snapshot to remove; then stop.

   `SESSION_CONTEXT_HOME` must already be present in this session's environment, inherited when the agent process started (never export or derive it here). Every invocation below must be exactly one Bash segment, with no `export` beforehand, no `env` or variable-assignment prefix, and no other command chained, piped, redirected, or substituted around it. If it is unset, stop and request that this pane/session be relaunched with the correct environment instead of deriving another context store.

2. **Validate, then preview** — require `<name>` to match `^[A-Za-z0-9_-]+$` before interpolating it into any path; reject any other value without previewing or removing anything. Then produce a point-in-time preview of exactly what will be deleted — do NOT pass `--confirmed` yet:
   ```
   ls -1 "$SESSION_CONTEXT_HOME/<name>.md" "$SESSION_CONTEXT_HOME/.history/<name>."*.md 2>/dev/null
   ```
   Tell the user exactly which files (the snapshot + N history versions) will be permanently deleted. The removal script later revalidates under its writer lock, so a concurrent overwrite may add history after this preview — the script's final removal count is authoritative. If the snapshot doesn't exist, say so, suggest `/context-list`, and stop.

3. Confirm with **AskUserQuestion**, listing **"No, cancel (Recommended)" FIRST as the default**, then "Yes, delete" — any answer other than an explicit "Yes, delete" cancels.
   - On **No/cancel** (or any non-Yes answer): report that removal was cancelled. Do NOT run the removal script.
   - On **Yes**: run the removal with the capability flag:
     ```
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/remove-context.sh" "<name>" --confirmed
     ```
     Relay the "N file(s) deleted" result.
