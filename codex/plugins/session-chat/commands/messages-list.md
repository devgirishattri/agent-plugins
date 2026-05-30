---
description: List trusted session-chat dispatch message files
argument-hint: [--older-than 7d] [--sender name] [--recipient name]
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.13.2}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
   ```

2. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/list-messages.sh" $ARGUMENTS
   ```

3. Present the tab-separated output as file, age in seconds, size in bytes, sender, and recipient.
4. This command is read-only.
