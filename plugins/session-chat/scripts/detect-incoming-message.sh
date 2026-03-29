#!/usr/bin/env bash
# detect-incoming-message.sh — UserPromptSubmit hook: detect cross-session messages
# and inject instructions for Claude to read the full message and auto-respond.
# Supported platforms: macOS, Linux

# Quick exit if not inside tmux
[ -z "${TMUX:-}" ] && exit 0

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Check if the input contains a [from:X pane:Y] pattern anywhere
if ! echo "$HOOK_INPUT" | grep -q '\[from:'; then
  exit 0
fi

# Extract sender name: [from:SENDER_NAME pane:...]
SENDER_NAME=$(echo "$HOOK_INPUT" | grep -oE '\[from:[^ ]+ ' | head -1 | sed 's/\[from://' | sed 's/ $//')

# Extract sender pane: pane:SENDER_PANE
SENDER_PANE=$(echo "$HOOK_INPUT" | grep -oE 'pane:%[0-9]+' | head -1 | sed 's/pane://')

# Extract message file path: msg:/path/to/file.md
MSG_FILE=$(echo "$HOOK_INPUT" | grep -oE 'msg:[^ \]]+' | head -1 | sed 's/msg://')

# Quick exit if extraction failed
if [ -z "$SENDER_NAME" ] || [ -z "$SENDER_PANE" ]; then
  exit 0
fi

# Sanitize extracted values
SENDER_NAME=$(echo "$SENDER_NAME" | tr -cd 'a-zA-Z0-9_:-')
SENDER_PANE=$(echo "$SENDER_PANE" | tr -cd 'a-zA-Z0-9_%')

# Check if this is a reply to a dispatched task (mark it completed)
TASKS_DIR=".claude/dispatch/tasks"
if [ -d "$TASKS_DIR/$SENDER_NAME" ]; then
  TASK_STATUS=$(cat "$TASKS_DIR/$SENDER_NAME/status.txt" 2>/dev/null || echo "")
  if [ "$TASK_STATUS" = "running" ]; then
    # Read full message from file if available
    if [ -n "$MSG_FILE" ] && [ -f "$MSG_FILE" ]; then
      cp "$MSG_FILE" "$TASKS_DIR/$SENDER_NAME/result.md"
    fi
    echo "completed" > "$TASKS_DIR/$SENDER_NAME/status.txt"
    exit 0
  fi
fi

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"

# Build the instruction — include file path if available
READ_INSTRUCTION=""
if [ -n "$MSG_FILE" ]; then
  READ_INSTRUCTION="IMPORTANT: The notification in the prompt is only a preview. Read the FULL message from the file at: ${MSG_FILE} using the Read tool BEFORE responding. "
fi

# Inject system message instructing Claude to read the full message and respond back
printf '{"decision":"approve","systemMessage":"MANDATORY INSTRUCTION: The user prompt is a cross-session message from session [%s]. %sYou MUST: 1) Read the full message file if a msg: path is provided. 2) Answer their question using your knowledge of the current project. 3) Send your response back by running: bash %s/scripts/send-message.sh %s YOUR_ANSWER (replace YOUR_ANSWER with your answer as a single-quoted string). 4) Do this IMMEDIATELY without asking the user for permission."}\n' "$SENDER_NAME" "$READ_INSTRUCTION" "$PLUGIN_ROOT" "$SENDER_NAME"
