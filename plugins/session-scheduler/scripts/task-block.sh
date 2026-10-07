#!/usr/bin/env bash
# task-block.sh — mark a task blocked; ack assigner via session-chat.
# Usage: task-block.sh <id> [--force] <reason>
#        task-block.sh <id> --note-file <own-draft> [summary]
#        task-block.sh <id> --generation <N> [--note-file <own-draft>] <reason>   (contracted task)
# --note-file: see task-done.sh (one verdict event, full body in an artifact).
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
  task_exists "$ID" || { echo "ERROR: task '$ID' not found." >&2; exit 1; }
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
task_exists "$ID" || { echo "ERROR: task '$ID' not found." >&2; exit 1; }

ACTOR=$(current_pane_name)
ASSIGNER=$(task_get "$ID" '.assigner')
NAME=$(task_get "$ID" '.name')

HIST_NOTE="$REASON"
VERDICT_ARG="null"
if [ "$NOTE_FILE_SET" = 1 ]; then
  # Validate and copy the verdict BEFORE any transition (exits on refusal).
  verdict_note_prepare "$ID" "$NOTE_FILE" "$REASON" || exit 1
  HIST_NOTE="$VERDICT_NOTE"
  VERDICT_ARG=$(verdict_event_arg)
fi

if ! task_set_status "$ID" "blocked" "$ACTOR" "$HIST_NOTE" "$VERDICT_ARG"; then
  [ "$NOTE_FILE_SET" = 1 ] && verdict_discard_unreferenced "$ID" "$VERDICT_EVENT"
  echo "ERROR: task $ID NOT marked blocked." >&2
  exit 1
fi

if [ "$NOTE_FILE_SET" = 1 ]; then
  # One notification for this event after the transition; outcome recorded on
  # that event only (a crash before the record leaves it "pending").
  EVENT_STATE=$(task_get "$ID" '.meta.verdict_events["'"$VERDICT_EVENT"'"].notification.state // empty')
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
  # Notification is nested session-chat/tmux transport AFTER an irreversible
  # legal transition: durable file-backed dispatch first (queued to the
  # assigner's inbox when busy — the same transport task-assign uses), inline
  # /send as a last-resort fallback. On total failure, report the partial
  # success explicitly — the transition must not be retried and this script
  # never self-escalates.
  session_chat_ack "$ASSIGNER" "$ID" "blocked" "task ${ID} (${NAME}) BLOCKED by ${ACTOR}: ${REASON}"
  task_record_last_ack "$ID" "blocked" "$ASSIGNER" "$SESSION_CHAT_ACK_STATUS" "$SESSION_CHAT_ACK_FILE"
  if [ "$SESSION_CHAT_ACK_STATUS" = "failed" ]; then
    echo "WARN: partial success — the ledger transition to blocked succeeded, but the durable ack to '$ASSIGNER' failed." >&2
    echo "  Task $ID is already blocked. Do NOT rerun task-block and do NOT use --force to repair the notification." >&2
    echo "  Report this partial success; only when authorized, send a separate exact session-chat message to '$ASSIGNER'." >&2
  fi
fi

echo "Task $ID marked blocked."
if [ "$NOTE_FILE_SET" = 1 ]; then
  echo "  reason: $HIST_NOTE"
  echo "  verdict event: $VERDICT_EVENT (notification: ${VERDICT_OUTCOME:-$EVENT_STATE})"
  # Cleanup is the last step and never undoes the verdict.
  verdict_consume_draft "$NOTE_FILE" "$VERDICT_IDENT" "$VERDICT_SHA"
else
  echo "  reason: $REASON"
fi
