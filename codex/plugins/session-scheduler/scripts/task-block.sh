#!/usr/bin/env bash
# task-block.sh — Mark a scheduler task blocked
# Usage: task-block.sh <task-id> [--force] <reason>
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

if [ "$#" -lt 2 ]; then
  echo "ERROR: Usage: task-block.sh <task-id> [--force] <reason>" >&2
  exit 1
fi

require_jq || exit 1
ensure_dirs || exit 1

ID="$1"
shift
if [ "${1:-}" = "--force" ]; then
  SESSION_SCHEDULER_FORCE=1; export SESSION_SCHEDULER_FORCE
  shift
fi
REASON="$*"
if [ -z "$REASON" ]; then
  echo "ERROR: Usage: task-block.sh <task-id> [--force] <reason>" >&2
  exit 1
fi
FILE=$(task_file "$ID") || exit 1
[ -f "$FILE" ] || { echo "ERROR: Task not found: $ID" >&2; exit 1; }
ACTOR=$(current_pane_name)

append_history_update "$FILE" "blocked" "blocked" "$ACTOR" "$REASON" || exit 1

ASSIGNER=$(jq -r '.assigner // ""' "$FILE")
if [ -n "$ASSIGNER" ] && [ "$ASSIGNER" != "$ACTOR" ]; then
  NOTIFICATION_FAILED=0
  CHAT_ROOT=$(session_chat_root 2>/dev/null || true)
  if [ -n "$CHAT_ROOT" ]; then
    if ! bash "$CHAT_ROOT/scripts/send-message.sh" "$ASSIGNER" "Task $ID blocked: $REASON" >&2; then
      NOTIFICATION_FAILED=1
    fi
  else
    NOTIFICATION_FAILED=1
  fi
  if [ "$NOTIFICATION_FAILED" -eq 1 ]; then
    echo "WARN: Assigner notification failed after task $ID reached blocked (partial success)." >&2
    echo "Do NOT rerun task-block or use --force to repair the notification." >&2
    echo "Report the partial success and, only when authorized, send a separate exact session-chat message." >&2
  fi
fi

echo "Marked task $ID blocked."
