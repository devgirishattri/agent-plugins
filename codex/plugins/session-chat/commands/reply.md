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

5. For a long, multi-line, or quoting-sensitive reply, create a temporary
   directory separately, use `apply_patch` to write the verbatim reply into
   `reply.md`, then run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/dispatch-to-session.sh" --reply-to "<message-id>" "<pane-name>" "<temp-directory>/reply.md"
   ```

   Delete the file with `apply_patch`, then remove the empty directory. Never
   interpolate reply text into a shell heredoc or command string.
6. Relay the transport result or shortest actionable error.
