---
description: Delete a Codex session and related local data files
argument-hint: [session-id-or-name]
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-manager/1.4.6}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-manager"
   ```

2. Run the delete resolver:

   ```bash
   bash "$PLUGIN_ROOT/scripts/prepare-delete.sh" "$ARGUMENTS"
   ```

3. If the status is `SELECT`, show the available sessions as a numbered table and ask the user which session to delete. Include session name and full ID in each option.
4. If the status is `NONE`, report the message and suggest `/session-search` or `/session-list`.
5. If the status is `MULTIPLE`, show the matching sessions as a table and ask the user to provide the full UUID.
6. If the status is `ONE`, show the session details and ask the user to confirm by replying with `delete <full-uuid>`.
7. If the latest user message is exactly `delete <full-uuid>`, run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/delete-session.sh" "<full-uuid>"
   ```

8. Report what was deleted. If the user cancels, report that deletion was cancelled.

Important: only pass a full UUID to the delete script. Never pass a session name or partial ID.
