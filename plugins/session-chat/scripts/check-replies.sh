#!/usr/bin/env bash
# check-replies.sh — Correlate messages this pane sent with replies that came
# back. A reply is any incoming message whose LEADING envelope starts with a
# [re:<id>] token where <id> is a message id this pane previously sent (/send and
# /dispatch print the id; recipients are asked to put [re:<id>] first in their
# acks; a [re:<id>] quoted later in a body never counts).
# Usage: check-replies.sh [--pending] [--since MINUTES] [--task TASK_ID]
#   --pending        only show sent messages still unanswered (no acceptable reply correlated)
#   --since MINUTES  look-back window for sent messages (default 1440 = 24h)
#   --task TASK_ID   only replies tagged [task:TASK_ID] (and requests sent with that task)
# Output: TSV rows  <id> <to> <type> <delivery> <age> <reply> <excerpt> <task>
#   A request with several replies prints one row per reply association (each
#   with its own task). REPLY is one of:
#     unconfirmed                          no acceptable reply yet
#     verified:<from>                      <from> is the request's recipient AND the
#                                          reply was recorded as received by the
#                                          request's sender (this pane)
#     replied (recipient-unknown):<from>   an older reply row with no recorded
#                                          recipient; <from> matches, but receipt by
#                                          this pane is NOT evidenced
#     unexpected:<from> (...)              a reply from someone other than the
#                                          request's recipient, or recorded as
#                                          received by another pane / without
#                                          recipient context — never counted as an answer
set -uo pipefail

source "$(dirname "$0")/lib.sh"

PENDING_ONLY=0
SINCE_MIN=1440
TASK_FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pending) PENDING_ONLY=1 ;;
    --since)
      shift
      SINCE_MIN=$(normalize_positive_int "${1:-1440}" 1440)
      ;;
    --task)
      shift
      TASK_FILTER="${1:-}"
      if ! [[ "$TASK_FILTER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "ERROR: --task expects a task id of letters, digits, _ and - (got '$TASK_FILTER')." >&2
        exit 1
      fi
      ;;
    -h|--help)
      echo "Usage: check-replies.sh [--pending] [--since MINUTES] [--task TASK_ID]"
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

SENT_LOG=$(sent_log_file)
if [ ! -f "$SENT_LOG" ]; then
  echo "No sent messages recorded yet (the ledger starts with your next /send or /dispatch)."
  exit 0
fi
REPLIES_LOG=$(replies_log_file)

NOW=$(now_ms)
CUTOFF=$((NOW - SINCE_MIN * 60000))

age_human() {
  local then_ms="$1"
  local s=$(( (NOW - then_ms) / 1000 ))
  [ "$s" -lt 0 ] && s=0
  if [ "$s" -lt 60 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%sm' $((s / 60))
  elif [ "$s" -lt 86400 ]; then printf '%sh' $((s / 3600))
  else printf '%sd' $((s / 86400)); fi
}

# classify_replies <id> <request_from> <request_to> — one line per DISTINCT reply
# association, ALL rows for the id scanned (an unexpected row never hides a later
# valid one). Fields are \037-separated so an empty task survives:
#   <kind>\037<from>\037<task>\037<recorded recipient>
# kind: verified | recipient-unknown | unexpected-sender | unexpected-recipient |
# unexpected-nocontext. Rows with 3 fields are the older format (no recipient);
# a row with more fields but an empty recipient is missing its context.
classify_replies() {
  [ -f "$REPLIES_LOG" ] || return 0
  awk -F'\t' -v id="$1" -v rf="$2" -v rt="$3" -v tf="$TASK_FILTER" '
    $2 == id {
      from = $3; task = (NF >= 4 ? $4 : ""); recip = (NF >= 5 ? $5 : "")
      if (tf != "" && task != tf) next
      if (from != rt || rt == "") kind = "unexpected-sender"
      else if (NF <= 3) kind = "recipient-unknown"
      else if (recip == "") kind = "unexpected-nocontext"
      else if (rf == "" || recip != rf) kind = "unexpected-recipient"
      else kind = "verified"
      key = kind SUBSEP from SUBSEP task SUBSEP recip
      if (seen[key]++) next
      printf "%s\037%s\037%s\037%s\n", kind, from, task, recip
    }' "$REPLIES_LOG" 2>/dev/null
}

print_row() {
  # print_row <id> <to> <type> <delivery> <age> <reply> <excerpt> <task>
  if [ "$HEADER_PRINTED" = "0" ]; then
    printf 'ID\tTO\tTYPE\tDELIVERY\tAGE\tREPLY\tEXCERPT\tTASK\n'
    HEADER_PRINTED=1
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"
}

ROWS=0
PENDING=0
HEADER_PRINTED=0
# The sent log is read through awk with a non-whitespace delimiter so an empty
# column (the task id of an untagged send) survives `read`, and a 7-column row
# from before task ids existed simply yields an empty task.
while IFS=$'\037' read -r ts id req_from to type delivery excerpt req_task; do
  [ -n "$id" ] || continue
  is_nonnegative_int "$ts" || continue
  [ "$ts" -ge "$CUTOFF" ] || continue
  age=$(age_human "$ts")
  answered=()      # REPLY column text + task for each acceptable reply
  answered_tasks=()
  unexpected=()
  unexpected_tasks=()
  while IFS=$'\037' read -r kind rfrom rtask rrecip; do
    [ -n "$kind" ] || continue
    case "$kind" in
      verified)
        answered+=("verified:${rfrom}"); answered_tasks+=("$rtask") ;;
      recipient-unknown)
        answered+=("replied (recipient-unknown):${rfrom}"); answered_tasks+=("$rtask") ;;
      unexpected-sender)
        unexpected+=("unexpected:${rfrom} (not the recipient '${to}')"); unexpected_tasks+=("$rtask") ;;
      unexpected-recipient)
        unexpected+=("unexpected:${rfrom} (received by '${rrecip}', not by this request's sender)"); unexpected_tasks+=("$rtask") ;;
      unexpected-nocontext)
        unexpected+=("unexpected:${rfrom} (no recipient context recorded)"); unexpected_tasks+=("$rtask") ;;
    esac
  done < <(classify_replies "$id" "$req_from" "$to")
  # --task: keep a request when it was sent with that task OR a reply carries it.
  if [ -n "$TASK_FILTER" ] && [ "$req_task" != "$TASK_FILTER" ] \
     && [ "${#answered[@]}" -eq 0 ] && [ "${#unexpected[@]}" -eq 0 ]; then
    continue
  fi
  if [ "${#answered[@]}" -gt 0 ]; then
    [ "$PENDING_ONLY" = "1" ] && continue
  else
    PENDING=$((PENDING + 1))
  fi
  if [ "${#answered[@]}" -eq 0 ]; then
    print_row "$id" "$to" "$type" "$delivery" "$age" "unconfirmed" "$excerpt" "$req_task"
  fi
  i=0
  while [ "$i" -lt "${#answered[@]}" ]; do
    print_row "$id" "$to" "$type" "$delivery" "$age" "${answered[$i]}" "$excerpt" "${answered_tasks[$i]}"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#unexpected[@]}" ]; do
    print_row "$id" "$to" "$type" "$delivery" "$age" "${unexpected[$i]}" "$excerpt" "${unexpected_tasks[$i]}"
    i=$((i + 1))
  done
  ROWS=$((ROWS + 1))
done < <(awk -F'\t' 'BEGIN { OFS = "\037" } { gsub(/\037/, " "); print $1, $2, $3, $4, $5, $6, $7, $8 }' "$SENT_LOG")

if [ "$ROWS" -eq 0 ]; then
  if [ -n "$TASK_FILTER" ]; then
    echo "No messages or replies tagged [task:${TASK_FILTER}] in the last ${SINCE_MIN} minute(s)."
  elif [ "$PENDING_ONLY" = "1" ]; then
    echo "All messages sent in the last ${SINCE_MIN} minute(s) have replies."
  else
    echo "No messages sent in the last ${SINCE_MIN} minute(s)."
  fi
else
  echo "—"
  echo "${ROWS} message(s) shown, ${PENDING} unconfirmed. 'unconfirmed' means no acceptable [re:<id>] reply has been correlated back yet — this tracks reply CORRELATION, not the recipient's task progress or liveness (use /pane-health for that). 'verified' means the reply came from the request's recipient and was recorded as received by this pane; 'recipient-unknown' rows predate that record and are not verified; 'unexpected' replies never count as answers."
fi
exit 0
