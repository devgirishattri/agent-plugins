---
name: context-share
description: "Share a saved session context snapshot with another named tmux pane."
---

# Context Share

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-context/0.1.4}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-context"
```

Parse the first argument as the target session and the optional second argument as the snapshot name. If the target is missing, tell the user:

```text
Usage: $session-context:context-share <session-name> [snapshot-name]
```

If no snapshot name is provided, derive one from the current directory. Run:

```bash
bash "$PLUGIN_ROOT/scripts/share-context.sh" "<session-name>" "<snapshot-name>"
```

If tmux is not active, explain that sharing requires running Codex inside tmux.
If the snapshot does not exist, suggest `$session-context:context-generate <snapshot-name>`. If the target session is not found, suggest `$session-chat:panes`.
