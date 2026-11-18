---
description: Show or set the recipient-side SESSION_CHAT_INCOMING_MODE
argument-hint: "[auto|assist|notify|off]"
allowed-tools: Bash(bash:*)
---

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. Run the script directly and report only the result.

`SESSION_CHAT_INCOMING_MODE` controls how this pane reacts to incoming `/send` and `/dispatch` messages. The default is `notify`, which forbids reading dispatch files. Orchestration requires `auto` or `assist`.

Requested mode: `$ARGUMENTS`

1. If the requested mode above is empty, run the helper as shown to report the current mode. If it is `notify`, `assist`, `auto`, or `off`, append that one mode as a literal argument.
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/incoming-mode.sh"
   ```

2. With no mode, the script reports the current mode and explains the four modes. Relay that output verbatim.

3. For a valid mode, relay the helper's printed export line. Apply the printed `export SESSION_CHAT_INCOMING_MODE=<mode>` in the recipient's launcher or parent shell, then relaunch the agent so it inherits that value.

4. If the script errors on an invalid mode, surface its message. Then list the four valid modes.
