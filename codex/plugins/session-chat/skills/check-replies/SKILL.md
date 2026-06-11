---
name: check-replies
description: "Show which session-chat messages this pane sent have been answered and which still await a reply. Use when the user asks who has replied, what is pending, or whether a worker answered."
---

# Check Replies

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.15.3}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
```

Parse optional `--pending` (only unanswered messages) and optional `--since <minutes>` (look-back window, default 1440 = 24h).

Run:

```bash
bash "$PLUGIN_ROOT/scripts/check-replies.sh" [--pending] [--since <minutes>]
```

Present the tab-separated output as a table: ID, To, Type, Delivery, Age, Reply, Excerpt.
`awaiting` rows are messages nobody has answered yet — list them first if the user asked what is pending.
Replies are matched by `[re:<id>]` tokens in incoming messages; when asking a pane to respond, tell it to include `[re:<id>]` in its reply.
If a message has been awaiting for a long time, suggest `$session-chat:pane-health <name>` to check the recipient.
