---
description: Delete a Codex session and related local data files (no args = interactive select; --all = wipe current project)
argument-hint: [session-id-or-title | --all]
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-plugins/session-manager/1.7.1}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-manager"
   ```

2. If `$ARGUMENTS` is exactly `--all`, do not ask about each session individually. First run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/list-sessions.sh"
   ```

   Count the returned session rows and tell the user exactly how many Codex sessions will be deleted for the current project directory. Ask once for confirmation, with options equivalent to "Yes, delete all" and "No, cancel". Warn that this includes the currently active session, whose data may be rewritten when this session exits. If the user confirms, run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/delete-all-sessions.sh"
   ```

   Then report the summary. If the user cancels, report that deletion was cancelled. Skip the remaining steps.

3. Run the delete-and-resolve helper:

   ```bash
   bash "$PLUGIN_ROOT/scripts/delete-resolved-session.sh" "$ARGUMENTS"
   ```

4. If the status is `SELECT`, show the available sessions as a numbered table and ask the user which session to delete. Include thread title and full ID in each option.
5. If the status is `NONE`, report the message and suggest `/session-search` or `/session-list`.
6. If the status is `MULTIPLE`, show the matching sessions as a table and ask the user to provide a more specific title or the full UUID.
7. If the status is `DELETING`, report the deletion output.
8. If the latest user message is exactly `delete <full-uuid>`, keep backwards compatibility by running:

   ```bash
   bash "$PLUGIN_ROOT/scripts/delete-session.sh" "<full-uuid>"
   ```

9. Report what was deleted. If the user cancels, report that deletion was cancelled.

Important: only pass a full UUID to `delete-session.sh`. Send titles, partial IDs, and project queries through `delete-resolved-session.sh`.
