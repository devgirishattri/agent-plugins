#!/usr/bin/env bash
# task-block.sh — Mark a scheduler task blocked
# Usage: task-block.sh <task-id> <reason>
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

if [ "$#" -lt 2 ]; then
  echo "ERROR: Usage: task-block.sh <task-id> <reason>" >&2
  exit 1
fi

require_jq || exit 1
ensure_dirs

ID="$1"
shift
REASON="$*"
FILE=$(task_file "$ID") || exit 1
[ -f "$FILE" ] || { echo "ERROR: Task not found: $ID" >&2; exit 1; }
ACTOR=$(current_pane_name)

append_history_update "$FILE" "blocked" "blocked" "$ACTOR" "$REASON"

ASSIGNER=$(jq -r '.assigner // ""' "$FILE")
if [ -n "$ASSIGNER" ] && [ "$ASSIGNER" != "$ACTOR" ]; then
  CHAT_ROOT=$(session_chat_root 2>/dev/null || true)
  if [ -n "$CHAT_ROOT" ]; then
    bash "$CHAT_ROOT/scripts/send-message.sh" "$ASSIGNER" "Task $ID blocked: $REASON" >&2 || true
  fi
fi

echo "Marked task $ID blocked."
