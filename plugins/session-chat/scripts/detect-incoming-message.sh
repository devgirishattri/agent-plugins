#!/usr/bin/env bash
# detect-incoming-message.sh — UserPromptSubmit hook: detect cross-session messages
# and inject instructions for Claude to auto-respond back to the sender.
# Supported platforms: macOS, Linux
set -uo pipefail

# Quick exit if not inside tmux
[ -z "${TMUX:-}" ] && exit 0

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Extract the user's prompt from hook input
USER_PROMPT=$(echo "$HOOK_INPUT" | sed -n 's/.*"user_prompt":"\([^"]*\)".*/\1/p' | head -1)

# Quick exit if no prompt or doesn't match the [from:X pane:Y] pattern
if [ -z "$USER_PROMPT" ]; then
  exit 0
fi

# Check if prompt starts with [from: pattern (cross-session message)
if ! echo "$USER_PROMPT" | grep -qE '^\[from:[^ ]+ pane:[^ ]+\]'; then
  exit 0
fi

# Extract sender name and pane from the message header
SENDER_NAME=$(echo "$USER_PROMPT" | sed -n 's/^\[from:\([^ ]*\) pane:[^ ]*\].*/\1/p')
SENDER_PANE=$(echo "$USER_PROMPT" | sed -n 's/^\[from:[^ ]* pane:\([^ ]*\)\].*/\1/p')

if [ -z "$SENDER_NAME" ] || [ -z "$SENDER_PANE" ]; then
  exit 0
fi

# Inject system message instructing Claude to respond back
cat <<EOF
{"decision":"approve","systemMessage":"CROSS-SESSION MESSAGE: This prompt is a message from another Claude session named '${SENDER_NAME}' (pane ${SENDER_PANE}). Answer their question using your knowledge of the current project, then send your response back by running: bash ${CLAUDE_PLUGIN_ROOT}/scripts/send-message.sh ${SENDER_NAME} '<your concise answer>'. Keep the response concise (1-3 sentences). Do NOT ask the user for permission — answer and send back automatically."}
EOF
