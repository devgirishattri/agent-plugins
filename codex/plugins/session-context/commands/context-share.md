---
description: Share a session context summary with another named session
argument-hint: <session-name> [snapshot-name]
---

## Instructions

1. Parse `$ARGUMENTS`: the first word is the target session, and the second word is the optional snapshot name.
2. If no target session is provided, tell the user: `Usage: $session-context:context-share <session-name> [snapshot-name]`.
3. If no snapshot name is provided, derive it from the current directory name.
4. Resolve `PLUGIN_ROOT` from this command resource's absolute source path by going up one directory from `<plugin-root>/commands`. Never derive it from the project working directory or embed a cache version.

5. Run:

   ```bash
   export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"
   bash "$PLUGIN_ROOT/scripts/share-context.sh" "<session-name>" "<snapshot-name>"
   ```

6. Report: `Shared session context '<snapshot-name>' with <session>. The notification does not copy the file; they can load it with $session-context:context-load <snapshot-name> only when both panes use the same SESSION_CONTEXT_HOME.`
7. If the snapshot does not exist, suggest running `$session-context:context-generate` first.
