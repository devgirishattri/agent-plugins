#!/usr/bin/env bash
# send-message.sh — Send a message to a named tmux pane
# Usage: send-message.sh <target-name> <message>
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

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
  *) exit 1 ;;
esac
