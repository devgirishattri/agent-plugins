---
name: context-load
description: "Load a previously saved session-chat context snapshot into the current Codex session."
---

# Context Load

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.9.6}"
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
