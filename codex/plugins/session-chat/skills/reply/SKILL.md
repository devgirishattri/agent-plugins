---
name: reply
description: "Reply to an incoming session-chat message with automatic message-id correlation. Use when responding, acknowledging, or reporting completion to another pane after receiving a session-chat message or dispatch."
---

# Reply

When this skill is invoked, do not add a preamble. Send the reply, then report
only the transport result or the shortest actionable error.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from cwd or hardcode a marketplace cache version.

Parse the first argument as the sender pane, the second as the incoming message
id, and the remainder as the reply. The id must be the 8-16 character lowercase
hex value from the incoming `id:<id>` field. If anything is missing, report:

```text
Usage: $session-chat:reply <pane-name> <message-id> <message>
```

Never compose `[re:<id>]` manually. The transport owns that protocol marker and
adds it exactly once through `--reply-to`.

For a safe single-line reply within `SESSION_CHAT_SEND_MAX_LEN`, run:

```bash
bash "$PLUGIN_ROOT/scripts/send-message.sh" --reply-to "<message-id>" "<pane-name>" "<message>"
```

The generated token counts toward the send limit. If this reports the length
guard, retry the same reply id through the dispatch-file path below.

For a multi-line, long, or quoting-sensitive reply:

1. Create a temporary directory with `mktemp -d` in a separate shell call.
2. Use `apply_patch` to add `<temp-directory>/reply.md` containing the verbatim
   reply. Never embed reply text in a heredoc, `echo`, `printf`, command
   substitution, or interpreter `-c` string.
3. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/dispatch-to-session.sh" --reply-to "<message-id>" "<pane-name>" "<temp-directory>/reply.md"
   ```

4. Delete the temporary file with `apply_patch`, then remove the empty directory.

If the reply id is invalid, relay the validation error and stop. If tmux is not
active, explain that replies require tmux. For target, duplicate-name, busy, or
sandbox-denial errors, follow the same guidance as `$session-chat:send` and
`$session-chat:dispatch`.
