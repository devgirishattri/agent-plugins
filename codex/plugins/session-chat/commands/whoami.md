---
description: Show or set this session's tmux pane name for messaging
argument-hint: "[name]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Run this to read the current pane name:

   ```bash
   bash "$PLUGIN_ROOT/scripts/get-my-name.sh"
   ```

3. If a current name is shown and `$ARGUMENTS` is empty, report: `This pane is named **<name>**. Other sessions can reach you via $session-chat:send <name> <message>.`
4. If `$ARGUMENTS` is provided, validate that it only contains letters, numbers, hyphens, and underscores, then run:

   ```bash
   bash -lc 'source "$0/scripts/lib.sh" && set_pane_name "$TMUX_PANE" "$1"' "$PLUGIN_ROOT" "<name>"
   ```

5. Report: `Pane renamed to **<name>**.`
6. If both current name and `$ARGUMENTS` are empty, report: `No name set. Use $session-chat:whoami <name> to set one.`
