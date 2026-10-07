#!/usr/bin/env bash
# task-done.sh — mark a task done; ack assigner via session-chat.
# Usage: task-done.sh <id> [--force] [note]
#        task-done.sh <id> --note-file <own-draft> [note]
#        task-done.sh <id> --generation <N> [--note-file <own-draft>] <note>   (contracted task)
# --note-file: the complete verdict is the reviewer's own draft; it is validated
# (own-draft-check.sh, size/UTF-8/NUL) and copied to an exclusive artifact BEFORE
# the transition, recorded as one verdict event in the same atomic ledger write,
# and the assigner gets one notification carrying the full body.
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
task_exists "$ID" || { echo "ERROR: task '$ID' not found." >&2; exit 1; }

# Validate and copy the verdict BEFORE any transition (exits on refusal).
HIST_NOTE="$NOTE"
VERDICT_ARG="null"
if [ "$NOTE_FILE_SET" = 1 ]; then
  verdict_note_prepare "$ID" "$NOTE_FILE" "$NOTE" || exit 1
  HIST_NOTE="$VERDICT_NOTE"
  VERDICT_ARG=$(verdict_event_arg)
fi

ACTOR=$(current_pane_name)
ASSIGNER=$(task_get "$ID" '.assigner')
NAME=$(task_get "$ID" '.name')

if ! task_set_status "$ID" "done" "$ACTOR" "$HIST_NOTE" "$VERDICT_ARG"; then
  [ "$NOTE_FILE_SET" = 1 ] && verdict_discard_unreferenced "$ID" "$VERDICT_EVENT"
  echo "ERROR: task $ID NOT marked done." >&2
  exit 1
fi

# Record duration_seconds = done time - started_at (when started_at is known).
STARTED_AT=$(task_get "$ID" '.started_at // empty')
if [ -n "$STARTED_AT" ]; then
  START_EPOCH=$(iso_to_epoch "$STARTED_AT")
  if [ "$START_EPOCH" -gt 0 ]; then
    DURATION=$(($(epoch_now) - START_EPOCH))
    [ "$DURATION" -lt 0 ] && DURATION=0
    task_update "$ID" '.duration_seconds = $d' --argjson d "$DURATION" \
      || echo "WARN: could not record duration_seconds for $ID." >&2
  fi
fi

if [ "$NOTE_FILE_SET" = 1 ]; then
  # One notification for this event, sent after the lock is released; the
  # outcome is recorded on THAT event only. A crash before the record leaves
  # the event "pending" (unconfirmed). Never replay the transition.
  EVENT_STATE=$(task_get "$ID" '.meta.verdict_events["'"$VERDICT_EVENT"'"].notification.state // empty')
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
  msg="task ${ID} (${NAME}) done by ${ACTOR}"
  [ -n "$NOTE" ] && msg="${msg} — ${NOTE}"
  # Notification is nested session-chat/tmux transport AFTER an irreversible
  # legal transition: durable file-backed dispatch first (queued to the
  # assigner's inbox when busy — the same transport task-assign uses), inline
  # /send as a last-resort fallback. On total failure, report the partial
  # success explicitly — the transition must not be retried and this script
  # never self-escalates.
  session_chat_ack "$ASSIGNER" "$ID" "done" "$msg"
  task_record_last_ack "$ID" "done" "$ASSIGNER" "$SESSION_CHAT_ACK_STATUS" "$SESSION_CHAT_ACK_FILE"
  if [ "$SESSION_CHAT_ACK_STATUS" = "failed" ]; then
    echo "WARN: partial success — the ledger transition to done succeeded, but the durable ack to '$ASSIGNER' failed." >&2
    echo "  Task $ID is already done. Do NOT rerun task-done and do NOT use --force to repair the notification." >&2
    echo "  Report this partial success; only when authorized, send a separate exact session-chat message to '$ASSIGNER'." >&2
  fi
fi

echo "Task $ID marked done."
if [ "$NOTE_FILE_SET" = 1 ]; then
  echo "  note: $HIST_NOTE"
  echo "  verdict event: $VERDICT_EVENT (notification: ${VERDICT_OUTCOME:-$EVENT_STATE})"
else
  [ -n "$NOTE" ] && echo "  note: $NOTE"
fi
DUR=$(task_get "$ID" '.duration_seconds // empty')
[ -n "$DUR" ] && echo "  duration: $(humanize_age "$DUR") (${DUR}s)"
if [ "$NOTE_FILE_SET" = 1 ]; then
  # Cleanup is the last step and never undoes the verdict: the draft is removed
  # only if it is still the same eligible own draft that was checked before
  # it was read.
  verdict_consume_draft "$NOTE_FILE" "$VERDICT_IDENT" "$VERDICT_SHA"
fi
exit 0
