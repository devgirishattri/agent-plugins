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
if [ -n "$ASSIGNER" ] && [ "$ASSIGNER" != "?" ] && [ "$ASSIGNER" != "$ACTOR" ]; then
  TASK_NAME=$(jq -r '.name // ""' "$FILE")
  ACK_FIRST_LINE="task $ID ($TASK_NAME) BLOCKED by $ACTOR: $REASON"
  if ! session_chat_ack "$ASSIGNER" "$ID" "blocked" "$ACK_FIRST_LINE"; then
    echo "WARN: Durable assigner ack failed after task $ID reached blocked (partial success)." >&2
    echo "Do NOT rerun task-block or use --force to repair the notification." >&2
    echo "Report the partial success and, only when authorized, send a separate exact session-chat message." >&2
  fi
  record_last_ack "$FILE" "blocked" "$ASSIGNER" "$SESSION_CHAT_ACK_STATUS" "$SESSION_CHAT_ACK_FILE" || true
fi

echo "Marked task $ID blocked."
