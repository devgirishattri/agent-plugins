---
description: Load a session context summary from another session
argument-hint: <snapshot-name>
---

## Instructions

1. If `$ARGUMENTS` is empty, tell the user: `Usage: $session-context:context-load <snapshot-name>`.
2. Resolve `PLUGIN_ROOT` from this command resource's absolute source path by going up one directory from `<plugin-root>/commands`. Never derive it from the project working directory or embed a cache version.

3. Run:

   ```bash
   export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"
   bash "$PLUGIN_ROOT/scripts/load-context.sh" "$ARGUMENTS"
   ```

4. If the context loaded successfully, internalize it:
- What was done and what files changed.
- Key decisions and their reasoning.
- Open issues and where the other session left off.
- Notes and gotchas.

5. Summarize: `Loaded context from '<name>'. They were working on X and left off at Y.`
6. If a staleness WARNING appears at the end of the output, surface it to the user and suggest regenerating with `$session-context:context-generate <name>` — treat the loaded content as potentially out of date.
7. If no snapshot is found, suggest `$session-context:context-list`.
