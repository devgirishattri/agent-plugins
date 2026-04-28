---
name: context-list
description: "List available session-chat context snapshots stored for Codex."
---

# Context List

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.9.5}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
```

Run:

```bash
bash "$PLUGIN_ROOT/scripts/list-contexts.sh"
```

Present tab-separated output as:

```text
| Project | Lines | Last Updated |
```
