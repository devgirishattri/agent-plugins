#!/usr/bin/env bash
# list-messages.sh — List trusted session-chat message files
# Usage: list-messages.sh [--older-than 7d] [--sender name] [--recipient name]
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

OLDER_THAN=""
FILTER_SENDER=""
FILTER_RECIPIENT=""

usage() {
  echo "Usage: list-messages.sh [--older-than 7d] [--sender name] [--recipient name]"
}

duration_to_seconds() {
  local value="$1"
  local number unit
  number="${value%[smhd]}"
  unit="${value#$number}"
  case "$number" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$unit" in
    s|'') printf '%s\n' "$number" ;;
    m) printf '%s\n' $((number * 60)) ;;
    h) printf '%s\n' $((number * 3600)) ;;
    d) printf '%s\n' $((number * 86400)) ;;
    *) return 1 ;;
  esac
}

parse_message_name() {
  local base="$1"
  MSG_TS="${base%%-*}"
  local rest="${base%.md}"
  rest="${rest#*-}"
  rest="${rest#*-}"
  rest="${rest#*-}"
  MSG_SENDER=""
  MSG_RECIPIENT=""

  if [[ "$rest" == *-to-* ]]; then
    MSG_SENDER="${rest%-to-*}"
    MSG_RECIPIENT="${rest##*-to-}"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --older-than)
      [ "$#" -ge 2 ] || { usage >&2; exit 1; }
      OLDER_THAN="$2"
      shift 2
      ;;
    --sender)
      [ "$#" -ge 2 ] || { usage >&2; exit 1; }
      FILTER_SENDER="$2"
      shift 2
      ;;
    --recipient)
      [ "$#" -ge 2 ] || { usage >&2; exit 1; }
      FILTER_RECIPIENT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

threshold_seconds=""
if [ -n "$OLDER_THAN" ]; then
  threshold_seconds=$(duration_to_seconds "$OLDER_THAN") || {
    echo "ERROR: Invalid duration: $OLDER_THAN. Use a value like 7d, 12h, 30m, or 60s." >&2
    exit 1
  }
fi

ensure_messages_dir || exit 1
now=$(date +%s)
count=0
total_size=0

printf 'File\tAgeSeconds\tSizeBytes\tSender\tRecipient\n'
while IFS= read -r file; do
  base=$(basename "$file")
  parse_message_name "$base"
  case "$MSG_TS" in
    ''|*[!0-9]*) age=0 ;;
    *) age=$((now - MSG_TS)) ;;
  esac
  [ -n "$threshold_seconds" ] && [ "$age" -lt "$threshold_seconds" ] && continue
  [ -n "$FILTER_SENDER" ] && [ "$MSG_SENDER" != "$FILTER_SENDER" ] && continue
  [ -n "$FILTER_RECIPIENT" ] && [ "$MSG_RECIPIENT" != "$FILTER_RECIPIENT" ] && continue
  size=$(wc -c < "$file" | tr -d ' ')
  count=$((count + 1))
  total_size=$((total_size + size))
  printf '%s\t%s\t%s\t%s\t%s\n' "$file" "$age" "$size" "$MSG_SENDER" "$MSG_RECIPIENT"
done < <(find "$MESSAGES_DIR" -maxdepth 1 -type f -name '*.md' -print | sort)

printf 'Summary\tcount=%s\ttotal_bytes=%s\n' "$count" "$total_size"
