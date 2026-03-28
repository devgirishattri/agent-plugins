#!/usr/bin/env bash
# cancel-worker.sh — Cancel a running worker task by killing its tmux pane
# Usage: cancel-worker.sh <label|all>
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

FILTER="${1:-}"
TASKS_DIR=".claude/dispatch/tasks"

if [ -z "$FILTER" ]; then
  echo "ERROR: Usage: cancel-worker.sh <label|all>"
  exit 1
fi

# Validate label against path traversal/injection
if [ "$FILTER" != "all" ]; then
  validate_label "$FILTER" || exit 1
fi

if [ ! -d "$TASKS_DIR" ]; then
  echo "No dispatched tasks found."
  exit 0
fi

cancelled=0

for task_dir in "$TASKS_DIR"/*/; do
  [ -d "$task_dir" ] || continue

  label=$(read_field "$task_dir/meta.txt" "label") || continue

  # Filter by label if specified
  if [ "$FILTER" != "all" ] && [ "$label" != "$FILTER" ]; then
    continue
  fi

  status=$(cat "$task_dir/status.txt" 2>/dev/null || echo "unknown")

  if [ "$status" = "running" ]; then
    pane_id=$(read_field "$task_dir/meta.txt" "pane_id")
    if [ -n "$pane_id" ]; then
      tmux kill-pane -t "$pane_id" 2>/dev/null || true
    fi
    echo "cancelled" > "$task_dir/status.txt"
    echo "Cancelled: $label (pane $pane_id)"
    cancelled=$((cancelled + 1))
  fi
done

if [ "$cancelled" -eq 0 ]; then
  echo "No running tasks to cancel."
fi
