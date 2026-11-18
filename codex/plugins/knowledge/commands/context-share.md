---
description: Share a session context summary with another named session
argument-hint: <session-name> [snapshot-name]
---

## Instructions

1. Parse `$ARGUMENTS`: the first word is the target session, and the second word is the optional snapshot name.
2. If no target session is provided, tell the user: `Usage: $knowledge:context-share <session-name> [snapshot-name]`.
3. If no snapshot name is provided, derive it from the current directory name
   and normalize it to canonical `snake_case`
   (`^[a-z0-9]+(_[a-z0-9]+)*$`). If a snapshot name is supplied and it is not
   canonical `snake_case`, reject it instead of invoking the helper.
4. Resolve the absolute plugin root from the installed plugin source containing
   this command reference and substitute it literally for `<PLUGIN_ROOT>` below.
   Never infer it from the working directory or hardcode a marketplace cache
   version.

5. `SESSION_CONTEXT_HOME` must already be present in this pane's environment,
   inherited when the agent process started (the pane/session launcher sets it —
   never export or derive it here). Invoke the helper as one literal Bash segment,
   with no `export` beforehand, no `env` or variable-assignment prefix,
   and no other command chained, piped, redirected, or substituted around it:

   ```bash
   bash "<PLUGIN_ROOT>/scripts/share-context.sh" "<session-name>" "<snapshot-name>"
   ```

   If the script reports `SESSION_CONTEXT_HOME` is not set, stop and request a
   pane relaunch with the correct environment instead of deriving another
   context store.

   **Transport contract:** `context-share` performs nested session-chat/tmux
   transport. In Codex, request scoped escalation/approval for the exact
   installed helper on the first attempt whenever it may send; keep it one
   literal Bash segment and never work around the sandbox with `bash -c`, a
   wrapper, `env`, an assignment prefix, an export, a pipeline, chaining,
   redirection, substitution, or broad provider-home access. Escalation grants
   transport access only; the chosen recipient and arguments remain
   authoritative. A failed share is transport-only with respect to snapshot
   contents: no snapshot lifecycle transition occurs, although resolving the
   configured store may create its directory or harden owner-only permissions.
   A failed share can leave the notification queued or staged. Check `$session-chat:pane-health` for the recipient. If delivery is uncertain, confirm receipt before resending. Retry only after verifying that nothing was staged, queued or delivered.

6. On success, report that the recipient was notified. They can load the snapshot with `$knowledge:context-load <snapshot-name>` when both panes inherited the same `SESSION_CONTEXT_HOME`. Relaunch a mismatched pane with the correct environment.
7. If the snapshot does not exist, suggest running `$knowledge:context-generate` first.
