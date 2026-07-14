#!/usr/bin/env bash
# task-block.sh — mark a task blocked; ack assigner via session-chat.
# Usage: task-block.sh <id> [--force] <reason>
set -uo pipefail

source "$(dirname "$0")/lib.sh"

require_jq || exit 1
ensure_dirs || exit 1

ID="${1:-}"
shift 2>/dev/null || true
if [ "${1:-}" = "--force" ]; then
  SESSION_SCHEDULER_FORCE=1; export SESSION_SCHEDULER_FORCE
  shift
fi
REASON="${*:-}"

if [ -z "$ID" ] || [ -z "$REASON" ]; then
  echo "ERROR: Usage: task-block.sh <id> [--force] <reason>" >&2
  exit 1
fi

validate_task_id "$ID" || exit 1
task_exists "$ID" || { echo "ERROR: task '$ID' not found." >&2; exit 1; }

ACTOR=$(current_pane_name)
ASSIGNER=$(task_get "$ID" '.assigner')
NAME=$(task_get "$ID" '.name')

if ! task_set_status "$ID" "blocked" "$ACTOR" "$REASON"; then
  echo "ERROR: task $ID NOT marked blocked." >&2
  exit 1
fi

if [ -n "$ASSIGNER" ] && [ "$ASSIGNER" != "?" ] && [ "$ASSIGNER" != "$ACTOR" ]; then
  # Notification is nested session-chat/tmux transport AFTER an irreversible
  # legal transition. On failure, report the partial success explicitly — the
  # transition must not be retried and this script never self-escalates.
  if ! session_chat_send "$ASSIGNER" "task ${ID} (${NAME}) BLOCKED by ${ACTOR}: ${REASON}"; then
    echo "WARN: partial success — the ledger transition to blocked succeeded, but the session-chat notification to '$ASSIGNER' failed." >&2
    echo "  Task $ID is already blocked. Do NOT rerun task-block and do NOT use --force to repair the notification." >&2
    echo "  Report this partial success; only when authorized, send a separate exact session-chat message to '$ASSIGNER'." >&2
  fi
fi

echo "Task $ID marked blocked."
echo "  reason: $REASON"
