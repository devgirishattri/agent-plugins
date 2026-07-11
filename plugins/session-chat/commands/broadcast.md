---
description: Send one short message to every named tmux pane (current session or all)
argument-hint: "[--all] [--match GLOB] <message>"
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate or add a preamble. Run the script directly and report only the result.

`/broadcast` fans out a **short, single-line** message to every named pane except this one — status pings, "sync now" nudges, fleet-wide notices. Per-target delivery is identical to `/send` (durable enqueue, live paste, queued fallback).

1. Parse $ARGUMENTS: optional `--all` (every tmux session instead of just the current one), `--match <glob>` (e.g. `--match 'worker-*'`), `--priority high`, and `--ttl <minutes>`; everything after is the message
2. Run the broadcast script with properly quoted arguments:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/broadcast-message.sh [--all] [--match "<glob>"] [--priority high] [--ttl <minutes>] "<message>"
   ```
3. Present the per-target TSV results (`sent`/`queued`/`failed` per pane) as a short markdown table, then the summary line
4. If a target failed, suggest `/pane-health <name>` to diagnose it
5. If the error is about no name, tell the user to run `/whoami <name>` first
6. If no panes matched, run `/panes` to show what is available
7. If the error mentions the tmux socket was denied (`Operation not permitted`), do NOT treat it as "no panes" or "no name" — surface the error verbatim, including its escalated/approved retry hint, so the user re-runs the broadcast with the exec approved rather than assuming there were no targets
