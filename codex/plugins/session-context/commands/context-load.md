---
description: "[DEPRECATED — superseded by knowledge] Load a session context summary from another session"
argument-hint: <snapshot-name>
---

## Instructions

1. If `$ARGUMENTS` is empty, tell the user: `Usage: $session-context:context-load <snapshot-name>`.
2. Resolve the absolute plugin root from the installed plugin source containing
   this command reference and substitute it literally for `<PLUGIN_ROOT>` below.
   Never infer it from the working directory or hardcode a marketplace cache
   version.

3. `SESSION_CONTEXT_HOME` must already be present in this pane's environment,
   inherited when the agent process started (the pane/session launcher sets it —
   never export or derive it here). Invoke the helper as one literal Bash
   segment, with no `export` beforehand, no `env` or variable-assignment prefix,
   and no other command chained, piped, redirected, or substituted around it:

   ```bash
   bash "<PLUGIN_ROOT>/scripts/load-context.sh" "<snapshot-name>"
   ```

   If the script reports `SESSION_CONTEXT_HOME` is not set, stop and request a
   pane relaunch with the correct environment instead of deriving another
   context store.

4. If the context loaded successfully, internalize it:
- What was done and what files changed.
- Key decisions and their reasoning.
- Open issues and where the other session left off.
- Notes and gotchas.

5. Summarize: `Loaded context from '<name>'. They were working on X and left off at Y.`
6. If a staleness WARNING appears at the end of the output, surface it to the user and suggest regenerating with `$session-context:context-generate <name>` — treat the loaded content as potentially out of date.
7. If no snapshot is found, suggest `$session-context:context-list`.
