---
description: Reply to a received message, auto-correlating it via the message id
argument-hint: <pane> <message-id> <message>
allowed-tools: Bash(bash:*), Write
---

## Instructions

Do not narrate or add a preamble. Run the action directly and report only the result.

`/reply` responds to a message you received and **automatically correlates** the reply: the transport prepends the `[re:<id>]` token for you, so the original sender's `/check-replies` matches it. Never type `[re:<id>]` yourself — pass the id and let `--reply-to` add it exactly once. See the `session-chat` skill for the delivery contract.

1. Parse $ARGUMENTS as `<pane> <message-id> <message>`:
   - `<pane>` — the sender's pane name (the `[from:<name> …]` in the message you received)
   - `<message-id>` — the `id:<hex>` from that same received message (8–16 lowercase hex)
   - everything after — your reply text
   If the message id is missing or is not 8–16 lowercase hex characters, stop and tell the user: "`/reply <pane> <message-id> <message>` — the message id is the `id:<hex>` shown in the message you're answering."

2. Choose the transport by the reply's shape:
   - **Short and single-line** (no newlines, ≲1000 chars) → `/send` transport:
     ```
     bash ${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh --reply-to <message-id> "<pane>" "<message>"
     ```
   - **Long or multiline** → `/dispatch` transport with **data-safe staging** (never embed the body in a shell heredoc/command — arbitrary content is unsafe as shell source):
     1. Choose a fresh temp path (e.g. `$(mktemp)` via a separate Bash call, or a file under your scratchpad dir).
     2. Use the **Write tool** to write the **verbatim reply body** to that path — never interpolate the body into a bash command.
     3. Dispatch it (the script reads the file with `cat`; nothing in it is shell-evaluated):
        ```
        bash ${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-to-session.sh --reply-to <message-id> "<pane>" "<prompt-file-path>"
        ```
     4. Optionally `rm -f "<prompt-file-path>"` afterward.

3. Report the result:
   - "Sent to …" / "Dispatched task to …" (delivered live) or "Queued …" (recipient busy — durable, surfaces on their next turn) → confirm success, and note the reply is correlated (the sender's `/check-replies` will mark id `<message-id>` answered). **Do not resend a "Queued" reply** — it is not lost, and resending duplicates it.
   - If `--reply-to` reports an invalid id, re-check the `id:<hex>` from the received message.
   - If the error is about no name, tell the user to run `/whoami <name>` first.
   - If the target is not found, run `/panes` to show available targets.
   - If it mentions duplicate names, ask the user to rename one pane via `/whoami`.
   - A busy recipient yields a "Queued …" result — durable success, **do not resend** (it arrives on their next turn and resending duplicates it). Retry only a hard failure after fixing its named cause.
