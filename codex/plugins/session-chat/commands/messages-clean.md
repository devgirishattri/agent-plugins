---
description: Dry-run or delete trusted session-chat dispatch message files
argument-hint: [--older-than 7d] [--sender name] [--recipient name] [--apply]
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.14.0}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
   ```

2. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/clean-messages.sh" $ARGUMENTS
   ```

3. Without `--apply`, report that the output is a dry run.
4. With `--apply`, report the deleted count and total bytes.
5. If a duration is invalid, tell the user to use values like `7d`, `12h`, `30m`, or `60s`.
