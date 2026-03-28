#!/usr/bin/env bash
# check-status.sh — Check status of dispatched worker tasks
# Usage: check-status.sh [label|all]
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

FILTER="${1:-all}"
TASKS_DIR=".claude/dispatch/tasks"

# Validate label against path traversal/injection
if [ "$FILTER" != "all" ]; then
  validate_label "$FILTER" || exit 1
fi

if [ ! -d "$TASKS_DIR" ]; then
  echo "No dispatched tasks found."
  exit 0
fi

found=0

for task_dir in "$TASKS_DIR"/*/; do
  [ -d "$task_dir" ] || continue

  label=$(read_field "$task_dir/meta.txt" "label") || continue

  # Filter by label if specified
  if [ "$FILTER" != "all" ] && [ "$label" != "$FILTER" ]; then
    continue
  fi

  status=$(cat "$task_dir/status.txt" 2>/dev/null || echo "unknown")
  model=$(read_field "$task_dir/meta.txt" "model")
  pane_id=$(read_field "$task_dir/meta.txt" "pane_id")
  created_at=$(read_field "$task_dir/meta.txt" "created_at")

  # Check if pane is still alive for running tasks
  if [ "$status" = "running" ] && [ -n "$pane_id" ]; then
    if ! tmux display-message -t "$pane_id" -p '#{pane_id}' >/dev/null 2>&1; then
      echo "failed" > "$task_dir/status.txt"
      status="failed"
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$status" "$model" "$pane_id" "$created_at"
  found=$((found + 1))
done

if [ "$found" -eq 0 ]; then
  if [ "$FILTER" = "all" ]; then
    echo "No dispatched tasks found."
  else
    echo "No task found with label: $FILTER"
  fi
fi
