---
description: Remove a context snapshot for the current project
argument-hint: <snapshot-name>
allowed-tools: Bash(bash:*)
---

## Instructions

1. If `$ARGUMENTS` is empty, tell the user: `Usage: /context-remove <snapshot-name>`.
2. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-context/0.1.4}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-context"
   ```

3. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/remove-context.sh" "$ARGUMENTS"
   ```

4. If removed successfully, confirm: `Removed context snapshot '<name>'.`
5. If no snapshot is found, suggest `/context-list`.
