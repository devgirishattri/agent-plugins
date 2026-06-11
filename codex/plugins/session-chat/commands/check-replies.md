---
description: Show which sent messages have been answered and which are still awaiting a reply
argument-hint: [--pending] [--since MINUTES]
---

## Instructions

1. Parse `$ARGUMENTS`: optional `--pending` (only unanswered messages) and optional `--since <minutes>` (look-back window, default 1440 = 24h).
2. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.16.0}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
   ```

3. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/check-replies.sh" [--pending] [--since <minutes>]
   ```

4. Present the tab-separated output as a markdown table: | ID | To | Type | Delivery | Age | Reply | Excerpt |
5. `awaiting` rows are messages nobody has answered yet — list them first if the user asked what is pending.
6. Replies are matched by `[re:<id>]` tokens in incoming messages; when asking a pane to respond, tell it to include `[re:<id>]` in its reply.
7. If a message has been `awaiting` for a long time, suggest `/pane-health <name>` to check the recipient.
