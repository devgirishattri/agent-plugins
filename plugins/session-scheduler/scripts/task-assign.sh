#!/usr/bin/env bash
# task-assign.sh — assign a task to a pane and dispatch via session-chat.
# Usage: task-assign.sh <pane> <id> [--eta MINUTES] [--stage NAME] [--context NAME] [--force] <prompt-text>
# Flags must come before the prompt text.
set -uo pipefail

source "$(dirname "$0")/lib.sh"

require_jq || exit 1
ensure_dirs

PANE="${1:-}"
ID="${2:-}"
shift 2 2>/dev/null || true

ETA_MIN=""
STAGE=""
CONTEXT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --eta)     ETA_MIN="${2:-}"; shift 2 ;;
    --stage)   STAGE="${2:-}"; shift 2 ;;
    --context) CONTEXT="${2:-}"; shift 2 ;;
    --force)   SESSION_SCHEDULER_FORCE=1; export SESSION_SCHEDULER_FORCE; shift ;;
    *)         break ;;
  esac
done
PROMPT_TEXT="${*:-}"

if [ -z "$PANE" ] || [ -z "$ID" ] || [ -z "$PROMPT_TEXT" ]; then
  echo "ERROR: Usage: task-assign.sh <pane> <id> [--eta MINUTES] [--stage NAME] [--context NAME] [--force] <prompt-text>" >&2
  exit 1
fi

validate_task_id "$ID" || exit 1

if ! task_exists "$ID"; then
  echo "ERROR: task '$ID' not found. Create it first with /task-new." >&2
  exit 1
fi

if [ -n "$ETA_MIN" ] && ! [[ "$ETA_MIN" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --eta expects a positive integer number of minutes, got '$ETA_MIN'." >&2
  exit 1
fi
if [ -n "$STAGE" ]; then
  validate_stage "$STAGE" || exit 1
fi

# Pre-flight: status transition must be legal (or forced) BEFORE we touch the
# prompt file or dispatch anything.
CURRENT_STATUS=$(task_get "$ID" '.status')
if ! transition_allowed "$CURRENT_STATUS" "assigned" && ! scheduler_force_enabled; then
  echo "ERROR: illegal status transition '$CURRENT_STATUS' -> 'assigned' for task $ID." >&2
  echo "  current status: $CURRENT_STATUS; legal next: $(legal_targets "$CURRENT_STATUS")" >&2
  echo "  Override with --force (or SESSION_SCHEDULER_FORCE=1)." >&2
  exit 1
fi

# Pre-flight: refuse if any dependency is not done (unless --force).
UNMET=$(unmet_deps "$ID")
if [ -n "$UNMET" ] && ! scheduler_force_enabled; then
  echo "ERROR: task $ID has unmet dependencies:" >&2
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
    echo "ERROR: invalid context name '$CONTEXT' (alphanumeric, _, - only)." >&2
    exit 1
  fi
  CONTEXT_FILE="$(resolve_contexts_dir)/$CONTEXT.md"
  if [ ! -f "$CONTEXT_FILE" ]; then
    echo "ERROR: context snapshot '$CONTEXT' not found at $CONTEXT_FILE." >&2
    echo "  Generate it first with /session-context:context-generate $CONTEXT." >&2
    exit 1
  fi
fi

NAME=$(task_get "$ID" '.name')
ASSIGNER=$(current_pane_name)
PROMPT_FILE=$(prompt_path "$ID")

# If the prompt file already exists (reassignment), back it up so we can
# restore it on dispatch failure; if it's new, delete it on dispatch failure.
PROMPT_BACKUP=""
HAD_PROMPT=0
if [ -f "$PROMPT_FILE" ]; then
  HAD_PROMPT=1
  PROMPT_BACKUP="${PROMPT_FILE}.bak.$$"
  if ! cp "$PROMPT_FILE" "$PROMPT_BACKUP"; then
    echo "ERROR: could not back up existing prompt file $PROMPT_FILE; aborting." >&2
    exit 1
  fi
fi

restore_prompt_on_failure() {
  if [ "$HAD_PROMPT" -eq 1 ]; then
    mv "$PROMPT_BACKUP" "$PROMPT_FILE" 2>/dev/null
  else
    rm -f "$PROMPT_FILE"
  fi
}

# Build the executor prompt with task header + reply instructions.
cat > "$PROMPT_FILE" <<EOF
Task ${ID}: ${NAME}

${PROMPT_TEXT}

---
When done, reply via:
  /session-scheduler:task-done ${ID} [note]
To request review (e.g. with a commit SHA), reply via:
  /session-scheduler:task-review ${ID} <note>
If blocked, reply via:
  /session-scheduler:task-block ${ID} <reason>
EOF

if [ -n "$CONTEXT" ]; then
  cat >> "$PROMPT_FILE" <<EOF

## Context
Load the shared context first: /session-context:context-load ${CONTEXT}
EOF
fi

if ! session_chat_dispatch "$PANE" "$PROMPT_FILE"; then
  restore_prompt_on_failure
  echo "ERROR: session-chat dispatch to '$PANE' failed; ledger NOT updated, prompt file rolled back." >&2
  exit 1
fi
[ -n "$PROMPT_BACKUP" ] && rm -f "$PROMPT_BACKUP"

# Compute eta_at (now + N minutes) via epoch math; portable across BSD/GNU date.
ETA_AT=""
if [ -n "$ETA_MIN" ]; then
  ETA_AT=$(epoch_to_iso $(($(epoch_now) + ETA_MIN * 60)))
  if [ -z "$ETA_AT" ]; then
    echo "WARN: could not compute eta_at (date arithmetic failed); proceeding without ETA." >&2
  fi
fi

CURRENT_JSON=$(cat "$(task_path "$ID")")
UPDATED_JSON=$(printf '%s' "$CURRENT_JSON" | jq \
  --arg assignee "$PANE" \
  --arg prompt_file "$PROMPT_FILE" \
  --arg eta "$ETA_AT" \
  --arg stage "$STAGE" \
  --arg ctx "$CONTEXT" \
  '.assignee = $assignee
   | .prompt_file = $prompt_file
   | (if $eta != "" then .eta_at = $eta else . end)
   | (if $stage != "" then .stage = $stage else . end)
   | (if $ctx != "" then .meta.context = $ctx else . end)')
if ! task_write "$ID" "$UPDATED_JSON"; then
  echo "ERROR: dispatch succeeded but ledger update failed for $ID. Inspect $(task_path "$ID")." >&2
  exit 1
fi
if ! task_set_status "$ID" "assigned" "$ASSIGNER" "dispatched to $PANE"; then
  echo "ERROR: dispatch succeeded but status update failed for $ID. Inspect $(task_path "$ID")." >&2
  exit 1
fi

echo "Assigned task $ID ($NAME) to $PANE."
echo "  prompt:  $PROMPT_FILE"
echo "  status:  assigned"
[ -n "$STAGE" ]   && echo "  stage:   $STAGE"
[ -n "$ETA_AT" ]  && echo "  eta:     $ETA_AT (${ETA_MIN}m)"
[ -n "$CONTEXT" ] && echo "  context: $CONTEXT"
echo
echo "Track with: /task-status $ID"
