---
description: Search Codex sessions by name, ID prefix, or project path
argument-hint: <search-query>
---

## Instructions

1. If `$ARGUMENTS` is empty, tell the user: `Usage: /session-search <name-or-id-or-project>`.
2. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-manager/1.4.7}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-manager"
   ```

3. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/search-sessions.sh" "$ARGUMENTS"
   ```

4. Present matching sessions as a markdown table:

   ```text
   | Thread | Session ID | Project | Size | Last Modified |
   ```

Rules:
- Show full Session IDs so users can copy them for `/session-delete`.
- If no sessions match, tell the user no sessions matched `$ARGUMENTS`.
- Show the count of matching sessions at the bottom.
- Mention that `/session-delete <session-id>` can be used to delete a session.
