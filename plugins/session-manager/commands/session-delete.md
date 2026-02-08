---
description: Delete a session and all its related data files (no args = interactive select)
argument-hint: [session-id-or-name]
allowed-tools: Bash(bash:*)
---

## Available Sessions

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/list-sessions.sh`

## Find Session

Target: **$ARGUMENTS**

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/find-or-skip.sh "$ARGUMENTS"`

## Instructions

1. **If $ARGUMENTS is empty**: Show the available sessions from above as a numbered table and use AskUserQuestion to let the user pick which session to delete. Include session name and ID in each option. After selection, show the session details and ask for final confirmation with AskUserQuestion using options "Yes, delete it" and "No, cancel".

2. **If no sessions matched**: Report that no session was found and suggest `/session-search` or `/session-list`.

3. **If multiple sessions matched**: Show the matching sessions as a table and ask the user to provide the full UUID to identify exactly one session.

4. **If exactly one session matched**: Show the session details (name, ID, project, size) and ask the user for confirmation before deleting. Use AskUserQuestion with options "Yes, delete it" and "No, cancel".

5. **If the user confirms deletion**: Run the delete script with the FULL session UUID:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/delete-session.sh <full-uuid>
   ```
   Then report what was deleted.

6. **If the user cancels**: Report that deletion was cancelled.

IMPORTANT: Only pass a full UUID (36 characters, format xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx) to the delete script. Never pass a session name or partial ID.
