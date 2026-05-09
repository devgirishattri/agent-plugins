#!/usr/bin/env bash
# task-assign.sh — Assign a scheduler task to a named pane through session-chat
# Usage: task-assign.sh <pane> <task-id> <prompt>
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

if [ "$#" -lt 3 ]; then
  echo "ERROR: Usage: task-assign.sh <pane> <task-id> <prompt>" >&2
  exit 1
fi

require_jq || exit 1
ensure_dirs

ASSIGNEE="$1"
ID="$2"
shift 2
PROMPT="$*"
FILE=$(task_file "$ID") || exit 1
if [ ! -f "$FILE" ]; then
  echo "ERROR: Task not found: $ID" >&2
  exit 1
fi

CHAT_ROOT=$(session_chat_root) || exit 1
TASK_NAME=$(jq -r '.name' "$FILE")
ASSIGNER=$(current_pane_name)
[ -z "$ASSIGNER" ] && ASSIGNER=$(jq -r '.assigner // ""' "$FILE")
PROMPT_FILE=$(prompt_file "$ID") || exit 1

cat > "$PROMPT_FILE" <<EOF
Task ID: $ID
Task Name: $TASK_NAME
Assigned To: $ASSIGNEE

$PROMPT

When complete, report with:
\$session-scheduler:task-done $ID <summary>

If blocked, report with:
\$session-scheduler:task-block $ID <reason>
EOF

bash "$CHAT_ROOT/scripts/dispatch-to-session.sh" "$ASSIGNEE" "$PROMPT_FILE" || exit 1
bash "$CHAT_ROOT/scripts/send-message.sh" "$ASSIGNEE" "Task $ID assigned: $TASK_NAME" >&2 || true

NOW=$(now_iso)
jq \
  --arg assignee "$ASSIGNEE" \
  --arg assigner "$ASSIGNER" \
  --arg prompt_file "$PROMPT_FILE" \
  --arg now "$NOW" \
  --arg note "$PROMPT" \
  '.status="assigned"
   | .assignee=$assignee
   | .assigner=(if (.assigner // "") == "" then $assigner else .assigner end)
   | .prompt_file=$prompt_file
   | .updated_at=$now
   | .history += [{ts:$now,event:"assigned",actor:$assigner,note:$note}]' \
  "$FILE" | write_json_atomic "$FILE" || exit 1

echo "Assigned task $ID to $ASSIGNEE"
