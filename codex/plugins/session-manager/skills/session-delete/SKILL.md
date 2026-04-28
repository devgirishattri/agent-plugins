---
name: session-delete
description: "Delete a local Codex session after resolving and confirming a full session UUID."
---

# Session Delete

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-manager/1.4.4}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-manager"
```

Resolve the target:

```bash
bash "$PLUGIN_ROOT/scripts/find-or-skip.sh" "<session-id-or-name>"
```

If exactly one session matches, show its details and ask for explicit confirmation. Only pass a full UUID to:

```bash
bash "$PLUGIN_ROOT/scripts/delete-session.sh" "<full-uuid>"
```

Never delete by partial ID or display name.
