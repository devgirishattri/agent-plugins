---
description: Delete a session and all its related data files (no args = interactive select; --all = wipe current project)
argument-hint: "[session-id-or-name | --all]"
allowed-tools: Bash(bash:*)
---

## Available Sessions

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/list-sessions.sh`

## Find Session

Target: **$ARGUMENTS**

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/find-or-skip.sh "$ARGUMENTS"`

## Instructions

0. **If $ARGUMENTS is `--all` (bulk delete for the current project)**: Do NOT ask about each session individually. Instead, use the "Available Sessions" list above to tell the user exactly how many sessions will be deleted and which project directory they belong to, then ask **once** with AskUserQuestion. List **"No, cancel (Recommended)" FIRST as the default**, then "Yes, delete all" — any answer other than an explicit "Yes, delete all" cancels. Warn that this includes the currently active session (its data may be rewritten when this session exits). Only if the user explicitly picks "Yes, delete all", run the bulk script — it deletes every session in the current project without further prompts:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/delete-all-sessions.sh --confirmed
   ```
   The `--confirmed` flag is the script's capability gate — pass it ONLY after the user explicitly picked "Yes, delete all"; the script refuses (exit 2) without it. Then report the summary. If the user cancels, report that deletion was cancelled. Skip the remaining steps.

1. **If $ARGUMENTS is empty**: Show the available sessions from above as a numbered table and use AskUserQuestion to let the user pick which session to delete. Include session name and ID in each option. After selection, show the session details and ask for final confirmation with AskUserQuestion, listing **"No, cancel (Recommended)" FIRST as the default**, then "Yes, delete it" — any answer other than an explicit "Yes, delete it" cancels.

2. **If no sessions matched**: Report that no session was found and suggest `/session-search` or `/session-list`.

3. **If multiple sessions matched**: Show the matching sessions as a table and ask the user to provide the full UUID to identify exactly one session.

4. **If exactly one session matched**: Show the session details (name, ID, project, size) and ask the user for confirmation before deleting. Use AskUserQuestion listing **"No, cancel (Recommended)" FIRST as the default**, then "Yes, delete it" — any answer other than an explicit "Yes, delete it" cancels.

5. **If the user confirms deletion**: Run the delete script with the FULL session UUID and the `--confirmed` capability flag (pass `--confirmed` ONLY after the explicit "Yes, delete it"; the script refuses with exit 2 without it):
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/delete-session.sh <full-uuid> --confirmed
   ```
   Then report what was deleted.

6. **If the user cancels**: Report that deletion was cancelled.

IMPORTANT: Only pass a full UUID (36 characters, format xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx) to the delete script. Never pass a session name or partial ID.
