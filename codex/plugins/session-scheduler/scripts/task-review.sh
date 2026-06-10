#!/usr/bin/env bash
# task-review.sh — Move an assigned scheduler task to review
# The executor (or orchestrator) calls this when work is ready for audit, with
# a note such as a commit SHA. The reviewer then runs task-done (approve) or
# task-block (reject).
# Usage: task-review.sh <task-id> [--force] <note>
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

if [ "$#" -lt 2 ]; then
  echo "ERROR: Usage: task-review.sh <task-id> [--force] <note>   (note required, e.g. a commit SHA)" >&2
  exit 1
fi

require_jq || exit 1
ensure_dirs

ID="$1"
shift
if [ "${1:-}" = "--force" ]; then
  SESSION_SCHEDULER_FORCE=1; export SESSION_SCHEDULER_FORCE
  shift
fi
NOTE="$*"
if [ -z "$NOTE" ]; then
  echo "ERROR: Usage: task-review.sh <task-id> [--force] <note>   (note required, e.g. a commit SHA)" >&2
  exit 1
fi
FILE=$(task_file "$ID") || exit 1
[ -f "$FILE" ] || { echo "ERROR: Task not found: $ID" >&2; exit 1; }
ACTOR=$(current_pane_name)

append_history_update "$FILE" "review" "review" "$ACTOR" "$NOTE" || exit 1

ASSIGNER=$(jq -r '.assigner // ""' "$FILE")
if [ -n "$ASSIGNER" ] && [ "$ASSIGNER" != "$ACTOR" ]; then
  CHAT_ROOT=$(session_chat_root 2>/dev/null || true)
  if [ -n "$CHAT_ROOT" ]; then
    bash "$CHAT_ROOT/scripts/send-message.sh" "$ASSIGNER" "Task $ID ready for REVIEW: $NOTE" >&2 || true
  fi
fi

echo "Marked task $ID review."
echo "Reviewer: approve with \$session-scheduler:task-done $ID <note>, or reject with \$session-scheduler:task-block $ID <reason>."
