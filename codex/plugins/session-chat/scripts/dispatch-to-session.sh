#!/usr/bin/env bash
# dispatch-to-session.sh — Send a task to an existing named session via file-based messaging
# Usage: dispatch-to-session.sh [--priority high|normal] [--ttl MINUTES] [--reply-to ID] <target-name> <prompt-file>
#   --priority high  queued recovery surfaces this before normal messages
#   --ttl MINUTES    if still queued after this window, drop instead of surfacing
# Supported platforms: macOS, Linux

source "$(dirname "$0")/lib.sh"

REPLY_TO=""
REPLY_TO_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --priority)
      shift
      export SESSION_CHAT_PRIORITY="${1:-normal}"
      ;;
    --ttl)
      shift
      _ttl_min=$(normalize_positive_int "${1:-0}" 0)
      export SESSION_CHAT_TTL_MS=$((_ttl_min * 60000))
      ;;
    --reply-to)
      shift
      REPLY_TO="${1:-}"
      REPLY_TO_SET=1
      ;;
    *) break ;;
  esac
  shift
done

TARGET_NAME="${1:-}"
PROMPT_FILE="${2:-}"

if [ -z "$TARGET_NAME" ] || [ -z "$PROMPT_FILE" ]; then
  echo "ERROR: Usage: dispatch-to-session.sh [--reply-to ID] <target-name> <prompt-file>"
  exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: Prompt file not found: $PROMPT_FILE"
  exit 1
fi

# Send the task via file-based dispatch
PROMPT_TEXT=$(cat "$PROMPT_FILE")
if [ "$REPLY_TO_SET" = "1" ]; then
  PROMPT_TEXT=$(correlate_reply "$REPLY_TO" "$PROMPT_TEXT") || exit 1
fi

ensure_tmux
dispatch_message "$TARGET_NAME" "$PROMPT_TEXT"
rc=$?
case "$rc" in
  0) echo "Dispatched task to '$TARGET_NAME'" ;;
  3) echo "Queued dispatch to '$TARGET_NAME' — recipient was busy; it will arrive on their next turn." ;;
  *) exit 1 ;;
esac
