#!/usr/bin/env bash
# task-status.sh — Show scheduler task status
# Usage: task-status.sh [id|--all|--pending|--mine|--by-stage|--by-workflow|--workflow ID]
# Flags column: OVERDUE (past eta_at while still actionable — not done, not
# blocked), STALE (assigned/review with no update for
# SESSION_SCHEDULER_STALE_MINUTES, default 30).
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

require_jq || exit 1
ensure_dirs || exit 1

MODE="${1:---active}"
WORKFLOW_FILTER=""
if [ "$MODE" = "--workflow" ]; then
  WORKFLOW_FILTER="${2:-}"
  validate_route_name "workflow id" "$WORKFLOW_FILTER" || exit 1
fi
MINE=$(current_pane_name)

ROW_FILTER='[.id,.status,(.meta.workflow_id // .workflow_id // "-"),(.stage // "-"),(if (.assignee // "") == "" then "-" else .assignee end),(.reviewer // "-"),.assigner,.updated_at,.name] | @tsv'

# Single-task detail: row + flags + dependency statuses.
case "$MODE" in
  --all|--active|--pending|--mine|--by-stage|--by-workflow|--workflow) : ;;
  -*)
    echo "ERROR: Usage: task-status.sh [id|--all|--pending|--mine|--by-stage|--by-workflow|--workflow ID]" >&2
    exit 1
    ;;
  *)
    id="$MODE"
    task=$(task_file "$id") || exit 1
    [ -f "$task" ] || { echo "ERROR: Task not found: $id" >&2; exit 1; }
    printf 'ID\tStatus\tWorkflow\tStage\tAssignee\tReviewer\tAssigner\tUpdated\tName\n'
    jq -r "$ROW_FILTER" "$task"
    flags=$(task_flags "$task")
    [ "$flags" != "-" ] && printf 'Flags\t%s\n' "$flags"
    home=$(jq -r '.meta.scheduler_home // .scheduler_home // empty' "$task")
    [ -n "$home" ] && printf 'Scheduler home\t%s\n' "$home"
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

if [ "$MODE" = "--by-stage" ] || [ "$MODE" = "--by-workflow" ]; then
  rows=""
  shown=0
  group_label="Stage"
  if [ "$MODE" = "--by-workflow" ]; then
    group_label="Workflow"
  fi
  for file in "$TASKS_DIR"/*.json; do
    [ -f "$file" ] || continue
    if [ "$MODE" = "--by-workflow" ]; then
      # A workflow view represents the whole arc, including completed steps.
      # Records without a workflow id do not belong to a workflow group.
      group=$(jq -r '.meta.workflow_id // .workflow_id // empty' "$file" 2>/dev/null) || continue
      [ -n "$group" ] || continue
    else
      status=$(jq -r '.status // ""' "$file" 2>/dev/null) || continue
      [ "$status" = "done" ] && continue
      group=$(jq -r '.stage // "(none)"' "$file" 2>/dev/null) || continue
    fi
    row=$(jq -r --arg group "$group" '[$group,.id,.status,(if (.assignee // "") == "" then "-" else .assignee end),(.reviewer // "-"),.assigner,.updated_at,.name] | @tsv' "$file" 2>/dev/null) || continue
    flags=$(task_flags "$file")
    rows="${rows}${row}"$'\t'"${flags}"$'\n'
    shown=$((shown + 1))
  done
  if [ "$shown" -eq 0 ]; then
    if [ "$MODE" = "--by-workflow" ]; then
      echo "No tasks with a workflow id in $TASKS_DIR."
    else
      echo "No non-done tasks in $TASKS_DIR."
    fi
    exit 0
  fi
  printf '%s' "$rows" | sort -t '	' -k1,1 | awk -F'\t' -v label="$group_label" '
    $1 != prev {
      if (prev != "") print ""
      print label ": " $1
      print "  ID\tStatus\tAssignee\tReviewer\tAssigner\tUpdated\tFlags\tName"
      prev = $1
    }
    {
      printf "  %s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5, $6, $7, $9, $8
    }'
  exit 0
fi

printf 'ID\tStatus\tWorkflow\tStage\tAssignee\tReviewer\tAssigner\tUpdated\tFlags\tName\n'

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
      row=$(jq -r --arg mine "$MINE" "select(.assignee == \$mine or .assigner == \$mine or .reviewer == \$mine) | $ROW_FILTER" "$file")
      ;;
    --workflow)
      row=$(jq -r --arg workflow "$WORKFLOW_FILTER" "select((.meta.workflow_id // .workflow_id // \"\") == \$workflow) | $ROW_FILTER" "$file")
      ;;
  esac
  [ -z "$row" ] && continue
  flags=$(task_flags "$file")
  # Reorder: id status workflow stage assignee reviewer assigner updated FLAGS name
  printf '%s\n' "$row" | awk -F'\t' -v flags="$flags" \
    '{ printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5, $6, $7, $8, flags, $9 }'
done
exit 0
