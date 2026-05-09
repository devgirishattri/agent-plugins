---
description: Show or set the recipient-side SESSION_CHAT_INCOMING_MODE
argument-hint: [auto|assist|notify|off]
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate or add a preamble. Run the script directly and report only the result.

`SESSION_CHAT_INCOMING_MODE` controls how this pane reacts to incoming `/send` and `/dispatch` messages. Default is `notify`, which forbids reading dispatch files — orchestration requires `auto` or `assist`.

1. Run:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/incoming-mode.sh "$ARGUMENTS"
   ```

2. If `$ARGUMENTS` is empty, the script reports the current mode and explains the four modes. Relay that output verbatim.

3. If `$ARGUMENTS` is one of `auto`/`assist`/`notify`/`off`, the script prints an `export ...` line. Tell the user to `eval` it in their shell (or paste it into their shell rc to persist), since a child script cannot mutate the parent shell's environment.

4. If the script errors on an invalid mode, surface its message; suggest the four valid modes.
