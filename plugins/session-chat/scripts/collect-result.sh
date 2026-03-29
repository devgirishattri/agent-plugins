#!/usr/bin/env bash
# collect-result.sh — Read results from completed dispatched tasks
# Usage: collect-result.sh [session-name|all]
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

  if [ "$status" = "completed" ]; then
    echo "=== $target ==="
    if [ -f "$task_dir/result.md" ]; then
      cat "$task_dir/result.md"
    else
      echo "(No result captured)"
    fi
    echo ""
    found=$((found + 1))
  fi
done

if [ "$found" -eq 0 ]; then
  if [ "$FILTER" = "all" ]; then
    echo "No completed tasks to collect."
  else
    echo "Task for '$FILTER' is not completed yet or does not exist."
  fi
fi
