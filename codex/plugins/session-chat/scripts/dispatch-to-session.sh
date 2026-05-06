#!/usr/bin/env bash
# dispatch-to-session.sh — Send a task to an existing named session via file-based messaging
# Usage: dispatch-to-session.sh <target-name> <prompt-file>
# Supported platforms: macOS, Linux

source "$(dirname "$0")/lib.sh"

TARGET_NAME="${1:-}"
PROMPT_FILE="${2:-}"

if [ -z "$TARGET_NAME" ] || [ -z "$PROMPT_FILE" ]; then
  echo "ERROR: Usage: dispatch-to-session.sh <target-name> <prompt-file>"
  exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: Prompt file not found: $PROMPT_FILE"
  exit 1
fi

ensure_tmux

# Send the task via file-based dispatch
PROMPT_TEXT=$(cat "$PROMPT_FILE")
if ! dispatch_message "$TARGET_NAME" "$PROMPT_TEXT"; then
  echo "ERROR: Failed to dispatch task to '$TARGET_NAME'." >&2
  exit 1
fi

echo "Dispatched task to '$TARGET_NAME'"
