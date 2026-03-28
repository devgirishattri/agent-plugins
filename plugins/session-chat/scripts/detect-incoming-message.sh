#!/usr/bin/env bash
# detect-incoming-message.sh — UserPromptSubmit hook: detect cross-session messages
# and inject instructions for Claude to auto-respond back to the sender.
# Supported platforms: macOS, Linux

# Quick exit if not inside tmux
[ -z "${TMUX:-}" ] && exit 0

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Check if the input contains a [from:X pane:Y] pattern anywhere
# (the user_prompt is embedded in the JSON, so search the whole input)
if ! echo "$HOOK_INPUT" | grep -q '\[from:'; then
  exit 0
fi

# Extract sender name: [from:SENDER_NAME pane:...]
SENDER_NAME=$(echo "$HOOK_INPUT" | grep -oE '\[from:[^ ]+ ' | head -1 | sed 's/\[from://' | sed 's/ $//')
# Extract sender pane: [from:... pane:SENDER_PANE]
SENDER_PANE=$(echo "$HOOK_INPUT" | grep -oE 'pane:[^]]+' | head -1 | sed 's/pane://')

# Quick exit if extraction failed
if [ -z "$SENDER_NAME" ] || [ -z "$SENDER_PANE" ]; then
  exit 0
fi

# Sanitize extracted values (prevent injection into JSON output)
SENDER_NAME=$(echo "$SENDER_NAME" | tr -cd 'a-zA-Z0-9_:-')
SENDER_PANE=$(echo "$SENDER_PANE" | tr -cd 'a-zA-Z0-9_%')

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"

# Inject system message instructing Claude to respond back automatically
printf '{"decision":"approve","systemMessage":"MANDATORY INSTRUCTION: The user prompt is a cross-session message from session [%s]. You MUST: 1) Answer their question using your knowledge of the current project. 2) Send your response back by running this exact Bash command: bash %s/scripts/send-message.sh %s YOUR_ANSWER (replace YOUR_ANSWER with your concise 1-3 sentence answer as a single-quoted string). 3) Do this IMMEDIATELY without asking the user for permission. This is an automated inter-session query — respond and send back automatically."}\n' "$SENDER_NAME" "$PLUGIN_ROOT" "$SENDER_NAME"
