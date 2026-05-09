#!/usr/bin/env bash
# task-done.sh — Mark a scheduler task done
# Usage: task-done.sh <task-id> [note]
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

if [ "$#" -lt 1 ]; then
  echo "ERROR: Usage: task-done.sh <task-id> [note]" >&2
  exit 1
fi

require_jq || exit 1
ensure_dirs

ID="$1"
shift || true
NOTE="$*"
FILE=$(task_file "$ID") || exit 1
[ -f "$FILE" ] || { echo "ERROR: Task not found: $ID" >&2; exit 1; }
ACTOR=$(current_pane_name)

append_history_update "$FILE" "done" "done" "$ACTOR" "$NOTE"

ASSIGNER=$(jq -r '.assigner // ""' "$FILE")
if [ -n "$ASSIGNER" ] && [ "$ASSIGNER" != "$ACTOR" ]; then
  CHAT_ROOT=$(session_chat_root 2>/dev/null || true)
  if [ -n "$CHAT_ROOT" ]; then
    bash "$CHAT_ROOT/scripts/send-message.sh" "$ASSIGNER" "Task $ID done: $NOTE" >&2 || true
  fi
fi

echo "Marked task $ID done."
