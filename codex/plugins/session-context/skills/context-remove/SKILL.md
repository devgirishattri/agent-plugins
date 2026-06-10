---
name: context-remove
description: "Remove a saved session context snapshot for the current Codex project."
---

# Context Remove

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-context/0.3.0}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-context"
```

If no snapshot name is provided, tell the user:

```text
Usage: $session-context:context-remove <snapshot-name>
```

Run:

```bash
bash "$PLUGIN_ROOT/scripts/remove-context.sh" "<snapshot-name>"
```

If the snapshot was removed, confirm the name. If no snapshot is found, suggest `$session-context:context-list`.
