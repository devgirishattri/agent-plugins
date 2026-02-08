---
description: Delete a session and all its related data files (no args = current session)
argument-hint: [session-id-or-name]
allowed-tools: Bash(bash:*)
---

## Session Context

Current session ID: **$SESSION_ID**

## Find Session

Target: **$ARGUMENTS**

!`[ -n "$ARGUMENTS" ] && bash ${CLAUDE_PLUGIN_ROOT}/scripts/search-sessions.sh "$ARGUMENTS" || echo ""`

## Instructions

1. **If $ARGUMENTS is empty**: The user wants to delete the **current session**. Use $SESSION_ID as the target. Show the current session details and ask the user for confirmation using AskUserQuestion with options "Yes, delete current session" and "No, cancel".

2. **If no sessions matched**: Report that no session was found and suggest `/session-search` or `/session-list`.

3. **If multiple sessions matched**: Show the matching sessions as a table and ask the user to provide the full UUID to identify exactly one session.

4. **If exactly one session matched**: Show the session details (name, ID, project, size) and ask the user for confirmation before deleting. Use AskUserQuestion with options "Yes, delete it" and "No, cancel".

5. **If the user confirms deletion**: Run the delete script with the FULL session UUID:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/delete-session.sh <full-uuid>
   ```
   Then report what was deleted.
   **If the deleted session was the current session ($SESSION_ID)**, display this message after the deletion report:
   ```
   ⚠️ Session deleted. Please restart Claude Code.
   ```

6. **If the user cancels**: Report that deletion was cancelled.

IMPORTANT: Only pass a full UUID (36 characters, format xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx) to the delete script. Never pass a session name or partial ID.
