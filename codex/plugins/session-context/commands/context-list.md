---
description: List available context snapshots for the current project
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-context/0.3.0}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-context"
   ```

2. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/list-contexts.sh"
   ```

3. Present the tab-separated output as a markdown table:

   ```text
   | Project | Lines | Last Updated | Versions |
   ```

Rules:
- The Versions column counts archived history entries (created each time a snapshot is overwritten, max 10 kept).
- If no snapshots are found, suggest `/context-generate` to create one.
- Suggest `/context-load <project>` to load a snapshot.
- Suggest `/context-diff <project>` to compare a snapshot with its previous version.
- Suggest `/context-share <session> <project>` to share with another session.
