---
description: List available context snapshots for the current project
---

## Instructions

1. Resolve `PLUGIN_ROOT` from this command resource's absolute source path by going up one directory from `<plugin-root>/commands`. Never derive it from the project working directory or embed a cache version.

2. Run:

   ```bash
   export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"
   bash "$PLUGIN_ROOT/scripts/list-contexts.sh"
   ```

3. Present the tab-separated output as a markdown table:

   ```text
   | Snapshot | Lines | Last Updated | Versions |
   ```

Rules:
- The Versions column counts archived history entries (created each time a snapshot is overwritten, max 10 kept).
- If no snapshots are found, suggest `$session-context:context-generate` to create one.
- Use the first-column snapshot names in every suggestion.
- Suggest `$session-context:context-load <snapshot-name>` to load a snapshot.
- Suggest `$session-context:context-diff <snapshot-name>` to compare a snapshot with its previous version.
- Suggest `$session-context:context-share <session> <snapshot-name>` to notify another session.
- Suggest `$session-context:context-remove <snapshot-name>` to remove a stale snapshot.
