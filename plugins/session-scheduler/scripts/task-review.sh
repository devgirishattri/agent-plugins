#!/usr/bin/env bash
# task-review.sh — move an assigned task to review; ack assigner via session-chat.
# The executor (or orchestrator) calls this when work is ready for audit, with a
# note such as a commit SHA. The reviewer then runs task-done (approve) or
# task-block (reject).
# Usage: task-review.sh <id> [--force] <note>
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

if [ -z "$ID" ] || [ -z "$NOTE" ]; then
  echo "ERROR: Usage: task-review.sh <id> [--force] <note>   (note required, e.g. a commit SHA)" >&2
  exit 1
fi

validate_task_id "$ID" || exit 1
task_exists "$ID" || { echo "ERROR: task '$ID' not found." >&2; exit 1; }

ACTOR=$(current_pane_name)
ASSIGNER=$(task_get "$ID" '.assigner')
NAME=$(task_get "$ID" '.name')

if ! task_set_status "$ID" "review" "$ACTOR" "$NOTE"; then
  echo "ERROR: task $ID NOT moved to review." >&2
  exit 1
fi

if [ -n "$ASSIGNER" ] && [ "$ASSIGNER" != "?" ] && [ "$ASSIGNER" != "$ACTOR" ]; then
  session_chat_send "$ASSIGNER" "task ${ID} (${NAME}) ready for REVIEW by ${ACTOR}: ${NOTE}"
fi

echo "Task $ID moved to review."
echo "  note: $NOTE"
echo
echo "Reviewer: approve with /task-done $ID [note], or reject with /task-block $ID <reason>."
