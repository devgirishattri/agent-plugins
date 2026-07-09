---
description: List Codex sessions for the current project, or all projects
argument-hint: [all]
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-plugins/session-manager/1.7.1}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-manager"
   ```

2. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/list-sessions.sh" $ARGUMENTS
   ```

3. Present the tab-separated output as a clean markdown table:

   ```text
   | Thread | Session ID | Project | Size | Last Modified |
   ```

Rules:
- Sort by Last Modified, most recent first. The script output is already sorted.
- Show full Session IDs so users can copy them for `/session-delete`.
- If a session has no thread title, show `(untitled)`.
- Show the total count of sessions at the bottom.
- If the output is empty or says `No sessions found`, report that no sessions were found.
- Mention that `/session-list all` shows sessions across all projects.
- Suggest `/session-search <query>` to filter results.
