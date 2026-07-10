---
description: Send one short message to every named tmux pane (current session or all)
argument-hint: "[--all] [--match GLOB] <message>"
---

## Instructions

`$session-chat:broadcast` fans out a **short, single-line** message to every named pane except this one. Per-target delivery is identical to `$session-chat:send`.

1. Parse `$ARGUMENTS`: optional `--all` (every tmux session instead of just the current one), optional `--match <glob>` (e.g. `--match 'worker-*'`), everything after is the message.
2. If the message is missing, tell the user: `Usage: $session-chat:broadcast [--all] [--match GLOB] <message>`.
3. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

4. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/broadcast-message.sh" [--all] [--match "<glob>"] "<message>"
   ```

5. Present the per-target TSV results (`sent`/`queued`/`failed` per pane) as a short markdown table, then the summary line.
6. If a target failed, suggest `$session-chat:pane-health <name>`.
7. If there is an error about no name, suggest `$session-chat:whoami <name>`.
8. If no panes matched, suggest `$session-chat:panes`.
