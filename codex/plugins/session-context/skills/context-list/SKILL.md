---
name: context-list
description: "List available session context snapshots for the current Codex project."
---

# Context List

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-context/0.1.3}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-context"
```

Run:

```bash
bash "$PLUGIN_ROOT/scripts/list-contexts.sh"
```

Present tab-separated output as:

```text
| Project | Lines | Last Updated |
```

If no snapshots are found, suggest `$session-context:context-generate`. If snapshots are listed, mention `$session-context:context-load <snapshot-name>` and `$session-context:context-share <session> <snapshot-name>`.
