#!/usr/bin/env bash
# task-status.sh — read-only ledger view.
# Usage:
#   task-status.sh                 # active tasks (created/assigned/review)
#   task-status.sh <id>            # single task detail (incl. deps + flags)
#   task-status.sh --all           # all tasks
#   task-status.sh --pending       # status=created
#   task-status.sh --mine          # tasks where assigner=current pane
#   task-status.sh --by-stage      # non-done tasks grouped by stage
#   task-status.sh --by-workflow   # tasks grouped by meta.workflow_id
#   task-status.sh --workflow ID   # tasks in one workflow
# Flags column: OVERDUE (past eta_at while still actionable — not done, not
# blocked), STALE (assigned/review with no update for
# SESSION_SCHEDULER_STALE_MINUTES, default 30).
set -uo pipefail

source "$(dirname "$0")/lib.sh"

require_jq || exit 1
ensure_dirs || exit 1

FILTER="active"
SINGLE_ID=""
WORKFLOW=""
case "${1:-}" in
  ""|--active) FILTER="active" ;;
  --all)       FILTER="all" ;;
  --pending)   FILTER="pending" ;;
  --mine)      FILTER="mine" ;;
  --by-stage)  FILTER="by-stage" ;;
  --by-workflow) FILTER="by-workflow" ;;
  --workflow)
    FILTER="workflow"
    WORKFLOW="${2:-}"
    [ -n "$WORKFLOW" ] || { echo "ERROR: --workflow requires an id." >&2; exit 1; }
    validate_workflow_id "$WORKFLOW" || exit 1
    ;;
  -h|--help)
    echo "Usage: task-status.sh [<id>|--active|--all|--pending|--mine|--by-stage|--by-workflow|--workflow ID]"
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
  flags=$(task_flags "$(task_path "$SINGLE_ID")")
  if [ "$flags" != "-" ]; then
    echo
    echo "Flags: $flags"
  fi
  deps=$(task_get "$SINGLE_ID" '(.depends_on // [])[]')
  if [ -n "$deps" ]; then
    echo
    echo "Dependencies:"
    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      if task_exists "$dep"; then
        dstatus=$(task_get "$dep" '.status')
      else
        dstatus="missing"
      fi
      printf '  %s\t%s\n' "$dep" "$dstatus"
    done <<< "$deps"
  fi
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

if [ "$FILTER" = "by-stage" ]; then
  rows=""
  shown=0
  for f in "${files[@]}"; do
    status=$(jq -r '.status // ""' "$f" 2>/dev/null) || continue
    [ "$status" = "done" ] && continue
    row=$(jq -r '[(.stage // "(none)"), .id, .status, .assigner, (.assignee // "-"), .name, .updated_at] | @tsv' "$f" 2>/dev/null) || continue
    flags=$(task_flags "$f")
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
      print "  ID\tSTATUS\tASSIGNER\tASSIGNEE\tNAME\tUPDATED\tFLAGS"
      prev = $1
    }
    {
      printf "  %s\t%s\t%s\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5, $6, $7, $8
    }'
  echo
  printf '%d task(s) shown (filter: by-stage, non-done).\n' "$shown"
  exit 0
fi

if [ "$FILTER" = "by-workflow" ]; then
  # Group every task carrying a workflow_id by that id (whole arc, including
  # done steps). Tasks with no workflow_id are omitted.
  rows=""
  shown=0
  for f in "${files[@]}"; do
    wf=$(jq -r '.meta.workflow_id // ""' "$f" 2>/dev/null) || continue
    [ -z "$wf" ] && continue
    row=$(jq -r --arg wf "$wf" '[$wf, .id, .status, (.stage // "-"), .assigner, (.assignee // "-"), .name, .updated_at] | @tsv' "$f" 2>/dev/null) || continue
    flags=$(task_flags "$f")
    rows="${rows}${row}	${flags}
"
    shown=$((shown + 1))
  done
  if [ "$shown" -eq 0 ]; then
    echo "No tasks with a workflow_id. Set one via /task-new --workflow ID or /task-assign --workflow ID."
    exit 0
  fi
  printf '%s' "$rows" | sort -t '	' -k1,1 | awk -F'\t' '
    $1 != prev {
      if (prev != "") print ""
      print "Workflow: " $1
      print "  ID\tSTATUS\tSTAGE\tASSIGNER\tASSIGNEE\tNAME\tUPDATED\tFLAGS"
      prev = $1
    }
    {
      printf "  %s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $2, $3, $4, $5, $6, $7, $8, $9
    }'
  echo
  printf '%d task(s) shown (filter: by-workflow).\n' "$shown"
  exit 0
fi

printf 'ID\tSTATUS\tSTAGE\tASSIGNER\tASSIGNEE\tNAME\tUPDATED\tFLAGS\n'
shown=0
for f in "${files[@]}"; do
  row=$(jq -r '[.id, .status, (.stage // "-"), .assigner, (.assignee // "-"), .name, .updated_at] | @tsv' "$f" 2>/dev/null) || continue
  status=$(printf '%s' "$row" | cut -f2)
  assigner=$(printf '%s' "$row" | cut -f4)
  case "$FILTER" in
    active)
      [[ "$status" == "created" || "$status" == "assigned" || "$status" == "review" ]] || continue
      ;;
    pending)
      [[ "$status" == "created" ]] || continue
      ;;
    mine)
      [[ "$assigner" == "$ME" ]] || continue
      ;;
    workflow)
      wf=$(jq -r '.meta.workflow_id // ""' "$f" 2>/dev/null)
      [[ "$wf" == "$WORKFLOW" ]] || continue
      ;;
  esac
  flags=$(task_flags "$f")
  printf '%s\t%s\n' "$row" "$flags"
  shown=$((shown + 1))
done

echo
printf '%d task(s) shown (filter: %s).\n' "$shown" "$FILTER"
