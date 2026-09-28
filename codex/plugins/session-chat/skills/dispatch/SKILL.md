---
name: dispatch
description: "Dispatch a task prompt to another named tmux pane through session-chat. Use when the user asks to assign work, dispatch a task, or send a tracked task to another Codex session."
---

# Dispatch

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from cwd or hardcode a marketplace cache version.

Parse the first argument as the target pane name and the rest as the task prompt. If either is missing, tell the user:

```text
Usage: $session-chat:dispatch <pane-name> <task prompt>
```

If this is a response to an incoming session-chat message or dispatch, use
`$session-chat:reply <pane> <incoming-id> <message>` instead so reply
correlation cannot be omitted.

Stage the prompt as data, never as shell source:

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
With session-workspace 0.10.0, the recipient can read the complete delivered
copy using the literal `cat '<absolute-path>'` command shown by the incoming
hook. The helper saves it directly in the validated messages grant as
`<epoch>-<pid>-<id>-<sender>-to-<recipient>.md`. Inline truncation never requires
splitting a task. Executor/reviewer reads require self as sender or recipient,
unique validated topology endpoints, and a private regular file without
symlinks or traversal. Existing own drafts are readable; sending routes and
incoming-mode consent remain unchanged.
Outside this harness, create a temporary directory with `mktemp -d` in a separate
shell call and use a native tool to write the file there.

1. Use `apply_patch` to add `<draft-path>` with the verbatim prompt body.
   Never embed prompt text in a shell heredoc, `echo`, `printf`, command
   substitution, or an interpreter `-c` string.
2. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/dispatch-to-session.sh" [--priority high] [--ttl <minutes>] [--reply-to <incoming-id>] "<target>" "<draft-path>"
   ```

3. After `Dispatched ...` or durable `Queued ...` success, delete your own draft
   with `apply_patch`; outside the harness, also remove the empty temporary
   directory. Keep the draft after a hard failure for retry after fixing its
   cause. Never resend a queued success.

If tmux is not active, explain that dispatch requires running Codex inside tmux.
If the target is not found, suggest `$session-chat:panes`. If this pane has no name, suggest `$session-chat:whoami <name>`.
Relay the script's `Dispatched task ...` or `Queued dispatch ...` result accurately. For either successful result, mention that the recipient must use `SESSION_CHAT_INCOMING_MODE=auto` or `assist` to read and act on the task; default `notify` only reports that a dispatch arrived.
If the output reports multiple panes named the same target, tell the user to rename one pane with `$session-chat:whoami <name>`.
If a live timeout is followed by `Queued dispatch ...`, report durable queued success and do not retry. Raise `SESSION_CHAT_VERIFY_TIMEOUT_MS` only when immediate live delivery matters. Retry only a hard failure that did not queue, after fixing its cause.
