---
name: session-list
description: "List local Codex sessions for the current project or all projects. Use when the user asks to list sessions or inspect recent Codex sessions."
---

# Session List

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-manager/1.4.4}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-manager"
```

Run one of:

```bash
bash "$PLUGIN_ROOT/scripts/list-sessions.sh"
bash "$PLUGIN_ROOT/scripts/list-sessions.sh" all
```

Present tab-separated output as:

```text
| Name | Session ID | Project | Size | Last Modified |
```

Show full session IDs and a total count.
