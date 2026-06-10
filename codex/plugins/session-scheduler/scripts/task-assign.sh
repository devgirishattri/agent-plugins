#!/usr/bin/env bash
# task-assign.sh — Assign a scheduler task to a named pane through session-chat
# Usage: task-assign.sh <pane> <task-id> [--eta MINUTES] [--stage NAME] [--context NAME] [--force] <prompt>
# Flags must come before the prompt text.
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

if [ "$#" -lt 3 ]; then
  echo "ERROR: Usage: task-assign.sh <pane> <task-id> [--eta MINUTES] [--stage NAME] [--context NAME] [--force] <prompt>" >&2
  exit 1
fi

require_jq || exit 1
ensure_dirs

ASSIGNEE="$1"
ID="$2"
shift 2

ETA_MIN=""
STAGE=""
CONTEXT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --eta)     ETA_MIN="${2:-}"; shift 2 ;;
    --stage)   STAGE="${2:-}"; shift 2 ;;
    --context) CONTEXT="${2:-}"; shift 2 ;;
    --force)   SESSION_SCHEDULER_FORCE=1; export SESSION_SCHEDULER_FORCE; shift ;;
    *)         break ;;
  esac
done
PROMPT="$*"

if [ -z "$PROMPT" ]; then
  echo "ERROR: Prompt text is required (flags must come before the prompt)." >&2
  exit 1
fi

FILE=$(task_file "$ID") || exit 1
if [ ! -f "$FILE" ]; then
  echo "ERROR: Task not found: $ID" >&2
  exit 1
fi

if [ -n "$ETA_MIN" ] && ! [[ "$ETA_MIN" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --eta expects a positive integer number of minutes, got: $ETA_MIN" >&2
  exit 1
fi
if [ -n "$STAGE" ]; then
  validate_stage "$STAGE" || exit 1
fi

# Pre-flight: status transition must be legal (or forced) BEFORE we touch the
# prompt file or dispatch anything.
CURRENT_STATUS=$(jq -r '.status // ""' "$FILE")
if ! transition_allowed "$CURRENT_STATUS" "assigned" && ! scheduler_force_enabled; then
  echo "ERROR: Illegal status transition '$CURRENT_STATUS' -> 'assigned' for task $ID." >&2
  echo "Current status: $CURRENT_STATUS; legal next: $(legal_targets "$CURRENT_STATUS")" >&2
  echo "Override with --force or SESSION_SCHEDULER_FORCE=1." >&2
  exit 1
fi

# Pre-flight: refuse if any dependency is not done (unless --force).
UNMET=$(unmet_deps "$ID")
if [ -n "$UNMET" ] && ! scheduler_force_enabled; then
  echo "ERROR: Task $ID has unmet dependencies:" >&2
  while IFS= read -r dep_line; do
    printf '  %s\n' "$dep_line" >&2
  done <<< "$UNMET"
  echo "Complete them first, or re-run with --force to assign anyway." >&2
  exit 1
fi

# Pre-flight: resolve the session-context snapshot before any side effects.
CONTEXT_FILE=""
if [ -n "$CONTEXT" ]; then
  if ! [[ "$CONTEXT" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: Invalid context name: $CONTEXT (alphanumeric, _, - only)." >&2
    exit 1
  fi
  CONTEXT_FILE="$(resolve_contexts_dir)/$CONTEXT.md"
  if [ ! -f "$CONTEXT_FILE" ]; then
    echo "ERROR: Context snapshot '$CONTEXT' not found at $CONTEXT_FILE." >&2
    echo "Generate it first with \$session-context:context-generate $CONTEXT." >&2
    exit 1
  fi
fi

CHAT_ROOT=$(session_chat_root) || exit 1
TASK_NAME=$(jq -r '.name' "$FILE")
ASSIGNER=$(current_pane_name)
[ -z "$ASSIGNER" ] && ASSIGNER=$(jq -r '.assigner // ""' "$FILE")
PROMPT_FILE=$(prompt_file "$ID") || exit 1

# If the prompt file already exists (reassignment), back it up so we can
# restore it on dispatch failure; if it is new, delete it on dispatch failure.
PROMPT_BACKUP=""
HAD_PROMPT=0
if [ -f "$PROMPT_FILE" ]; then
  HAD_PROMPT=1
  PROMPT_BACKUP="${PROMPT_FILE}.bak.$$"
  cp "$PROMPT_FILE" "$PROMPT_BACKUP" || {
    echo "ERROR: Could not back up existing prompt file $PROMPT_FILE; aborting." >&2
    exit 1
  }
fi

restore_prompt_on_failure() {
  if [ "$HAD_PROMPT" -eq 1 ]; then
    mv "$PROMPT_BACKUP" "$PROMPT_FILE" 2>/dev/null
  else
    rm -f "$PROMPT_FILE"
  fi
}

cat > "$PROMPT_FILE" <<EOF
Task ID: $ID
Task Name: $TASK_NAME
Assigned To: $ASSIGNEE

$PROMPT

When complete, report with:
\$session-scheduler:task-done $ID <summary>

To request review (e.g. with a commit SHA), report with:
\$session-scheduler:task-review $ID <note>

If blocked, report with:
\$session-scheduler:task-block $ID <reason>
EOF

if [ -n "$CONTEXT" ]; then
  cat >> "$PROMPT_FILE" <<EOF

## Context
Load the shared context first: \$session-context:context-load $CONTEXT
EOF
fi

if ! bash "$CHAT_ROOT/scripts/dispatch-to-session.sh" "$ASSIGNEE" "$PROMPT_FILE"; then
  restore_prompt_on_failure
  echo "ERROR: session-chat dispatch to '$ASSIGNEE' failed; ledger NOT updated, prompt file rolled back." >&2
  exit 1
fi
[ -n "$PROMPT_BACKUP" ] && rm -f "$PROMPT_BACKUP"
bash "$CHAT_ROOT/scripts/send-message.sh" "$ASSIGNEE" "Task $ID assigned: $TASK_NAME" >&2 || true

# Compute eta_at (now + N minutes) via epoch math; portable across BSD/GNU date.
ETA_AT=""
if [ -n "$ETA_MIN" ]; then
  ETA_AT=$(epoch_to_iso $(($(now_epoch) + ETA_MIN * 60)))
  [ -z "$ETA_AT" ] && echo "WARN: Could not compute eta_at (date arithmetic failed); proceeding without ETA." >&2
fi

jq \
  --arg assignee "$ASSIGNEE" \
  --arg assigner "$ASSIGNER" \
  --arg prompt_file "$PROMPT_FILE" \
  --arg eta "$ETA_AT" \
  --arg stage "$STAGE" \
  --arg ctx "$CONTEXT" \
  '.assignee=$assignee
   | .assigner=(if (.assigner // "") == "" then $assigner else .assigner end)
   | .prompt_file=$prompt_file
   | (if $eta != "" then .eta_at=$eta else . end)
   | (if $stage != "" then .stage=$stage else . end)
   | (if $ctx != "" then .meta.context=$ctx else . end)' \
  "$FILE" | write_json_atomic "$FILE" || exit 1

append_history_update "$FILE" "assigned" "assigned" "$ASSIGNER" "$PROMPT" || exit 1

echo "Assigned task $ID to $ASSIGNEE"
[ -n "$STAGE" ]   && echo "Stage: $STAGE"
[ -n "$ETA_AT" ]  && echo "ETA: $ETA_AT (${ETA_MIN}m)"
[ -n "$CONTEXT" ] && echo "Context: $CONTEXT"
exit 0
