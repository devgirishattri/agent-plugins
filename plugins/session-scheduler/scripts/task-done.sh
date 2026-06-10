#!/usr/bin/env bash
# task-done.sh — mark a task done; ack assigner via session-chat.
# Usage: task-done.sh <id> [--force] [note]
set -uo pipefail

source "$(dirname "$0")/lib.sh"

require_jq || exit 1
ensure_dirs

ID="${1:-}"
shift 2>/dev/null || true
if [ "${1:-}" = "--force" ]; then
  SESSION_SCHEDULER_FORCE=1; export SESSION_SCHEDULER_FORCE
  shift
fi
NOTE="${*:-}"

validate_task_id "$ID" || exit 1
task_exists "$ID" || { echo "ERROR: task '$ID' not found." >&2; exit 1; }

ACTOR=$(current_pane_name)
ASSIGNER=$(task_get "$ID" '.assigner')
NAME=$(task_get "$ID" '.name')

if ! task_set_status "$ID" "done" "$ACTOR" "$NOTE"; then
  echo "ERROR: task $ID NOT marked done." >&2
  exit 1
fi

# Record duration_seconds = done time - started_at (when started_at is known).
STARTED_AT=$(task_get "$ID" '.started_at // empty')
if [ -n "$STARTED_AT" ]; then
  START_EPOCH=$(iso_to_epoch "$STARTED_AT")
  if [ "$START_EPOCH" -gt 0 ]; then
    DURATION=$(($(epoch_now) - START_EPOCH))
    [ "$DURATION" -lt 0 ] && DURATION=0
    UPDATED_JSON=$(jq --argjson d "$DURATION" '.duration_seconds = $d' "$(task_path "$ID")")
    task_write "$ID" "$UPDATED_JSON" || echo "WARN: could not record duration_seconds for $ID." >&2
  fi
fi

if [ -n "$ASSIGNER" ] && [ "$ASSIGNER" != "?" ] && [ "$ASSIGNER" != "$ACTOR" ]; then
  msg="task ${ID} (${NAME}) done by ${ACTOR}"
  [ -n "$NOTE" ] && msg="${msg} — ${NOTE}"
  session_chat_send "$ASSIGNER" "$msg"
fi

echo "Task $ID marked done."
[ -n "$NOTE" ] && echo "  note: $NOTE"
DUR=$(task_get "$ID" '.duration_seconds // empty')
[ -n "$DUR" ] && echo "  duration: $(humanize_age "$DUR") (${DUR}s)"
exit 0
