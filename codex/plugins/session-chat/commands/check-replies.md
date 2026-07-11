---
description: Show which sent messages have confirmed correlated replies
argument-hint: "[--pending] [--since MINUTES]"
---

## Instructions

1. Parse `$ARGUMENTS`: optional `--pending` (only unanswered messages) and optional `--since <minutes>` (look-back window, default 1440 = 24h).
2. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

3. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/check-replies.sh" [--pending] [--since <minutes>]
   ```

4. Present the tab-separated output as a markdown table: | ID | To | Type | Delivery | Age | Reply | Excerpt |
5. `unconfirmed` means no correlated reply has arrived; it is not task-liveness
   evidence. List those rows first if the user asks what is pending.
6. Use `$session-chat:reply <pane> <id> <message>` so the transport generates
   `[re:<id>]`; never ask an agent to type the token manually.
7. If a message stays unconfirmed, suggest `$session-chat:pane-health <name>`
   and check scheduler task status separately.
