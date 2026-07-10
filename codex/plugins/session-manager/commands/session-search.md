---
description: Search Codex sessions by name, ID prefix, or project path
argument-hint: <search-query>
---

## Instructions

1. If `$ARGUMENTS` is empty, tell the user: `Usage: $session-manager:session-search <name-or-id-or-project>`.
2. Resolve `PLUGIN_ROOT` from this command resource's absolute path: it is the parent directory of `commands/`. Never hard-code a marketplace cache version.

3. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/search-sessions.sh" "$ARGUMENTS"
   ```

4. Present matching sessions as a markdown table:

   ```text
   | Thread | Session ID | Project | Size | Last Modified |
   ```

Rules:
- Show full Session IDs so users can copy them for `$session-manager:session-delete`.
- If no sessions match, tell the user no sessions matched `$ARGUMENTS`.
- Show the count of matching sessions at the bottom.
- Mention that `$session-manager:session-delete <session-id>` can be used to delete a session.
