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

0. **If $ARGUMENTS is `--all` (bulk delete for the current project)**: Do NOT ask about each session individually. Use the "Available Sessions" list above. Tell the user how many sessions will be deleted and which project directory they belong to. Warn that this includes the currently active session; its data may be rewritten when this session exits. Then ask **once** with AskUserQuestion. List **"No, cancel (Recommended)"** FIRST as the default, then "Yes, delete all". Any answer other than an explicit "Yes, delete all" cancels.

   Run the bulk script only after the user explicitly picks "Yes, delete all". It deletes every session in the current project without further prompts:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/delete-all-sessions.sh --confirmed
   ```
   The `--confirmed` flag is the script's capability gate. Pass it ONLY after the user explicitly picked "Yes, delete all". Without it, the script refuses (exit 2). Then report the summary. If the user cancels, report that deletion was cancelled. Skip the remaining steps.

1. **If $ARGUMENTS is empty**: Show the available sessions from above as a numbered table. Use AskUserQuestion to let the user pick the session to delete. Include session name and ID in each option. After the selection, show the session details. Then ask for final confirmation with AskUserQuestion. List **"No, cancel (Recommended)"** FIRST as the default, then "Yes, delete it". Any answer other than an explicit "Yes, delete it" cancels.

2. **If no sessions matched**: Report that no session was found and suggest `/session-search` or `/session-list`.

3. **If multiple sessions matched**: Show the matching sessions as a table and ask the user to provide the full UUID to identify exactly one session.

4. **If exactly one session matched**: Show the session details (name, ID, project, size). Ask the user for confirmation before deleting. Use AskUserQuestion. List **"No, cancel (Recommended)"** FIRST as the default, then "Yes, delete it". Any answer other than an explicit "Yes, delete it" cancels.

5. **If the user confirms deletion**: Run the delete script with the FULL session UUID and the `--confirmed` capability flag. Pass `--confirmed` ONLY after the explicit "Yes, delete it". Without it, the script refuses (exit 2):
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/delete-session.sh <full-uuid> --confirmed
   ```
   Then report what was deleted.

6. **If the user cancels**: Report that deletion was cancelled.

Pass only a full 36-character UUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx) to the delete script. It rejects names and partial IDs, so resolve the UUID with the search/list scripts first.
