---
description: Send a message to another named tmux pane (any session, any repo)
argument-hint: <pane-name> <message>
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate or add a preamble. Run the script directly and report only the result.

`/send` is for **short, single-line** messages (status, acks, replies). The script refuses payloads with newlines or >1024 chars — for those, use `/dispatch`. See the `session-chat` skill for the full decision table and recipient prerequisites.

1. Parse $ARGUMENTS: optional `--priority high` (surfaces before normal messages if queued) and `--ttl <minutes>` (drop instead of surfacing if still queued after the window) come first; then the target pane name; everything after is the message
2. Run the send script with properly quoted arguments:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh [--priority high] [--ttl <minutes>] "<target-name>" "<message>"
   ```
3. If the output says "Sent to ..." (delivered live) or "Queued to ..." (recipient busy — durable delivery, surfaces on their next turn), confirm success to the user. **Do not resend a "Queued" result** — it is not lost, and resending duplicates it.
4. If the error mentions newlines or length, retry with `/dispatch <target> <message>`
5. If the error is about no name, tell the user to run `/whoami <name>` first
6. If the target is not found, run `/panes` to show available targets
7. If the error mentions duplicate names, ask the user to rename one pane via `/whoami`
8. A busy recipient yields a "Queued to ..." result (durable success) — **do not retry it**; it arrives on the recipient's next turn and resending duplicates it. Raising `SESSION_CHAT_VERIFY_TIMEOUT_MS` only makes more sends land *live*; it does not affect delivery. Retry only a hard failure (no name, unknown/ambiguous target) after fixing the named cause.
