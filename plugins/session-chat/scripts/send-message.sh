#!/usr/bin/env bash
# send-message.sh — Send a message to a named tmux pane
# Usage: send-message.sh [--priority high|normal] [--ttl MINUTES] <target-name> <message>
#   --priority high  queued recovery surfaces this before normal messages
#   --ttl MINUTES    if still queued after this window, drop instead of surfacing
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

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

ensure_tmux
send_message "$TARGET_NAME" "$MESSAGE"
rc=$?
case "$rc" in
  0) echo "Sent to $TARGET_NAME." ;;
  3) echo "Queued to $TARGET_NAME — recipient was busy; it will arrive on their next turn." ;;
  *) exit 1 ;;  # send_message already emitted a specific error.
esac
