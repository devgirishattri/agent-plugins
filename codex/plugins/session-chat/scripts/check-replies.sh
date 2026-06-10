#!/usr/bin/env bash
# check-replies.sh — Correlate messages this pane sent with replies that came
# back. A reply is any incoming message containing a [re:<id>] token where
# <id> is a message id this pane previously sent (/send and /dispatch print
# the id; recipients are asked to include [re:<id>] in their acks).
# Usage: check-replies.sh [--pending] [--since MINUTES]
#   --pending        only show sent messages still awaiting a reply
#   --since MINUTES  look-back window for sent messages (default 1440 = 24h)
# Output: TSV rows  <id> <to> <type> <delivery> <age> <reply> <excerpt>
set -uo pipefail

source "$(dirname "$0")/lib.sh"

PENDING_ONLY=0
SINCE_MIN=1440
while [ $# -gt 0 ]; do
  case "$1" in
    --pending) PENDING_ONLY=1 ;;
    --since)
      shift
      SINCE_MIN=$(normalize_positive_int "${1:-1440}" 1440)
      ;;
    -h|--help)
      echo "Usage: check-replies.sh [--pending] [--since MINUTES]"
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

ROWS=0
PENDING=0
HEADER_PRINTED=0
while IFS=$'\t' read -r ts id from to type delivery excerpt; do
  [ -n "$id" ] || continue
  is_nonnegative_int "$ts" || continue
  [ "$ts" -ge "$CUTOFF" ] || continue
  reply_from=""
  if [ -f "$REPLIES_LOG" ]; then
    reply_from=$(awk -F'\t' -v id="$id" '$2 == id { print $3; exit }' "$REPLIES_LOG" 2>/dev/null)
  fi
  if [ -n "$reply_from" ]; then
    [ "$PENDING_ONLY" = "1" ] && continue
    reply="replied:${reply_from}"
  else
    reply="awaiting"
    PENDING=$((PENDING + 1))
  fi
  if [ "$HEADER_PRINTED" = "0" ]; then
    printf 'ID\tTO\tTYPE\tDELIVERY\tAGE\tREPLY\tEXCERPT\n'
    HEADER_PRINTED=1
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$to" "$type" "$delivery" "$(age_human "$ts")" "$reply" "$excerpt"
  ROWS=$((ROWS + 1))
done < "$SENT_LOG"

if [ "$ROWS" -eq 0 ]; then
  if [ "$PENDING_ONLY" = "1" ]; then
    echo "All messages sent in the last ${SINCE_MIN} minute(s) have replies."
  else
    echo "No messages sent in the last ${SINCE_MIN} minute(s)."
  fi
else
  echo "—"
  echo "${ROWS} message(s) shown, ${PENDING} awaiting a reply. Replies are matched by [re:<id>] tokens in incoming messages."
fi
exit 0
