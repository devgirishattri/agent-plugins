---
name: panes
description: "List named tmux panes available for session-chat messaging. Use when the user asks to list panes, show available sessions, find targets, or use panes."
---

# Panes

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.9.5}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
```

Run:

```bash
bash "$PLUGIN_ROOT/scripts/list-panes.sh"
```

Present tab-separated output as:

```text
| Name | Pane | Command | Location |
```

If the command says tmux is required or not active, explain that this action must run inside tmux. If no panes are listed, say no named panes were found and suggest `$session-chat:whoami <name>`.
