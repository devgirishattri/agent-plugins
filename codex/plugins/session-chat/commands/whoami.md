---
description: Show or set this session's tmux pane name for messaging
argument-hint: [name]
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.13.1}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
   ```

2. Run this to read the current pane name:

   ```bash
   bash "$PLUGIN_ROOT/scripts/get-my-name.sh"
   ```

3. If a current name is shown and `$ARGUMENTS` is empty, report: `This pane is named **<name>**. Other sessions can reach you via /send <name> <message>.`
4. If `$ARGUMENTS` is provided, validate that it only contains letters, numbers, hyphens, and underscores, then run:

   ```bash
   bash -lc 'source "$0/scripts/lib.sh" && set_pane_name "$TMUX_PANE" "$1"' "$PLUGIN_ROOT" "<name>"
   ```

5. Report: `Pane renamed to **<name>**.`
6. If both current name and `$ARGUMENTS` are empty, report: `No name set. Use /whoami <name> to set one.`
