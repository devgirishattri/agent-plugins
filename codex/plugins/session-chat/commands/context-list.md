---
description: List all available project context snapshots
---

## Instructions

1. Set `PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-codex/plugins/session-chat}"`.
2. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/list-contexts.sh"
   ```

3. Present the tab-separated output as a markdown table:

   ```text
   | Project | Lines | Last Updated |
   ```

Rules:
- If no snapshots are found, suggest `/context-generate` to create one.
- Suggest `/context-load <project>` to load a snapshot.
- Suggest `/context-share <session> <project>` to share with another session.
