---
description: Remove a context snapshot for the current project
argument-hint: <snapshot-name>
---

## Instructions

1. Resolve `PLUGIN_ROOT` from this command resource's absolute source path by going up one directory from `<plugin-root>/commands`. Never derive it from the project working directory or embed a cache version.
2. Set `SNAPSHOT_NAME` from `$ARGUMENTS`. If it is empty, run `list-contexts.sh`, collect its first-column snapshot names, and ask the user to select one. Prefer structured `request_user_input` when available in the current mode; otherwise ask a direct blocking question. If none exist, suggest `$session-context:context-generate` and stop.
3. Show the exact `SNAPSHOT_NAME` and ask a separate Yes/No confirmation. Prefer `request_user_input` when available, with Cancel recommended/default; otherwise ask directly and wait. Anything other than explicit confirmation cancels. Never invoke the removal script before confirmation.

4. After explicit confirmation, run:

   ```bash
   export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"
   bash "$PLUGIN_ROOT/scripts/remove-context.sh" "$SNAPSHOT_NAME" --confirmed
   ```

   The `--confirmed` guard must be passed only after the explicit confirmation in step 3. Never infer, pre-fill, or bypass confirmation.

5. If removed successfully, confirm that the current snapshot and its archived history were removed, including the script's history-file count.
6. If no snapshot is found, suggest `$session-context:context-list`. If cancelled, say no snapshot was removed.
