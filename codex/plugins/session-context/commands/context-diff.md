---
description: Diff a context snapshot against its archived history versions
argument-hint: <snapshot-name> [--versions | <timestamp>]
---

## Instructions

1. If `$ARGUMENTS` is empty, tell the user: `Usage: $session-context:context-diff <snapshot-name> [--versions | <timestamp>]`.
2. Resolve `PLUGIN_ROOT` from this command resource's absolute source path by going up one directory from `<plugin-root>/commands`. Never derive it from the project working directory or embed a cache version.

3. Run (passing the arguments through):

   ```bash
   export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"
   bash "$PLUGIN_ROOT/scripts/diff-context.sh" <snapshot-name> [--versions | <timestamp>]
   ```

   Modes:
   - `<snapshot-name>` only — unified diff of the newest archived version against the current snapshot.
   - `<snapshot-name> --versions` — list available history timestamps (UTC, `YYYYMMDD-HHMMSSZ`).
   - `<snapshot-name> <timestamp>` — diff that archived version against the current snapshot.

4. Show the unified diff in a fenced ```diff code block and briefly summarize what changed.
5. If the output says "(no differences)", state the snapshot is unchanged since that version.
6. If no history versions exist, explain that history is only created when `$session-context:context-generate` overwrites an existing snapshot.
7. If the snapshot does not exist, suggest `$session-context:context-list`.
