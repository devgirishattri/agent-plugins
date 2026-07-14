---
description: Remove a context snapshot for the current project
argument-hint: <snapshot-name>
---

## Instructions

1. Resolve the absolute plugin root from the installed plugin source containing
   this command reference and substitute it literally for `<PLUGIN_ROOT>` below.
   Never infer it from the working directory or hardcode a marketplace cache
   version.
2. `SESSION_CONTEXT_HOME` must already be present in this pane's environment,
   inherited when the agent process started (the pane/session launcher sets it —
   never export or derive it here). Invoke each helper as one literal Bash
   segment, with no `export` beforehand, no `env` or
   variable-assignment prefix, and no other command chained, piped, redirected,
   or substituted around it:

   If a helper reports `SESSION_CONTEXT_HOME` is not set, stop and request a
   pane relaunch with the correct environment instead of deriving another
   context store.

3. Set `SNAPSHOT_NAME` from `$ARGUMENTS`. If it is empty, invoke
   `bash "<PLUGIN_ROOT>/scripts/list-contexts.sh"` under the contract above,
   collect its first-column snapshot names, and ask the user to select one.
   Prefer structured `request_user_input` when available in the current mode;
   otherwise ask a direct blocking question. If none exist, suggest
   `$session-context:context-generate` and stop.
4. Preview exactly what deletion would remove before asking for confirmation.
   Using read-only filesystem inspection, enumerate the current
   `$SESSION_CONTEXT_HOME/<snapshot-name>.md` file and every matching
   `$SESSION_CONTEXT_HOME/.history/<snapshot-name>.*.md` file. Show the exact
   paths and history-file count. Do not invoke `remove-context.sh` during the
   preview. If neither current nor archived data exists, suggest
   `$session-context:context-list` and stop.
5. Show the exact `SNAPSHOT_NAME` and ask a separate Yes/No confirmation. Prefer `request_user_input` when available, with Cancel recommended/default; otherwise ask directly and wait. Anything other than explicit confirmation cancels. Never invoke the removal script before confirmation.

6. After explicit confirmation, run:

   ```bash
   bash "<PLUGIN_ROOT>/scripts/remove-context.sh" "<snapshot-name>" --confirmed
   ```

   The `--confirmed` guard must be passed only after the explicit confirmation in step 5. Never infer, pre-fill, or bypass confirmation.

7. If removed successfully, confirm that the current snapshot and its archived history were removed, including the script's history-file count.
8. If no snapshot is found, suggest `$session-context:context-list`. If cancelled, say no snapshot was removed.
