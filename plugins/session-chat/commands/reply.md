---
description: Reply to a received message, auto-correlating it via the message id
argument-hint: "[--task TASK_ID] <pane> <message-id> <message>"
allowed-tools: Bash(bash:*), Write
---

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. Run the action directly and report only the result.

`/reply` responds to a message you received and **automatically correlates** the reply. The transport prepends the `[re:<id>]` token for you, so the original sender's `/check-replies` matches it. Never type `[re:<id>]` yourself. Pass the id and let `--reply-to` add it exactly once. See the `session-chat` skill for the delivery contract.

The token goes at the very start of the message body. Only that leading position correlates; a `[re:<id>]` quoted later in a body is plain text and does not count. To tag a reply with a task, add `--task <task-id>`. The transport then writes `[re:<id>] [task:<task-id>]` in that order. A reply with several task-tagged parts is one `/reply` per task.

`/reply` is a command, not a shell executable. There is no `reply.sh` or `session-chat reply` binary. Always run the installed `send-message.sh` or `dispatch-to-session.sh` helper with `--reply-to` as shown below.

1. Parse $ARGUMENTS as `[--task <task-id>] <pane> <message-id> <message>`. Pass `--task <task-id>` through to the script only when the user gave it. Then parse the rest:
   - `<pane>` — the sender's pane name (the `[from:<name> …]` in the message you received)
   - `<message-id>` — the `id:<hex>` from that same received message (8–16 lowercase hex)
   - everything after — your reply text
   If the message id is missing or is not 8–16 lowercase hex characters, stop. Tell the user: "`/reply <pane> <message-id> <message>` — the message id is the `id:<hex>` shown in the message you're answering."

2. Choose the transport by the reply's shape:
   - **Short and single-line** (no newlines, ≲1000 chars) → `/send` transport:
     ```
     bash ${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh --reply-to <message-id> [--task <task-id>] "<pane>" "<message>"
     ```
   - **Long or multiline** → `/dispatch` transport with **data-safe staging**. Never embed the body in a shell heredoc or command, because arbitrary content is unsafe as shell source:
     1. Choose a fresh temp path (e.g. `$(mktemp)` via a separate Bash call, or a file under your scratchpad dir). **Under an active strict-v1 harness as a child pane**, use only your own drafts directory: `<messages-grant>/drafts/<your-pane-name>/reply-<message-id>-<nonce>.md`. Follow "Staging files under a strict-v1 harness" in the `session-chat` skill. With no `messages` grant, report that the grant is missing. Do not shorten a long reply to fit a single-line send.
     2. Use the **Write tool** to write the **verbatim reply body** to that path. Never interpolate the body into a bash command.
     3. Dispatch it. The script reads the file with `cat`, so nothing in it is shell-evaluated:
        ```
        bash ${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-to-session.sh --reply-to <message-id> [--task <task-id>] "<pane>" "<prompt-file-path>"
        ```
     4. Under strict-v1, the transport removes your own draft after a delivered or queued result (`Removed delivered draft: …`); do not delete it yourself. Outside strict-v1, optionally run `rm -f "<prompt-file-path>"` for a temp file. After a hard failure, keep the draft for the retry.
   - Put a complete verdict or packet in **one** reply. Do not send a short reply and then follow-ups that complete it. A correction is one full replacement packet that names the message id it replaces.

3. Report the result:
   - "Sent to …" or "Dispatched task to …" (delivered live), or "Queued …" (recipient busy; durable, surfaces on their next turn) → report success. Note that the reply is correlated: the sender's `/check-replies` will mark id `<message-id>` answered.
   - If `--reply-to` reports an invalid id, re-check the `id:<hex>` from the received message.
   - If the error is about no name, tell the user to run `/whoami <name>` first.
   - If the target is not found, run `/panes` to show available targets.
   - If it mentions duplicate names, ask the user to rename one pane via `/whoami`.
   - A busy recipient yields a "Queued …" result. That result is durable success, so **do not resend**. It arrives on their next turn, and resending duplicates it. Retry only a hard failure, and only after fixing its named cause.
