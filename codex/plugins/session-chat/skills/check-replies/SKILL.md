---
name: check-replies
description: "Show which session-chat messages this pane sent have confirmed correlated replies and which remain unconfirmed. Use when the user asks who replied or whether a response was correlated; this is not task-liveness status."
---

# Check Replies

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from cwd or hardcode a marketplace cache version.

Parse optional `--pending` (only unanswered messages) and optional `--since <minutes>` (look-back window, default 1440 = 24h).

Run:

```bash
bash "$PLUGIN_ROOT/scripts/check-replies.sh" [--pending] [--since <minutes>]
```

Present the tab-separated output as a table: ID, To, Type, Delivery, Age, Reply, Excerpt.
`unconfirmed` means no correlated reply has arrived; it does not prove that the
recipient is still working or that a scheduler task remains active. List those
rows first if the user asks what is pending.
Replies are matched by transport-generated `[re:<id>]` tokens. Use
`$session-chat:reply <pane> <id> <message>` instead of asking a person or agent
to type the token manually.
If a message stays unconfirmed for a long time, suggest
`$session-chat:pane-health <name>` and check the scheduler ledger separately.
