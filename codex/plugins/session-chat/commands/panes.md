---
description: List all named tmux panes across all sessions
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.9.4}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
   ```

2. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/list-panes.sh"
   ```

3. Present the tab-separated output as a markdown table:

   ```text
   | Name | Pane | Command | Location |
   ```

Rules:
- If no panes are listed, tell the user no named panes were found.
- Suggest `/whoami <name>` to name the current pane.
- Suggest `/send <name> <message>` to message a pane.
