#!/usr/bin/env bash
# task-block.sh — Mark a scheduler task blocked
# Usage: task-block.sh <task-id> [--force] <reason>
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
  task_has_contract "$ID" && verdict_contract_route block "$ID"
  verdict_refuse_generation_without_contract "$ID" || exit 2
  set -- "$ID" ${LEAD_ARGS[@]+"${LEAD_ARGS[@]}"} ${NOTE_WORDS[@]+"${NOTE_WORDS[@]}"}
else
  contract_route_if_needed block "$ID" "$@"
fi
shift 2>/dev/null || true
if [ "${1:-}" = "--force" ]; then
  SESSION_SCHEDULER_FORCE=1; export SESSION_SCHEDULER_FORCE
  shift
fi
REASON="${*:-}"

if [ -z "$ID" ] || { [ -z "$REASON" ] && [ "$NOTE_FILE_SET" != 1 ]; }; then
  echo "ERROR: Usage: task-block.sh <id> [--force] <reason>   (or --note-file <own-draft>)" >&2
  exit 1
fi

validate_task_id "$ID" || exit 1
[ -f "$(task_file "$ID")" ] || { echo "ERROR: task '$ID' not found." >&2; exit 1; }

FILE=$(task_file "$ID") || exit 1
ACTOR=$(current_pane_name)

HIST_NOTE="$REASON"
VERDICT_ARG="null"
if [ "$NOTE_FILE_SET" = 1 ]; then
  # Validate and copy the verdict BEFORE any transition (exits on refusal).
  verdict_note_prepare "$ID" "$NOTE_FILE" "$REASON" || exit 1
  HIST_NOTE="$VERDICT_NOTE"
  VERDICT_ARG=$(verdict_event_arg)
fi

if ! append_history_update "$FILE" "blocked" "blocked" "$ACTOR" "$HIST_NOTE" "$VERDICT_ARG"; then
  [ "$NOTE_FILE_SET" = 1 ] && verdict_discard_unreferenced "$ID" "$VERDICT_EVENT"
  exit 1
fi

ASSIGNER=$(jq -r '.assigner // ""' "$FILE")
if [ "$NOTE_FILE_SET" = 1 ]; then
  # One notification for this event after the transition; outcome recorded on
  # that event only (a crash before the record leaves it "pending").
  EVENT_STATE=$(jq -r '.meta.verdict_events["'"$VERDICT_EVENT"'"].notification.state // empty' "$FILE")
  if [ "$EVENT_STATE" = "pending" ]; then
    VERDICT_OUTCOME=$(verdict_notify "$ID" "$VERDICT_EVENT")
    verdict_record_outcome "$ID" "$VERDICT_EVENT" "$VERDICT_OUTCOME" \
      || echo "WARN: could not record the notification outcome ($VERDICT_OUTCOME) for event $VERDICT_EVENT; it stays 'pending' (unconfirmed)." >&2
    if [ "$VERDICT_OUTCOME" = "failed" ]; then
      echo "WARN: partial success — the ledger transition to blocked succeeded, but the verdict notification to '$ASSIGNER' failed." >&2
      echo "  Task $ID is already blocked and the full verdict is saved: $VERDICT_ARTIFACT. Do NOT rerun task-block and do NOT use --force." >&2
      echo "  Report this partial success; the assigner can read the verdict with task-status $ID." >&2
    fi
  fi
elif [ -n "$ASSIGNER" ] && [ "$ASSIGNER" != "?" ] && [ "$ASSIGNER" != "$ACTOR" ]; then
  TASK_NAME=$(jq -r '.name // ""' "$FILE")
  ACK_FIRST_LINE="task $ID ($TASK_NAME) BLOCKED by $ACTOR: $REASON"
  if ! session_chat_ack "$ASSIGNER" "$ID" "blocked" "$ACK_FIRST_LINE"; then
    echo "WARN: Durable assigner ack failed after task $ID reached blocked (partial success)." >&2
    echo "Do NOT rerun task-block or use --force to repair the notification." >&2
    echo "Report the partial success and, only when authorized, send a separate exact session-chat message." >&2
  fi
  record_last_ack "$FILE" "blocked" "$ASSIGNER" "$SESSION_CHAT_ACK_STATUS" "$SESSION_CHAT_ACK_FILE" || true
fi

echo "Marked task $ID blocked."

if [ "$NOTE_FILE_SET" = 1 ]; then
  echo "Verdict event: $VERDICT_EVENT (notification: ${VERDICT_OUTCOME:-$EVENT_STATE})"
  verdict_consume_draft "$NOTE_FILE" "$VERDICT_IDENT" "$VERDICT_SHA"
fi
exit 0
