#!/usr/bin/env bash
# tasks-clean.sh — Dry-run or delete scheduler task files
# Usage: tasks-clean.sh [--older-than 7d] [--status status] [--apply]
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

OLDER_THAN="7d"
STATUS_FILTER=""
APPLY=0

usage() {
  echo "Usage: tasks-clean.sh [--older-than 7d] [--status status] [--apply]"
}

duration_to_seconds() {
  local value="$1"
  local number unit
  number="${value%[smhd]}"
  unit="${value#"$number"}"
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

while [ "$#" -gt 0 ]; do
  case "$1" in
    --older-than)
      [ "$#" -ge 2 ] || { usage >&2; exit 1; }
      OLDER_THAN="$2"
      shift 2
      ;;
    --status)
      [ "$#" -ge 2 ] || { usage >&2; exit 1; }
      STATUS_FILTER="$2"
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

require_jq || exit 1
ensure_dirs || exit 1
threshold=$(duration_to_seconds "$OLDER_THAN") || {
  echo "ERROR: Invalid duration: $OLDER_THAN. Use values like 7d, 12h, 30m, or 60s." >&2
  exit 1
}
now=$(now_epoch)
count=0

for file in "$TASKS_DIR"/*.json; do
  [ -f "$file" ] || continue
  status=$(jq -r '.status // ""' "$file")
  [ -n "$STATUS_FILTER" ] && [ "$status" != "$STATUS_FILTER" ] && continue
  updated=$(jq -r '.updated_at // ""' "$file" 2>/dev/null)
  updated_epoch=$(iso_to_epoch "$updated")
  if [ "$updated_epoch" -le 0 ]; then
    echo "WARN: skipping $(basename "$file"): invalid updated_at '$updated'." >&2
    continue
  fi
  age=$((now - updated_epoch))
  [ "$age" -lt "$threshold" ] && continue
  id=$(jq -r '.id // ""' "$file" 2>/dev/null)
  count=$((count + 1))
  if [ "$APPLY" -eq 1 ]; then
    rm -f "$file"
    prompt=$(prompt_file "$id" 2>/dev/null) && rm -f "$prompt"
    printf 'Deleted\t%s\n' "$id"
  else
    printf 'Would delete\t%s\tstatus=%s\tage=%ss\n' "$id" "$status" "$age"
  fi
done

if [ "$APPLY" -eq 1 ]; then
  printf 'Summary\tdeleted=%s\n' "$count"
else
  printf 'Summary\twould_delete=%s\n' "$count"
  echo "Dry run only. Re-run with --apply to delete matching tasks."
fi
