#!/usr/bin/env bash
# task-assign.sh — assign a task to a pane and dispatch via session-chat.
# Usage: task-assign.sh <pane> <id> <prompt-text>
set -uo pipefail

source "$(dirname "$0")/lib.sh"

require_jq || exit 1
ensure_dirs

PANE="${1:-}"
ID="${2:-}"
shift 2 2>/dev/null || true
PROMPT_TEXT="${*:-}"

if [ -z "$PANE" ] || [ -z "$ID" ] || [ -z "$PROMPT_TEXT" ]; then
  echo "ERROR: Usage: task-assign.sh <pane> <id> <prompt-text>" >&2
  exit 1
fi

validate_task_id "$ID" || exit 1

if ! task_exists "$ID"; then
  echo "ERROR: task '$ID' not found. Create it first with /task-new." >&2
  exit 1
fi

NAME=$(task_get "$ID" '.name')
ASSIGNER=$(current_pane_name)
PROMPT_FILE=$(prompt_path "$ID")

# Build the executor prompt with task header + reply instructions.
cat > "$PROMPT_FILE" <<EOF
Task ${ID}: ${NAME}

${PROMPT_TEXT}

---
When done, reply via:
  /session-scheduler:task-done ${ID} [note]
If blocked, reply via:
  /session-scheduler:task-block ${ID} <reason>
EOF

if ! session_chat_dispatch "$PANE" "$PROMPT_FILE"; then
  echo "ERROR: session-chat dispatch to '$PANE' failed; ledger NOT updated." >&2
  exit 1
fi

task_set_assignee "$ID" "$PANE" "$PROMPT_FILE"
task_set_status "$ID" "assigned" "$ASSIGNER" "dispatched to $PANE"

echo "Assigned task $ID ($NAME) to $PANE."
echo "  prompt:  $PROMPT_FILE"
echo "  status:  assigned"
echo
echo "Track with: /task-status $ID"
