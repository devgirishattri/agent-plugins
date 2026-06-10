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
ensure_dirs

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
if [ -n "$ASSIGNER" ] && [ "$ASSIGNER" != "$ACTOR" ]; then
  CHAT_ROOT=$(session_chat_root 2>/dev/null || true)
  if [ -n "$CHAT_ROOT" ]; then
    bash "$CHAT_ROOT/scripts/send-message.sh" "$ASSIGNER" "Task $ID done: $NOTE" >&2 || true
  fi
fi

echo "Marked task $ID done."
DUR=$(jq -r '.duration_seconds // empty' "$FILE")
[ -n "$DUR" ] && echo "Duration: $(humanize_age "$DUR") (${DUR}s)"
exit 0
