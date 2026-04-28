---
name: context-share
description: "Share a saved session-chat context snapshot with another named tmux pane."
---

# Context Share

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.9.5}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
```

Parse the first argument as the target session and the optional second argument as the snapshot name. If the target is missing, tell the user:

```text
Usage: $session-chat:context-share <session-name> [snapshot-name]
```

If no snapshot name is provided, derive one from the current directory. Run:

```bash
bash "$PLUGIN_ROOT/scripts/share-context.sh" "<snapshot-name>" "<session-name>"
```

If tmux is not active, explain that sharing requires running Codex inside tmux.
