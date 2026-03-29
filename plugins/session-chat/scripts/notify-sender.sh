#!/usr/bin/env bash
# notify-sender.sh — Stop hook: write result and notify the dispatching pane
# Called automatically when a worker session exits
# Supported platforms: macOS, Linux
set -uo pipefail

# Quick exit if not inside tmux
[ -z "${TMUX:-}" ] && exit 0

TASKS_DIR=".claude/dispatch/tasks"

# Quick exit if no dispatch directory
[ -d "$TASKS_DIR" ] || exit 0

source "$(dirname "$0")/lib.sh"

# Find task for this pane
TASK_META=""
for meta in "$TASKS_DIR"/*/meta.txt; do
  [ -f "$meta" ] || continue
  pane_id=$(read_field "$meta" "pane_id")
  if [ "$pane_id" = "$TMUX_PANE" ]; then
    TASK_META="$meta"
    break
  fi
done

# Quick exit if this pane is not a dispatched worker
[ -z "$TASK_META" ] && exit 0

TASK_DIR=$(dirname "$TASK_META")
STATUS=$(cat "$TASK_DIR/status.txt" 2>/dev/null || echo "unknown")

# Only process running tasks
[ "$STATUS" != "running" ] && exit 0

LABEL=$(read_field "$TASK_META" "target")
SENDER_PANE=$(read_field "$TASK_META" "sender_pane")

# Read hook input from stdin to get transcript path
HOOK_INPUT=$(cat)
TRANSCRIPT=$(echo "$HOOK_INPUT" | sed -n 's/.*"transcript_path":"\([^"]*\)".*/\1/p' | head -1)

# Extract last assistant message from transcript
RESULT_TEXT=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  # Get last assistant text block from JSONL transcript
  RESULT_TEXT=$(grep -a '"type":"assistant"' "$TRANSCRIPT" 2>/dev/null | tail -1 | \
    sed -n 's/.*"message":"\([^"]*\)".*/\1/p' | head -c 2000) || true
fi

# If no transcript text, try capturing pane content as fallback
if [ -z "$RESULT_TEXT" ]; then
  RESULT_TEXT=$(tmux capture-pane -t "$TMUX_PANE" -p 2>/dev/null | tail -50) || true
fi

# Write result
if [ -n "$RESULT_TEXT" ]; then
  echo "$RESULT_TEXT" > "$TASK_DIR/result.md"
fi

# Update status
echo "completed" > "$TASK_DIR/status.txt"

# Notify sender pane (if it still exists)
if [ -n "$SENDER_PANE" ]; then
  if tmux display-message -t "$SENDER_PANE" -p '#{pane_id}' >/dev/null 2>&1; then
    NOTIFICATION="[from:worker:$LABEL pane:$TMUX_PANE] Task completed. Run /dispatch-collect $LABEL"
    tmux send-keys -t "$SENDER_PANE" -l -- "$NOTIFICATION" 2>/dev/null || true
    sleep 0.1
    tmux send-keys -t "$SENDER_PANE" Enter 2>/dev/null || true
  fi
fi

# Allow session to exit
exit 0
