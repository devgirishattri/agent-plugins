#!/usr/bin/env bash
# task-done.sh — mark a task done; ack assigner via session-chat.
# Usage: task-done.sh <id> [note]
set -uo pipefail

source "$(dirname "$0")/lib.sh"

require_jq || exit 1
ensure_dirs

ID="${1:-}"
shift 2>/dev/null || true
NOTE="${*:-}"

validate_task_id "$ID" || exit 1
task_exists "$ID" || { echo "ERROR: task '$ID' not found." >&2; exit 1; }

ACTOR=$(current_pane_name)
ASSIGNER=$(task_get "$ID" '.assigner')
NAME=$(task_get "$ID" '.name')

if ! task_set_status "$ID" "done" "$ACTOR" "$NOTE"; then
  echo "ERROR: ledger write failed for $ID; task NOT marked done." >&2
  exit 1
fi

if [ -n "$ASSIGNER" ] && [ "$ASSIGNER" != "?" ] && [ "$ASSIGNER" != "$ACTOR" ]; then
  msg="task ${ID} (${NAME}) done by ${ACTOR}"
  [ -n "$NOTE" ] && msg="${msg} — ${NOTE}"
  session_chat_send "$ASSIGNER" "$msg"
fi

echo "Task $ID marked done."
[ -n "$NOTE" ] && echo "  note: $NOTE"
