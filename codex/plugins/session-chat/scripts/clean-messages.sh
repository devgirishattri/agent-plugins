#!/usr/bin/env bash
# clean-messages.sh — Dry-run or delete trusted session-chat message files
# Usage: clean-messages.sh [--older-than 7d] [--sender name] [--recipient name] [--apply]
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

OLDER_THAN="7d"
FILTER_SENDER=""
FILTER_RECIPIENT=""
APPLY=0

usage() {
  echo "Usage: clean-messages.sh [--older-than 7d] [--sender name] [--recipient name] [--apply]"
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
    --apply)
      APPLY=1
      shift
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

threshold_seconds=$(duration_to_seconds "$OLDER_THAN") || {
  echo "ERROR: Invalid duration: $OLDER_THAN. Use a value like 7d, 12h, 30m, or 60s." >&2
  exit 1
}

ensure_messages_dir || exit 1
now=$(date +%s)
count=0
total_size=0

while IFS= read -r file; do
  base=$(basename "$file")
  parse_message_name "$base"
  case "$MSG_TS" in
    ''|*[!0-9]*) age=0 ;;
    *) age=$((now - MSG_TS)) ;;
  esac
  [ "$age" -lt "$threshold_seconds" ] && continue
  [ -n "$FILTER_SENDER" ] && [ "$MSG_SENDER" != "$FILTER_SENDER" ] && continue
  [ -n "$FILTER_RECIPIENT" ] && [ "$MSG_RECIPIENT" != "$FILTER_RECIPIENT" ] && continue
  size=$(wc -c < "$file" | tr -d ' ')
  count=$((count + 1))
  total_size=$((total_size + size))
  if [ "$APPLY" -eq 1 ]; then
    rm -f "$file"
    printf 'Deleted\t%s\n' "$file"
  else
    printf 'Would delete\t%s\n' "$file"
  fi
done < <(find "$MESSAGES_DIR" -maxdepth 1 -type f -name '*.md' -print | sort)

if [ "$APPLY" -eq 1 ]; then
  printf 'Summary\tdeleted=%s\ttotal_bytes=%s\n' "$count" "$total_size"
else
  printf 'Summary\twould_delete=%s\ttotal_bytes=%s\n' "$count" "$total_size"
  echo "Dry run only. Re-run with --apply to delete matching files."
fi
