#!/usr/bin/env bash
# messages-list.sh — Read-only inventory of dispatched message files.
# Usage: messages-list.sh [--from NAME] [--to NAME]
set -uo pipefail

source "$(dirname "$0")/lib.sh"

FROM=""
TO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="${2:-}"; shift 2 ;;
    --to)   TO="${2:-}";   shift 2 ;;
    -h|--help)
      echo "Usage: messages-list.sh [--from NAME] [--to NAME]"
      exit 0
      ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

ensure_messages_dir

shopt -s nullglob
files=("$MESSAGES_DIR"/*.md)
shopt -u nullglob

if [ "${#files[@]}" -eq 0 ]; then
  echo "No dispatched messages in $MESSAGES_DIR."
  exit 0
fi

now=$(date +%s)
total_bytes=0
count=0
printf 'AGE\tSIZE\tFROM\tTO\tFILE\n'
for f in "${files[@]}"; do
  base=$(basename "$f")
  # Names: <epoch>-<pid>-<id>-<from>-to-<to>.md or legacy <epoch>-<from>-to-<to>.md
  # (see parse_message_filename; the sender is never guessed out of the name).
  parse_message_filename "$base" || continue
  epoch="$MF_EPOCH"; from="$MF_FROM"; to="$MF_TO"
  if [ -n "$FROM" ] && [ "$from" != "$FROM" ]; then continue; fi
  if [ -n "$TO" ] && [ "$to" != "$TO" ]; then continue; fi
  age_s=$(( now - epoch ))
  if [ "$age_s" -lt 60 ]; then
    age="${age_s}s"
  elif [ "$age_s" -lt 3600 ]; then
    age="$((age_s / 60))m"
  elif [ "$age_s" -lt 86400 ]; then
    age="$((age_s / 3600))h"
  else
    age="$((age_s / 86400))d"
  fi
  size=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
  total_bytes=$((total_bytes + size))
  count=$((count + 1))
  printf '%s\t%sB\t%s\t%s\t%s\n' "$age" "$size" "$from" "$to" "$base"
done

echo
printf 'Total: %d files, %d bytes in %s\n' "$count" "$total_bytes" "$MESSAGES_DIR"
