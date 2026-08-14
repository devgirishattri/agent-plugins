#!/usr/bin/env bash
# task-done.sh — Mark a scheduler task done
# Usage: task-done.sh <task-id> [--force] [note]
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

if [ "$#" -lt 1 ]; then
  echo "ERROR: Usage: task-done.sh <task-id> [--force] [note]" >&2
  exit 1
fi

require_jq || exit 1
ensure_dirs || exit 1

ID="$1"
shift || true
if [ "${1:-}" = "--force" ]; then
  SESSION_SCHEDULER_FORCE=1; export SESSION_SCHEDULER_FORCE
  shift
fi
NOTE="$*"
FILE=$(task_file "$ID") || exit 1
[ -f "$FILE" ] || { echo "ERROR: Task not found: $ID" >&2; exit 1; }
ACTOR=$(current_pane_name)

append_history_update "$FILE" "done" "done" "$ACTOR" "$NOTE" || exit 1

# Record duration_seconds = done time - started_at (when started_at is known).
STARTED_AT=$(jq -r '.started_at // empty' "$FILE")
if [ -n "$STARTED_AT" ]; then
  START_EPOCH=$(iso_to_epoch "$STARTED_AT")
  if [ "$START_EPOCH" -gt 0 ]; then
    DURATION=$((  $(now_epoch) - START_EPOCH ))
    [ "$DURATION" -lt 0 ] && DURATION=0
    jq --argjson d "$DURATION" '.duration_seconds=$d' "$FILE" | write_json_atomic "$FILE" \
      || echo "WARN: Could not record duration_seconds for $ID." >&2
  fi
fi

ASSIGNER=$(jq -r '.assigner // ""' "$FILE")
if [ -n "$ASSIGNER" ] && [ "$ASSIGNER" != "?" ] && [ "$ASSIGNER" != "$ACTOR" ]; then
  TASK_NAME=$(jq -r '.name // ""' "$FILE")
  ACK_FIRST_LINE="task $ID ($TASK_NAME) done by $ACTOR"
  [ -n "$NOTE" ] && ACK_FIRST_LINE="$ACK_FIRST_LINE — $NOTE"
  if ! session_chat_ack "$ASSIGNER" "$ID" "done" "$ACK_FIRST_LINE"; then
    echo "WARN: Durable assigner ack failed after task $ID reached done (partial success)." >&2
    echo "Do NOT rerun task-done or use --force to repair the notification." >&2
    echo "Report the partial success and, only when authorized, send a separate exact session-chat message." >&2
  fi
  record_last_ack "$FILE" "done" "$ASSIGNER" "$SESSION_CHAT_ACK_STATUS" "$SESSION_CHAT_ACK_FILE" || true
fi

echo "Marked task $ID done."
DUR=$(jq -r '.duration_seconds // empty' "$FILE")
[ -n "$DUR" ] && echo "Duration: $(humanize_age "$DUR") (${DUR}s)"
exit 0
