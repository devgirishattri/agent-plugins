---
name: context-load
description: "Load a previously saved session-chat context snapshot into the current Codex session."
---

# Context Load

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.9.5}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
```

If no snapshot name is provided, tell the user:

```text
Usage: $session-chat:context-load <snapshot-name>
```

Run:

```bash
bash "$PLUGIN_ROOT/scripts/load-context.sh" "<snapshot-name>"
```

Internalize the loaded context and summarize what was loaded.
