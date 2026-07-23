---
description: Diff a context snapshot against its archived history versions
argument-hint: <snapshot-name> [--versions | <timestamp>]
---

## Instructions

1. If `$ARGUMENTS` is empty, tell the user: `Usage: $knowledge:context-diff <snapshot-name> [--versions | <timestamp>]`.
2. Resolve the absolute plugin root from the installed plugin source containing
   this command reference and substitute it literally for `<PLUGIN_ROOT>` below.
   Never infer it from the working directory or hardcode a marketplace cache
   version.

3. `SESSION_CONTEXT_HOME` must already be present in this pane's environment,
   inherited when the agent process started (the pane/session launcher sets it —
   never export or derive it here). Invoke the helper as one literal Bash
   segment, with no `export` beforehand, no `env` or variable-assignment prefix,
   and no other command chained, piped, redirected, or substituted around it,
   passing the selected arguments through:

   ```bash
   bash "<PLUGIN_ROOT>/scripts/diff-context.sh" "<snapshot-name>" [--versions | "<timestamp>"]
   ```

   If the script reports `SESSION_CONTEXT_HOME` is not set, stop and request a
   pane relaunch with the correct environment instead of deriving another
   context store.

   Modes:
   - `<snapshot-name>` only — unified diff of the newest archived version against the current snapshot.
   - `<snapshot-name> --versions` — list available history timestamps (`YYYYMMDD-HHMMSS+HHMM` in `AGENT_PLUGINS_TIME_ZONE`; legacy UTC timestamps remain accepted).
   - `<snapshot-name> <timestamp>` — diff that archived version against the current snapshot.

4. Show the unified diff in a fenced ```diff code block and briefly summarize what changed.
5. If the output says "(no differences)", state the snapshot is unchanged since that version.
6. If no history versions exist, explain that history is only created when `$knowledge:context-generate` overwrites an existing snapshot.
7. If the snapshot does not exist, suggest `$knowledge:context-list`.
