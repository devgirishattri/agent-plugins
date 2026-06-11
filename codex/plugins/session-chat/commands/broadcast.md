---
description: Send one short message to every named tmux pane (current session or all)
argument-hint: [--all] [--match GLOB] <message>
---

## Instructions

`/broadcast` fans out a **short, single-line** message to every named pane except this one — status pings, "sync now" nudges, fleet-wide notices. Per-target delivery is identical to `/send` (durable enqueue, live paste, queued fallback).

1. Parse `$ARGUMENTS`: optional `--all` (every tmux session instead of just the current one), optional `--match <glob>` (e.g. `--match 'worker-*'`), everything after is the message.
2. If the message is missing, tell the user: `Usage: /broadcast [--all] [--match GLOB] <message>`.
3. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.15.4}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
   ```

4. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/broadcast-message.sh" [--all] [--match "<glob>"] "<message>"
   ```

5. Present the per-target TSV results (`sent`/`queued`/`failed` per pane) as a short markdown table, then the summary line.
6. If a target failed, suggest `/pane-health <name>` to diagnose it.
7. If there is an error about no name, tell the user to run `/whoami <name>` first.
8. If no panes matched, suggest `/panes` to show what is available.
