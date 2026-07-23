---
description: Share a session context summary with another named session
argument-hint: <session-name> [snapshot-name]
---

## Instructions

1. Parse `$ARGUMENTS`: the first word is the target session, and the second word is the optional snapshot name.
2. If no target session is provided, tell the user: `Usage: $knowledge:context-share <session-name> [snapshot-name]`.
3. If no snapshot name is provided, derive it from the current directory name.
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
   Fixing the transport and re-running the same legal share command is safe.

6. Report: `Shared session context '<snapshot-name>' with <session>. The notification does not copy the file; they can load it with $knowledge:context-load <snapshot-name> only when both panes inherited the same SESSION_CONTEXT_HOME. Relaunch a mismatched pane with the correct environment.`
7. If the snapshot does not exist, suggest running `$knowledge:context-generate` first.
