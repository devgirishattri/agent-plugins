#!/usr/bin/env bash
# task-done.sh — Mark a scheduler task done
# Usage: task-done.sh <task-id> [--force] [note]
# Also accepts <task-id> [--generation N] --note-file <own draft>.
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

require_jq || exit 1
ensure_dirs || exit 1

ID="${1:-}"
# --note-file is parsed first (leading option only). Without it, a contracted
# task is handed to task-contract.sh with the original arguments before any
# write; it never returns in that case.
NOTE_FILE_SET=0
if [ "$#" -ge 1 ]; then
  verdict_split_args "${@:2}" || exit 1
fi
if [ "$NOTE_FILE_SET" = 1 ]; then
  validate_task_id "$ID" || exit 1
  [ -f "$(task_file "$ID")" ] || { echo "ERROR: task '$ID' not found." >&2; exit 1; }
  task_has_contract "$ID" && verdict_contract_route "done" "$ID"
  verdict_refuse_generation_without_contract "$ID" || exit 2
  set -- "$ID" ${LEAD_ARGS[@]+"${LEAD_ARGS[@]}"} ${NOTE_WORDS[@]+"${NOTE_WORDS[@]}"}
else
  contract_route_if_needed "done" "$ID" "$@"
fi
shift 2>/dev/null || true
if [ "${1:-}" = "--force" ]; then
  SESSION_SCHEDULER_FORCE=1; export SESSION_SCHEDULER_FORCE
  shift
fi
NOTE="${*:-}"

validate_task_id "$ID" || exit 1
[ -f "$(task_file "$ID")" ] || { echo "ERROR: task '$ID' not found." >&2; exit 1; }

# Validate and copy the verdict BEFORE any transition (exits on refusal).
HIST_NOTE="$NOTE"
VERDICT_ARG="null"
if [ "$NOTE_FILE_SET" = 1 ]; then
  verdict_note_prepare "$ID" "$NOTE_FILE" "$NOTE" || exit 1
  HIST_NOTE="$VERDICT_NOTE"
  VERDICT_ARG=$(verdict_event_arg)
fi

FILE=$(task_file "$ID") || exit 1
ACTOR=$(current_pane_name)

if ! append_history_update "$FILE" "done" "done" "$ACTOR" "$HIST_NOTE" "$VERDICT_ARG"; then
  [ "$NOTE_FILE_SET" = 1 ] && verdict_discard_unreferenced "$ID" "$VERDICT_EVENT"
  exit 1
fi

# Record duration_seconds = done time - started_at (when started_at is known).
STARTED_AT=$(jq -r '.started_at // empty' "$FILE")
if [ -n "$STARTED_AT" ]; then
  START_EPOCH=$(iso_to_epoch "$STARTED_AT")
  if [ "$START_EPOCH" -gt 0 ]; then
    DURATION=$((  $(now_epoch) - START_EPOCH ))
    [ "$DURATION" -lt 0 ] && DURATION=0
    task_jq_update "$FILE" --argjson d "$DURATION" '.duration_seconds=$d' \
      || echo "WARN: Could not record duration_seconds for $ID." >&2
  fi
fi

ASSIGNER=$(jq -r '.assigner // ""' "$FILE")
if [ "$NOTE_FILE_SET" = 1 ]; then
  # One notification for this event, sent after the lock is released; the
  # outcome is recorded on THAT event only. A crash before the record leaves
  # the event "pending" (unconfirmed). Never replay the transition.
  EVENT_STATE=$(jq -r '.meta.verdict_events["'"$VERDICT_EVENT"'"].notification.state // empty' "$FILE")
  if [ "$EVENT_STATE" = "pending" ]; then
    VERDICT_OUTCOME=$(verdict_notify "$ID" "$VERDICT_EVENT")
    verdict_record_outcome "$ID" "$VERDICT_EVENT" "$VERDICT_OUTCOME" \
      || echo "WARN: could not record the notification outcome ($VERDICT_OUTCOME) for event $VERDICT_EVENT; it stays 'pending' (unconfirmed)." >&2
    if [ "$VERDICT_OUTCOME" = "failed" ]; then
      echo "WARN: partial success — the ledger transition to done succeeded, but the verdict notification to '$ASSIGNER' failed." >&2
      echo "  Task $ID is already done and the full verdict is saved: $VERDICT_ARTIFACT. Do NOT rerun task-done and do NOT use --force." >&2
      echo "  Report this partial success; the assigner can read the verdict with task-status $ID." >&2
    fi
  fi
elif [ -n "$ASSIGNER" ] && [ "$ASSIGNER" != "?" ] && [ "$ASSIGNER" != "$ACTOR" ]; then
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

if [ "$NOTE_FILE_SET" = 1 ]; then
  echo "Verdict event: $VERDICT_EVENT (notification: ${VERDICT_OUTCOME:-$EVENT_STATE})"
  verdict_consume_draft "$NOTE_FILE" "$VERDICT_IDENT" "$VERDICT_SHA"
fi
exit 0
