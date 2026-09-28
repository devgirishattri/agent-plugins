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

This is a skill, not a shell executable. Run the installed `send-message.sh`
with `--reply-to` as shown below; there is no `reply.sh` or `session-chat reply`
command. Codex internal agent-messaging tools do not address tmux panes.
Substitute the resolved absolute plugin path literally in the shell command.

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

Under an active strict-v1 harness, a reviewer, executor, or confined coordinator
must stage in `<validated-messages-grant>/drafts/<validated-pane-name>/`.
Resolve the grant and identity from the validated workspace plan or launch context;
use `$session-workspace:workspace-plan` if needed. Never derive or export store
variables to grant access. Choose a fresh name such as
`reply-<incoming-id>-<nonce>.md`: the stem starts with an ASCII letter or digit,
contains only ASCII letters, digits, `.`, `_`, or `-`, and is at most 128
characters; the suffix is `.md` or `.txt`. Use native `apply_patch` to create,
revise, or delete only your own draft. Shell staging and shell cleanup are blocked.
Writes to transport messages, other panes' drafts, queue/archive/ledger state, symlinks,
hardlinks, moves, and patches mixing drafts with other files are forbidden.
If the messages grant or native writer is unavailable, report the missing
capability; do not truncate the reply or fall back to shell interpolation.
With session-workspace 0.10.0, read a complete incoming or sent dispatch with
the literal `cat '<absolute-path>'` command shown by the hook, under the
existing incoming-mode consent rules. Inline truncation is not a task-size
limit. The file must be a private regular top-level payload in the validated
messages grant, uniquely addressed to or sent by this pane in the validated
topology, without symlinks or traversal. Own existing drafts are readable too.
Outside this harness, create a temporary directory with `mktemp -d` in a separate
shell call and use a native tool to write the file there.

1. Use `apply_patch` to add the chosen `<draft-path>` containing the verbatim
   reply. Never embed reply text in a heredoc, `echo`, `printf`, command
   substitution, or interpreter `-c` string.
2. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/dispatch-to-session.sh" --reply-to "<message-id>" "<pane-name>" "<draft-path>"
   ```

3. After `Dispatched ...` or durable `Queued ...` success, delete your own draft
   with `apply_patch`. Keep it after a hard failure for retry after fixing the
   cause. Never resend a queued success. Outside the harness, also remove the
   empty temporary directory.

If the reply id is invalid, relay the validation error and stop. If tmux is not
active, explain that replies require tmux. For target, duplicate-name, busy, or
sandbox-denial errors, follow the same guidance as `$session-chat:send` and
`$session-chat:dispatch`.
