#!/usr/bin/env bash
# task-status.sh — read-only ledger view.
# Usage:
#   task-status.sh                 # active tasks (created/assigned)
#   task-status.sh <id>            # single task detail
#   task-status.sh --all           # all tasks
#   task-status.sh --pending       # status=created
#   task-status.sh --mine          # tasks where assigner=current pane
set -uo pipefail

source "$(dirname "$0")/lib.sh"

require_jq || exit 1
ensure_dirs

FILTER="active"
SINGLE_ID=""
case "${1:-}" in
  ""|--active) FILTER="active" ;;
  --all)       FILTER="all" ;;
  --pending)   FILTER="pending" ;;
  --mine)      FILTER="mine" ;;
  -h|--help)
    echo "Usage: task-status.sh [<id>|--active|--all|--pending|--mine]"
    exit 0
    ;;
  *)
    SINGLE_ID="$1"
    ;;
esac

if [ -n "$SINGLE_ID" ]; then
  validate_task_id "$SINGLE_ID" || exit 1
  if ! task_exists "$SINGLE_ID"; then
    echo "No task '$SINGLE_ID' in $TASKS_DIR." >&2
    exit 1
  fi
  jq . "$(task_path "$SINGLE_ID")"
  exit 0
fi

shopt -s nullglob
files=("$TASKS_DIR"/*.json)
shopt -u nullglob

if [ ${#files[@]} -eq 0 ]; then
  echo "No tasks in $TASKS_DIR. Create one with /task-new <name>."
  exit 0
fi

ME=$(current_pane_name)

printf 'ID\tSTATUS\tASSIGNER\tASSIGNEE\tNAME\tUPDATED\n'
shown=0
for f in "${files[@]}"; do
  row=$(jq -r '[.id, .status, .assigner, (.assignee // "-"), .name, .updated_at] | @tsv' "$f" 2>/dev/null) || continue
  status=$(printf '%s' "$row" | cut -f2)
  assigner=$(printf '%s' "$row" | cut -f3)
  case "$FILTER" in
    active)
      [[ "$status" == "created" || "$status" == "assigned" ]] || continue
      ;;
    pending)
      [[ "$status" == "created" ]] || continue
      ;;
    mine)
      [[ "$assigner" == "$ME" ]] || continue
      ;;
  esac
  printf '%s\n' "$row"
  shown=$((shown + 1))
done

echo
printf '%d task(s) shown (filter: %s).\n' "$shown" "$FILTER"
