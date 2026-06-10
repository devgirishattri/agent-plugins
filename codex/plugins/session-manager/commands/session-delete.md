---
description: Delete a Codex session and related local data files
argument-hint: [session-id-or-title]
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-manager/1.5.0}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-manager"
   ```

2. Run the delete-and-resolve helper:

   ```bash
   bash "$PLUGIN_ROOT/scripts/delete-resolved-session.sh" "$ARGUMENTS"
   ```

3. If the status is `SELECT`, show the available sessions as a numbered table and ask the user which session to delete. Include thread title and full ID in each option.
4. If the status is `NONE`, report the message and suggest `/session-search` or `/session-list`.
5. If the status is `MULTIPLE`, show the matching sessions as a table and ask the user to provide a more specific title or the full UUID.
6. If the status is `DELETING`, report the deletion output.
7. If the latest user message is exactly `delete <full-uuid>`, keep backwards compatibility by running:

   ```bash
   bash "$PLUGIN_ROOT/scripts/delete-session.sh" "<full-uuid>"
   ```

8. Report what was deleted. If the user cancels, report that deletion was cancelled.

Important: only pass a full UUID to `delete-session.sh`. Send titles, partial IDs, and project queries through `delete-resolved-session.sh`.
