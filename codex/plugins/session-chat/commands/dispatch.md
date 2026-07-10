---
description: Dispatch a tracked task to an existing named session
argument-hint: <session-name> <prompt>
---

## Instructions

1. Parse `$ARGUMENTS`: optional `--priority high` and `--ttl <minutes>` come first; then the target session name; everything after is the prompt.
2. If either value is missing, tell the user: `Usage: $session-chat:dispatch <session-name> <task prompt>`.
3. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

4. Stage the prompt with a data-safe file-writing tool, then dispatch it:

   - Run `mktemp -d "${TMPDIR:-/tmp}/session-chat-dispatch.XXXXXX"` separately
     and capture its result; do not include prompt content in that shell call.
   - Use `apply_patch` to add `<returned-directory>/prompt.md` containing the
     verbatim prompt. Never put arbitrary task text in a shell heredoc, `echo`,
     `printf`, command substitution, or interpreter `-c` string.
   - Run:

     ```bash
     bash "$PLUGIN_ROOT/scripts/dispatch-to-session.sh" [--priority high] [--ttl <minutes>] "<target>" "<returned-directory>/prompt.md"
     ```

   - Delete the prompt with `apply_patch` and remove the empty temp directory.
     If no data-safe file writer exists, ask the user for an existing prompt
     file instead of falling back to shell interpolation.

5. Report: `Dispatched task to **<target>**. The recipient must use SESSION_CHAT_INCOMING_MODE=auto or assist to read and act on the task; the default notify mode only reports that a dispatch arrived.`
6. If the target is not found, suggest `$session-chat:panes`.
7. If there is an error about no name, suggest `$session-chat:whoami <name>`.
8. For duplicate names, suggest `$session-chat:whoami <name>` in one pane.
9. If there is an error that the dispatch did not land within the timeout, tell the user the target may be busy; retry when idle or raise `SESSION_CHAT_VERIFY_TIMEOUT_MS`.
