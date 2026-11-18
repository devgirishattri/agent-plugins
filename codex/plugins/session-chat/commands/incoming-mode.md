---
description: Show or explain session-chat incoming message mode
argument-hint: "[notify|assist|auto|off]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Read the optional mode from `$ARGUMENTS`. With no mode, run the helper as shown. For `notify`, `assist`, `auto`, or `off`, append that one mode as a literal argument.

   ```bash
   bash "$PLUGIN_ROOT/scripts/incoming-mode.sh"
   ```

3. If no argument is provided, report the current mode and mode descriptions.
4. For a valid mode, relay the printed export. Apply the printed `export SESSION_CHAT_INCOMING_MODE=<mode>` in the recipient's launcher or parent shell, then relaunch the agent so it inherits that value.
5. If the mode is invalid, tell the user to use one of `notify`, `assist`, `auto`, or `off`.
