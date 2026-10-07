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

4. For file dispatch, follow `$session-chat:dispatch`'s canonical staging
   instructions: strict-v1 children use native `apply_patch` in their validated
   `<messages-grant>/drafts/<pane-name>/` namespace, with a fresh safe `.md` or
   `.txt` filename. Other sessions may use a separately created temporary
   directory. Preserve the verbatim body as data; never interpolate it into shell
   source. Dispatch using the installed `dispatch-to-session.sh` helper.
   After delivered or durable queued success, the transport consumes eligible
   own-pane drafts unless `SESSION_CHAT_KEEP_DRAFTS=1`. Do not delete retained
   drafts or resend successful messages. Preserve drafts after hard failure.
   Outside that namespace, remove your temporary file with `apply_patch` after
   success. Shell staging/cleanup stays blocked for strict-v1 children.
   A missing grant or native writer is an actionable error.
   Put complete verdicts in one file; corrections identify the replaced message.

5. Relay the script's `Dispatched task ...` or `Queued dispatch ...` result accurately. For either successful result, mention that the recipient must use `SESSION_CHAT_INCOMING_MODE=auto` or `assist` to read and act on the task; default `notify` only reports that a dispatch arrived.
6. If the target is not found, suggest `$session-chat:panes`.
7. If there is an error about no name, suggest `$session-chat:whoami <name>`.
8. For duplicate names, suggest `$session-chat:whoami <name>` in one pane.
9. If a live timeout is followed by `Queued dispatch ...`, report durable queued success and do not retry. Raise `SESSION_CHAT_VERIFY_TIMEOUT_MS` only when immediate live delivery matters. Retry only a hard failure that did not queue, after fixing its cause.
