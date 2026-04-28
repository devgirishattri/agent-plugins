---
description: Delete a Codex session and related local data files
argument-hint: [session-id-or-name]
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-manager/1.4.4}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-manager"
   ```

2. Run this first to show available sessions:

   ```bash
   bash "$PLUGIN_ROOT/scripts/list-sessions.sh"
   ```

3. Run this to resolve the target:

   ```bash
   bash "$PLUGIN_ROOT/scripts/find-or-skip.sh" "$ARGUMENTS"
   ```

4. If `$ARGUMENTS` is empty, show the available sessions as a numbered table and ask the user which session to delete. Include session name and ID in each option.
5. If no sessions matched, report that no session was found and suggest `/session-search` or `/session-list`.
6. If multiple sessions matched, show the matching sessions as a table and ask the user to provide the full UUID.
7. If exactly one session matched, show the session details and ask the user for explicit confirmation before deleting.
8. If the user confirms deletion, run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/delete-session.sh" "<full-uuid>"
   ```

9. Report what was deleted. If the user cancels, report that deletion was cancelled.

Important: only pass a full UUID to the delete script. Never pass a session name or partial ID.
