---
description: Show which sent messages have been answered and which are still awaiting a reply
argument-hint: [--pending] [--since MINUTES]
allowed-tools: Bash(bash:*)
---

## Sent-Message Status

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-replies.sh" $ARGUMENTS`

## Instructions

Do not narrate or add a preamble. Render the result directly.

Present the tab-separated data above as a markdown table:

| ID | To | Type | Delivery | Age | Reply | Excerpt |

Rules:
- `awaiting` rows are messages nobody has answered yet — list them first if the user asked what is pending
- Replies are matched by `[re:<id>]` tokens in incoming messages; when asking a pane to respond, tell it to include `[re:<id>]` in its reply
- Use `--pending` to show only unanswered messages, `--since <minutes>` to widen or narrow the look-back window (default 24h)
- If a message has been `awaiting` for a long time, suggest `/pane-health <name>` to check the recipient
