#!/usr/bin/env bash
# messages-clean.sh — Delete old dispatched message files. Dry-run by default.
# Usage: messages-clean.sh [--older-than DAYS] [--from NAME] [--to NAME] [--apply]
set -uo pipefail

source "$(dirname "$0")/lib.sh"

DAYS=7
FROM=""
TO=""
APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --older-than) DAYS="${2:-7}"; shift 2 ;;
    --from)       FROM="${2:-}";  shift 2 ;;
    --to)         TO="${2:-}";    shift 2 ;;
    --apply)      APPLY=1;        shift ;;
    -h|--help)
      echo "Usage: messages-clean.sh [--older-than DAYS] [--from NAME] [--to NAME] [--apply]"
      echo "Default: dry-run, --older-than 7. Files newer than the threshold are kept."
      exit 0
      ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --older-than must be an integer (days)." >&2
  exit 1
fi

ensure_messages_dir

shopt -s nullglob
files=("$MESSAGES_DIR"/*.md)
shopt -u nullglob

if [ "${#files[@]}" -eq 0 ]; then
  echo "No dispatched messages in $MESSAGES_DIR."
  exit 0
fi

now=$(date +%s)
threshold=$(( now - DAYS * 86400 ))

candidates=()
for f in "${files[@]}"; do
  base=$(basename "$f")
  epoch="${base%%-*}"
  if ! [[ "$epoch" =~ ^[0-9]+$ ]]; then continue; fi
  if [ "$epoch" -ge "$threshold" ]; then continue; fi
  rest="${base%.md}"
  rest="${rest#*-}"
  from="${rest%-to-*}"
  to="${rest##*-to-}"
  while [[ "$from" =~ ^[0-9]+- ]] || [[ "$from" =~ ^[0-9a-f]{8}- ]]; do
    from="${from#*-}"
  done
  if [ -n "$FROM" ] && [ "$from" != "$FROM" ]; then continue; fi
  if [ -n "$TO" ] && [ "$to" != "$TO" ]; then continue; fi
  candidates+=("$f")
done

if [ "${#candidates[@]}" -eq 0 ]; then
  echo "Nothing to clean (threshold: older than ${DAYS}d)."
  exit 0
fi

if [ "$APPLY" -ne 1 ]; then
  echo "DRY-RUN: would delete ${#candidates[@]} files older than ${DAYS}d:"
  for f in "${candidates[@]}"; do echo "  $(basename "$f")"; done
  echo
  echo "Re-run with --apply to actually delete."
  exit 0
fi

deleted=0
for f in "${candidates[@]}"; do
  if rm -f "$f"; then deleted=$((deleted + 1)); fi
done
echo "Deleted ${deleted} file(s) older than ${DAYS}d."
