---
description: Reply to an incoming session-chat message with automatic correlation
argument-hint: <pane-name> <message-id> <message>
---

## Instructions

1. Parse the sender pane, incoming lowercase-hex message id, and reply from
   `$ARGUMENTS`. If any is missing, report:
   `Usage: $session-chat:reply <pane-name> <message-id> <message>`.
2. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.
3. Never type `[re:<id>]` into the reply yourself. Pass the incoming id through
   `--reply-to`; the transport validates it and adds the marker exactly once.
4. For a safe single-line reply, run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/send-message.sh" --reply-to "<message-id>" "<pane-name>" "<message>"
   ```

5. For file dispatch, follow `$session-chat:reply`'s canonical staging
   instructions: strict-v1 children use native `apply_patch` in their validated
   `<messages-grant>/drafts/<pane-name>/` namespace, with a fresh safe `.md` or
   `.txt` filename. Other sessions may use a separately created temporary
   directory. Preserve the verbatim body as data; never interpolate it into shell
   source. Dispatch using the installed `dispatch-to-session.sh` helper with `--reply-to`.
   After delivered or durable queued success, the transport consumes eligible
   own-pane drafts unless `SESSION_CHAT_KEEP_DRAFTS=1`. Do not delete retained
   drafts or resend successful messages. Preserve drafts after hard failure.
   Outside that namespace, remove your temporary file with `apply_patch` after
   success. Shell staging/cleanup stays blocked for strict-v1 children.
   A missing grant or native writer is an actionable error.
   Put complete verdicts in one file; corrections identify the replaced message.

6. Relay the transport result or shortest actionable error.
