#!/usr/bin/env bash
# check-status.sh — Check status of dispatched tasks
# Usage: check-status.sh [session-name|all]
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

FILTER="${1:-all}"
TASKS_DIR=".claude/dispatch/tasks"

# Validate input against path traversal/injection
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

  target=$(read_field "$task_dir/meta.txt" "target") || continue

  # Filter by session name if specified
  if [ "$FILTER" != "all" ] && [ "$target" != "$FILTER" ]; then
    continue
  fi

  status=$(cat "$task_dir/status.txt" 2>/dev/null || echo "unknown")
  pane_id=$(read_field "$task_dir/meta.txt" "pane_id")
  created_at=$(read_field "$task_dir/meta.txt" "created_at")

  # Check if pane is still alive for running tasks
  if [ "$status" = "running" ] && [ -n "$pane_id" ]; then
    if ! tmux display-message -t "$pane_id" -p '#{pane_id}' >/dev/null 2>&1; then
      echo "failed" > "$task_dir/status.txt"
      status="failed"
    fi
  fi

  printf '%s\t%s\t%s\t%s\n' "$target" "$status" "$pane_id" "$created_at"
  found=$((found + 1))
done

if [ "$found" -eq 0 ]; then
  if [ "$FILTER" = "all" ]; then
    echo "No dispatched tasks found."
  else
    echo "No task found for session: $FILTER"
  fi
fi
