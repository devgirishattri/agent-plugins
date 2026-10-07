#!/usr/bin/env bash
# send-message.sh — Send a message to a named tmux pane
# Usage: send-message.sh [--priority high|normal] [--ttl MINUTES] [--reply-to ID] [--task TASK_ID] <target-name> <message>
#   --priority high  queued recovery surfaces this before normal messages
#   --ttl MINUTES    if still queued after this window, drop instead of surfacing
#   --reply-to ID    prepend a single [re:ID] correlation token (8-16 hex) so the
#                    original sender's /check-replies matches this as a reply
#   --task TASK_ID   put a [task:TASK_ID] token after it (letters, digits, _ and -);
#                    /check-replies --task TASK_ID lists everything tagged with it.
#                    Both tokens form a LEADING envelope: only the very start of
#                    the message body is ever read as one.
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

REPLY_TO=""
TASK_ID=""
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
      ;;
    --task)
      shift
      TASK_ID="${1:-}"
      if [ -z "$TASK_ID" ]; then
        echo "ERROR: --task requires a task id." >&2
        exit 1
      fi
      ;;
    *) break ;;
  esac
  shift
done

TARGET_NAME="${1:-}"
shift 2>/dev/null || true
MESSAGE="$*"

if [ -z "$TARGET_NAME" ]; then
  echo "ERROR: No target specified."
  echo "Usage: send-message.sh <pane-name> <message>"
  exit 1
fi

if [ -z "$MESSAGE" ]; then
  echo "ERROR: No message specified."
  exit 1
fi

# Compose the leading envelope ([re:ID] then [task:ID]) BEFORE the length/newline
# guards in send_message run, so an over-length reply fails loudly rather than
# dropping a token. apply_envelope fails closed on a malformed id or a
# conflicting leading token.
if [ -n "$REPLY_TO" ] || [ -n "$TASK_ID" ]; then
  MESSAGE=$(apply_envelope "$REPLY_TO" "$TASK_ID" "$MESSAGE") || exit 1
fi

ensure_tmux
send_message "$TARGET_NAME" "$MESSAGE"
rc=$?
case "$rc" in
  0) echo "Sent to $TARGET_NAME." ;;
  3) echo "Queued to $TARGET_NAME — recipient was busy; it will arrive on their next turn." ;;
  *) exit 1 ;;  # send_message already emitted a specific error.
esac
