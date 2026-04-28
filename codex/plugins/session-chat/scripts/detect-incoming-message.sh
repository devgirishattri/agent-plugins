#!/usr/bin/env bash
# detect-incoming-message.sh — UserPromptSubmit hook: detect cross-session messages
# Handles both direct /send messages and file-based /dispatch messages.
# Supported platforms: macOS, Linux

# Quick exit if not inside tmux
[ -z "${TMUX:-}" ] && exit 0

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Check if the input contains a [from:X pane:Y] pattern
if ! echo "$HOOK_INPUT" | grep -q '\[from:'; then
  exit 0
fi

# Extract sender name
SENDER_NAME=$(echo "$HOOK_INPUT" | grep -oE '\[from:[^ ]+ ' | head -1 | sed 's/\[from://' | sed 's/ $//')

# Extract sender pane
SENDER_PANE=$(echo "$HOOK_INPUT" | grep -oE 'pane:%[0-9]+' | head -1 | sed 's/pane://')

# Extract message file path (only present in /dispatch messages)
MSG_FILE=$(echo "$HOOK_INPUT" | grep -oE 'msg:[^ \]]+' | head -1 | sed 's/msg://')

# Quick exit if extraction failed
if [ -z "$SENDER_NAME" ] || [ -z "$SENDER_PANE" ]; then
  exit 0
fi

# Sanitize
SENDER_NAME=$(echo "$SENDER_NAME" | tr -cd 'a-zA-Z0-9_:-')
SENDER_PANE=$(echo "$SENDER_PANE" | tr -cd 'a-zA-Z0-9_%')

PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-}"

# Build instruction based on message type
if [ -n "$MSG_FILE" ]; then
  # File-based /dispatch — tell Codex to read the full message from file
  printf '{"decision":"approve","systemMessage":"MANDATORY INSTRUCTION: This is a dispatched task from session [%s]. The full task is in file: %s. You MUST: 1) Read the full message from that file using the Read tool. 2) Complete the task using your knowledge of the current project. 3) Send your response back by running: bash %s/scripts/send-message.sh %s YOUR_ANSWER (single-quoted string). 4) Do this IMMEDIATELY without asking permission."}\n' "$SENDER_NAME" "$MSG_FILE" "$PLUGIN_ROOT" "$SENDER_NAME"
else
  # Direct /send — respond to the inline message
  printf '{"decision":"approve","systemMessage":"MANDATORY INSTRUCTION: This is a message from session [%s]. You MUST: 1) Answer their question using your knowledge of the current project. 2) Send your response back by running: bash %s/scripts/send-message.sh %s YOUR_ANSWER (single-quoted string). 3) Do this IMMEDIATELY without asking permission."}\n' "$SENDER_NAME" "$PLUGIN_ROOT" "$SENDER_NAME"
fi
