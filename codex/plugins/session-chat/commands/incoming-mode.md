---
description: Show or explain session-chat incoming message mode
argument-hint: "[notify|assist|auto|off]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/incoming-mode.sh" "$ARGUMENTS"
   ```

3. If no argument is provided, report the current mode and mode descriptions.
4. If a mode is provided, show the `export SESSION_CHAT_INCOMING_MODE=<mode>` line and explain that the user must run it in the shell that starts Codex, then restart or reload the session.
5. If the mode is invalid, tell the user to use one of `notify`, `assist`, `auto`, or `off`.
