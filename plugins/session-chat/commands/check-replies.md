---
description: Show which sent messages have a correlated reply and which are still unconfirmed
argument-hint: "[--pending] [--since MINUTES] [--task TASK_ID]"
allowed-tools: Bash(bash:*)
---

## Sent-Message Status

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-replies.sh" $ARGUMENTS`

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. Render the result directly.

Present the tab-separated data above as a markdown table:

| ID | To | Type | Delivery | Age | Reply | Excerpt | Task |

Rules:
- A request with several replies has one row per reply (each with its own Task). The Reply column says how far each reply is verified:
  - `verified:<pane>` — the reply came from the pane the request went to, and it was recorded as received by this pane.
  - `replied (recipient-unknown):<pane>` — an older reply record with no recorded receiver. The sender matches, but receipt by this pane is not evidenced. Do not call it verified.
  - `unexpected:<pane> (...)` — a reply from another pane, or recorded as received by another pane or without receiver context. It is not an answer. A later `verified` reply still counts.
- `unconfirmed` rows are messages with no correlated `[re:<id>]` reply token yet. List them first if the user asked what is pending. `unconfirmed` tracks reply **correlation only**. It does NOT show whether the recipient is alive or working the task. Never present `unconfirmed` as "the pane is stuck/dead".
- The script matches replies by the `[re:<id>]` token at the very start of an incoming message body (then an optional `[task:<id>]`); a `[re:<id>]` quoted later in a body is ignored. When you ask a pane to respond, tell it to answer with `/reply <your-pane> <this message's id> <text>`. That command adds the `[re:<id>]` token automatically. The pane must not type the token by hand.
- Use `--task <task-id>` to show only replies tagged `[task:<task-id>]` (and requests sent with that task). Use `--pending` to show only unconfirmed messages. Use `--since <minutes>` to widen or narrow the look-back window (default 24h).
- If a message has been `unconfirmed` for a long time, suggest `/pane-health <name>` to check whether the recipient is alive and reachable. A live pane may simply not have replied yet.
