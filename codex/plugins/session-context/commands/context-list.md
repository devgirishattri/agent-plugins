---
description: List available context snapshots for the current project
---

## Instructions

1. Resolve the absolute plugin root from the installed plugin source containing
   this command reference and substitute it literally for `<PLUGIN_ROOT>` below.
   Never infer it from the working directory or hardcode a marketplace cache
   version.

2. `SESSION_CONTEXT_HOME` must already be present in this pane's environment,
   inherited when the agent process started (the pane/session launcher sets it —
   never export or derive it here). Invoke the helper as one literal Bash
   segment, with no `export` beforehand, no `env` or variable-assignment prefix,
   and no other command chained, piped, redirected, or substituted around it:

   ```bash
   bash "<PLUGIN_ROOT>/scripts/list-contexts.sh"
   ```

   If the script reports `SESSION_CONTEXT_HOME` is not set, stop and request a
   pane relaunch with the correct environment instead of deriving another
   context store.

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
