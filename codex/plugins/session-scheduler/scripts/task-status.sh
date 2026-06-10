#!/usr/bin/env bash
# task-status.sh — Show scheduler task status
# Usage: task-status.sh [id|--all|--pending|--mine|--by-stage]
# Flags column: OVERDUE (past eta_at), STALE (assigned/review with no update
# for SESSION_SCHEDULER_STALE_MINUTES, default 30).
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

require_jq || exit 1
ensure_dirs

MODE="${1:---active}"
MINE=$(current_pane_name)

ROW_FILTER='[.id,.status,(.stage // "-"),(if (.assignee // "") == "" then "-" else .assignee end),.assigner,.updated_at,.name] | @tsv'

# Single-task detail: row + flags + dependency statuses.
case "$MODE" in
  --all|--active|--pending|--mine|--by-stage) : ;;
  -*)
    echo "ERROR: Usage: task-status.sh [id|--all|--pending|--mine|--by-stage]" >&2
    exit 1
    ;;
  *)
    id="$MODE"
    task=$(task_file "$id") || exit 1
    [ -f "$task" ] || { echo "ERROR: Task not found: $id" >&2; exit 1; }
    printf 'ID\tStatus\tStage\tAssignee\tAssigner\tUpdated\tName\n'
    jq -r "$ROW_FILTER" "$task"
    flags=$(task_flags "$task")
    [ "$flags" != "-" ] && printf 'Flags\t%s\n' "$flags"
    deps=$(jq -r '(.depends_on // [])[]' "$task" 2>/dev/null)
    if [ -n "$deps" ]; then
      echo "Dependencies:"
      while IFS= read -r dep; do
        [ -z "$dep" ] && continue
        dfile=$(task_file "$dep" 2>/dev/null) || dfile=""
        if [ -n "$dfile" ] && [ -f "$dfile" ]; then
          dstatus=$(jq -r '.status // ""' "$dfile")
        else
          dstatus="missing"
        fi
        printf '  %s\t%s\n' "$dep" "$dstatus"
      done <<< "$deps"
    fi
    exit 0
    ;;
esac

if [ "$MODE" = "--by-stage" ]; then
  rows=""
  shown=0
  for file in "$TASKS_DIR"/*.json; do
    [ -f "$file" ] || continue
    status=$(jq -r '.status // ""' "$file" 2>/dev/null) || continue
    [ "$status" = "done" ] && continue
    row=$(jq -r '[(.stage // "(none)"),.id,.status,(if (.assignee // "") == "" then "-" else .assignee end),.assigner,.updated_at,.name] | @tsv' "$file" 2>/dev/null) || continue
    flags=$(task_flags "$file")
    rows="${rows}${row}	${flags}
"
    shown=$((shown + 1))
  done
  if [ "$shown" -eq 0 ]; then
    echo "No non-done tasks in $TASKS_DIR."
    exit 0
  fi
  printf '%s' "$rows" | sort -t '	' -k1,1 | awk -F'\t' '
    $1 != prev {
      if (prev != "") print ""
      print "Stage: " $1
      print "  ID\tStatus\tAssignee\tAssigner\tUpdated\tFlags\tName"
      prev = $1
    }
    {
      printf "  %s\t%s\t%s\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5, $6, $8, $7
    }'
  exit 0
fi

printf 'ID\tStatus\tStage\tAssignee\tAssigner\tUpdated\tFlags\tName\n'

for file in "$TASKS_DIR"/*.json; do
  [ -f "$file" ] || continue
  row=""
  case "$MODE" in
    --all)
      row=$(jq -r "$ROW_FILTER" "$file")
      ;;
    --pending|--active)
      row=$(jq -r "select(.status != \"done\" and .status != \"blocked\") | $ROW_FILTER" "$file")
      ;;
    --mine)
      row=$(jq -r --arg mine "$MINE" "select(.assignee == \$mine or .assigner == \$mine) | $ROW_FILTER" "$file")
      ;;
  esac
  [ -z "$row" ] && continue
  flags=$(task_flags "$file")
  # Reorder: id status stage assignee assigner updated FLAGS name
  printf '%s\n' "$row" | awk -F'\t' -v flags="$flags" \
    '{ printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5, $6, flags, $7 }'
done
exit 0
