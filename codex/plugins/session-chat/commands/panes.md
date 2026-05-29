---
description: List named tmux panes in the current tmux session, or all sessions
argument-hint: [all]
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.12.3}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
   ```

2. Run:

   ```bash
   ARGUMENTS="${ARGUMENTS:-}"
   bash "$PLUGIN_ROOT/scripts/list-panes.sh" "$ARGUMENTS"
   ```

3. By default, this lists named panes in the current tmux session only. If `all` is provided, it lists named panes across all tmux sessions.
4. Present the tab-separated output as a markdown table:

   ```text
   | Name | Pane | Command | Location |
   ```

Rules:
- If no panes are listed, tell the user no named panes were found.
- Suggest `/whoami <name>` to name the current pane.
- Suggest `/send <name> <message>` to message a pane.
- Mention `/panes all` only when the user needs panes from every tmux session.
