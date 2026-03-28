---
description: Send a message to another named tmux pane (any session, any repo)
argument-hint: <pane-name> <message>
allowed-tools: Bash(bash:*)
---

## Send Message

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh $ARGUMENTS`

## Instructions

- If the output says "Sent to ...", confirm to the user
- If there's an error about no name, tell the user to run `/whoami <name>` first
- If the target is not found, run `/panes` to show available targets
