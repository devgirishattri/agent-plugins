---
description: Send a message to another named tmux pane (any session, any repo)
argument-hint: <pane-name> <message>
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate or add a preamble. Run the script directly and report only the result.

1. Parse $ARGUMENTS: first word is the target pane name, everything after is the message
2. Run the send script with properly quoted arguments:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh "<target-name>" "<message>"
   ```
3. If the output says "Sent to ...", confirm to the user
4. If there's an error about no name, tell the user to run `/whoami <name>` first
5. If the target is not found, run `/panes` to show available targets
