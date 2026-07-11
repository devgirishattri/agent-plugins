---
description: Show which sent messages have a correlated reply and which are still unconfirmed
argument-hint: "[--pending] [--since MINUTES]"
allowed-tools: Bash(bash:*)
---

## Sent-Message Status

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-replies.sh" $ARGUMENTS`

## Instructions

Do not narrate or add a preamble. Render the result directly.

Present the tab-separated data above as a markdown table:

| ID | To | Type | Delivery | Age | Reply | Excerpt |

Rules:
- `unconfirmed` rows are messages with no correlated `[re:<id>]` reply token yet — list them first if the user asked what is pending. This tracks reply **correlation only**, NOT whether the recipient is alive or working the task — never present `unconfirmed` as "the pane is stuck/dead"
- Replies are matched by `[re:<id>]` tokens in incoming messages; when asking a pane to respond, tell it to answer with `/reply <your-pane> <this message's id> <text>` (which adds the `[re:<id>]` token automatically) rather than hand-typing the token
- Use `--pending` to show only unconfirmed messages, `--since <minutes>` to widen or narrow the look-back window (default 24h)
- If a message has been `unconfirmed` for a long time, suggest `/pane-health <name>` to check whether the recipient is actually alive/reachable (a live pane may simply not have replied yet)
