---
name: session-search
description: "Search local Codex sessions by title, session ID, or project path."
---

# Session Search

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-plugins/session-manager/1.7.1}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-manager"
```

If no query is provided, tell the user:

```text
Usage: $session-manager:session-search <query>
```

Run:

```bash
bash "$PLUGIN_ROOT/scripts/search-sessions.sh" "<query>"
```

Present tab-separated output as:

```text
| Thread | Session ID | Project | Size | Last Modified |
```
