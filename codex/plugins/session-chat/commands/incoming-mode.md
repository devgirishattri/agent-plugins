---
description: Show or explain session-chat incoming message mode
argument-hint: "[notify|assist|auto|off]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Use the helper with no arguments to show the current mode. To explain a change, append exactly one valid mode (`notify`, `assist`, `auto`, or `off`).

   ```bash
   bash "$PLUGIN_ROOT/scripts/incoming-mode.sh"
   ```

3. If no argument is provided, report the current mode and mode descriptions.
4. For a valid mode, relay the printed export. Apply the printed `export SESSION_CHAT_INCOMING_MODE=<mode>` in the recipient's launcher or parent shell, then relaunch the agent so it inherits that value.
5. If the mode is invalid, tell the user to use one of `notify`, `assist`, `auto`, or `off`.
