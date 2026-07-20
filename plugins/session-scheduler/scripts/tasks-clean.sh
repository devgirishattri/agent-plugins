#!/usr/bin/env bash
# tasks-clean.sh — delete old ledger + prompt files. Dry-run by default.
# Usage: tasks-clean.sh [--older-than DAYS] [--status STATUS] [--apply]
set -uo pipefail

source "$(dirname "$0")/lib.sh"

require_jq || exit 1
ensure_dirs || exit 1

DAYS=7
STATUS_FILTER=""
APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --older-than) DAYS="${2:-7}"; shift 2 ;;
    --status)     STATUS_FILTER="${2:-}"; shift 2 ;;
    --apply)      APPLY=1; shift ;;
    -h|--help)
      echo "Usage: tasks-clean.sh [--older-than DAYS] [--status done|blocked|...] [--apply]"
      exit 0
      ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --older-than must be an integer." >&2
  exit 1
fi

shopt -s nullglob
files=("$TASKS_DIR"/*.json)
shopt -u nullglob

if [ ${#files[@]} -eq 0 ]; then
  echo "No tasks in $TASKS_DIR."
  exit 0
fi

now=$(date +%s)
threshold=$((now - DAYS * 86400))
candidates=()

for f in "${files[@]}"; do
  updated=$(jq -r '.updated_at' "$f" 2>/dev/null) || continue
  status=$(jq -r '.status' "$f" 2>/dev/null) || continue
  epoch=$(iso_to_epoch "$updated")
  if [ "$epoch" -le 0 ]; then
    echo "WARN: skipping $(basename "$f"): invalid updated_at '$updated'." >&2
    continue
  fi
  [ "$epoch" -ge "$threshold" ] && continue
  if [ -n "$STATUS_FILTER" ] && [ "$status" != "$STATUS_FILTER" ]; then continue; fi
  candidates+=("$f")
done

if [ ${#candidates[@]} -eq 0 ]; then
  echo "Nothing to clean (older than ${DAYS}d${STATUS_FILTER:+, status=$STATUS_FILTER})."
  exit 0
fi

if [ "$APPLY" -ne 1 ]; then
  echo "DRY-RUN: would delete ${#candidates[@]} task(s) older than ${DAYS}d${STATUS_FILTER:+, status=$STATUS_FILTER}:"
  for f in "${candidates[@]}"; do
    id=$(jq -r '.id' "$f")
    status=$(jq -r '.status' "$f")
    printf '  %s\t%s\t%s\n' "$id" "$status" "$(basename "$f")"
  done
  echo
  echo "Re-run with --apply to actually delete (also removes the matching prompt file)."
  exit 0
fi

deleted=0
for f in "${candidates[@]}"; do
  # Read the task's own .id before deleting the file.
  id=$(jq -r '.id' "$f" 2>/dev/null)
  # "$f" comes from the bounded "$TASKS_DIR"/*.json glob, so deleting it is safe.
  rm -f "$f"
  # The prompt path is derived from that .id (file content). Validate it first
  # so a crafted .id like "../../foo" can never steer rm outside PROMPTS_DIR —
  # validate_task_id forbids "/" and ".".
  if validate_task_id "$id" >/dev/null 2>&1; then
    rm -f "$(prompt_path "$id")"
  fi
  deleted=$((deleted + 1))
done
echo "Deleted ${deleted} task(s) and matching prompt files."
