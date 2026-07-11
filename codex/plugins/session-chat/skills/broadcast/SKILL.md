---
name: broadcast
description: "Send one short message to every named tmux pane at once through session-chat. Use when the user asks to ping, notify, or message all panes, all workers, or the whole fleet."
---

# Broadcast

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from cwd or hardcode a marketplace cache version.

Parse optional `--all` (every tmux session instead of just the current one) and optional `--match <glob>` (e.g. `--match 'worker-*'`); the rest is the single-line message. If the message is missing, tell the user:

```text
Usage: $session-chat:broadcast [--all] [--match GLOB] <message>
```

Run:

```bash
bash "$PLUGIN_ROOT/scripts/broadcast-message.sh" [--all] [--match "<glob>"] "<message>"
```

Present the per-target TSV results (`sent`/`queued`/`failed` per pane) as a short table, then the summary line.
If the script returns non-zero because a sandbox denied the tmux socket, relay
that error and rerun the whole script escalated/approved; do not reinterpret it
as an unnamed sender or an empty target set.
If a target failed, suggest `$session-chat:pane-health <name>` to diagnose it.
If this pane has no name, suggest `$session-chat:whoami <name>`.
If no panes matched, suggest `$session-chat:panes`.
