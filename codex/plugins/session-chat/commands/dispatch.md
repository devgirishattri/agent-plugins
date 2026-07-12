---
description: Dispatch a tracked task to an existing named session
argument-hint: <session-name> <prompt>
---

## Instructions

1. Parse `$ARGUMENTS`: optional `--priority high` and `--ttl <minutes>` come first; then the target session name; everything after is the prompt.
2. If either value is missing, tell the user: `Usage: $session-chat:dispatch <session-name> <task prompt>`.
   If this is a response to an incoming message, use `$session-chat:reply`
   instead so the transport records its message id automatically.
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
     bash "$PLUGIN_ROOT/scripts/dispatch-to-session.sh" [--priority high] [--ttl <minutes>] [--reply-to <incoming-id>] "<target>" "<returned-directory>/prompt.md"
     ```

   - Delete the prompt with `apply_patch` and remove the empty temp directory.
     If no data-safe file writer exists, ask the user for an existing prompt
     file instead of falling back to shell interpolation.

5. Relay the script's `Dispatched task ...` or `Queued dispatch ...` result accurately. For either successful result, mention that the recipient must use `SESSION_CHAT_INCOMING_MODE=auto` or `assist` to read and act on the task; default `notify` only reports that a dispatch arrived.
6. If the target is not found, suggest `$session-chat:panes`.
7. If there is an error about no name, suggest `$session-chat:whoami <name>`.
8. For duplicate names, suggest `$session-chat:whoami <name>` in one pane.
9. If a live timeout is followed by `Queued dispatch ...`, report durable queued success and do not retry. Raise `SESSION_CHAT_VERIFY_TIMEOUT_MS` only when immediate live delivery matters. Retry only a hard failure that did not queue, after fixing its cause.
