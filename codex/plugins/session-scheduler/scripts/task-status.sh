#!/usr/bin/env bash
# task-status.sh — Show scheduler task status
# Usage: task-status.sh [id|--all|--pending|--mine]
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

require_jq || exit 1
ensure_dirs

MODE="${1:---active}"
MINE=$(current_pane_name)

printf 'ID\tStatus\tAssignee\tAssigner\tUpdated\tName\n'

for file in "$TASKS_DIR"/*.json; do
  [ -f "$file" ] || continue
  case "$MODE" in
    --all)
      jq -r '[.id,.status,.assignee,.assigner,.updated_at,.name] | @tsv' "$file"
      ;;
    --pending|--active)
      jq -r 'select(.status != "done" and .status != "blocked") | [.id,.status,.assignee,.assigner,.updated_at,.name] | @tsv' "$file"
      ;;
    --mine)
      jq -r --arg mine "$MINE" 'select(.assignee == $mine or .assigner == $mine) | [.id,.status,.assignee,.assigner,.updated_at,.name] | @tsv' "$file"
      ;;
    -*)
      echo "ERROR: Usage: task-status.sh [id|--all|--pending|--mine]" >&2
      exit 1
      ;;
    *)
      id="$MODE"
      task=$(task_file "$id") || exit 1
      [ -f "$task" ] || { echo "ERROR: Task not found: $id" >&2; exit 1; }
      jq -r '[.id,.status,.assignee,.assigner,.updated_at,.name] | @tsv' "$task"
      exit 0
      ;;
  esac
done
