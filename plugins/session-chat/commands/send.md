---
description: Send a message to another named tmux pane (any session, any repo)
argument-hint: "[--task TASK_ID] <pane-name> <message>"
allowed-tools: Bash(bash:*)
---

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. Run the script directly and report only the result.

`/send` is for **short, single-line** messages (status, acks, replies). The script refuses payloads with newlines or >1024 chars. For those, use `/dispatch`. See the `session-chat` skill for the full decision table and recipient prerequisites.

1. Parse $ARGUMENTS. Optional flags come first. `--priority high` surfaces the message before normal messages if queued. `--ttl <minutes>` drops the message instead of surfacing it if still queued after the window. `--task <task-id>` tags the message with a task (letters, digits, `_`, `-`) by putting a `[task:<task-id>]` token at the very start of the message. `/check-replies --task <task-id>` then lists the tagged requests and replies. Then comes the target pane name. Everything after is the message.
2. Run the send script with properly quoted arguments:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh [--priority high] [--ttl <minutes>] [--task <task-id>] "<target-name>" "<message>"
   ```
3. If the output says "Sent to ..." (delivered live) or "Queued to ..." (recipient busy), report success. "Queued to ..." is durable delivery. It surfaces on the recipient's next turn.
4. If the error mentions newlines or length, retry with `/dispatch <target> <message>`.
5. If the error is about no name, tell the user to run `/whoami <name>` first.
6. If the target is not found, run `/panes` to show available targets.
7. If the error mentions duplicate names, ask the user to rename one pane via `/whoami`.
8. A busy recipient yields a "Queued to ..." result. That result is durable success, so **do not retry it**. It arrives on the recipient's next turn, and resending duplicates it. Raising `SESSION_CHAT_VERIFY_TIMEOUT_MS` only makes more sends land *live*. It does not affect delivery. Retry only a hard failure (no name, unknown or ambiguous target), and only after fixing the named cause.
