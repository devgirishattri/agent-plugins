#!/usr/bin/env bash
# create-worker.sh — Create a tmux pane with a full Claude session and send a task
# Usage: create-worker.sh <label> <prompt-file> [model] [cwd]
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

LABEL="${1:-}"
PROMPT_FILE="${2:-}"
MODEL="${3:-sonnet}"
CWD="${4:-$(pwd)}"

if [ -z "$LABEL" ] || [ -z "$PROMPT_FILE" ]; then
  echo "ERROR: Usage: create-worker.sh <label> <prompt-file> [model] [cwd]"
  exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: Prompt file not found: $PROMPT_FILE"
  exit 1
fi

ensure_tmux

# Validate inputs against injection
validate_label "$LABEL" || exit 1
validate_model "$MODEL" || exit 1

# Verify sender has a name
MY_NAME=$(get_my_name)
if [ -z "$MY_NAME" ]; then
  echo "ERROR: This pane has no name. Run /whoami <name> first."
  exit 1
fi

# Create task state directory
ensure_dispatch_dir
TASK_DIR=$(task_dir "$LABEL")
if [ -d "$TASK_DIR" ]; then
  echo "ERROR: Task '$LABEL' already exists. Use a different label or cancel the existing one."
  exit 1
fi
mkdir -p "$TASK_DIR"

# Write task files
cp "$PROMPT_FILE" "$TASK_DIR/prompt.txt"
echo "running" > "$TASK_DIR/status.txt"

cat > "$TASK_DIR/meta.txt" <<EOF
label: $LABEL
model: $MODEL
sender_pane: $TMUX_PANE
sender_name: $MY_NAME
created_at: $(portable_date_iso)
cwd: $CWD
EOF

# Source tmux config for pane borders (non-destructive, idempotent)
CONF="${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/..}/scripts/dispatch-tmux.conf"
if [ -f "$CONF" ]; then
  tmux source-file "$CONF" 2>/dev/null || true
fi

# Create worker pane
PANE_ID=$(tmux split-window -h -c "$CWD" -P -F '#{pane_id}')
tmux select-layout tiled 2>/dev/null || true

# Label worker pane
set_pane_name "$PANE_ID" "worker:$LABEL"

# Update meta with pane ID
write_field "$TASK_DIR/meta.txt" "pane_id" "$PANE_ID"

# Launch Claude in the worker pane
tmux send-keys -t "$PANE_ID" -l -- "claude --worktree --model $MODEL --name worker-$LABEL"
sleep 0.1
tmux send-keys -t "$PANE_ID" Enter

# Wait for Claude to be ready (poll for prompt indicator, up to 15s)
for i in $(seq 1 30); do
  if tmux capture-pane -t "$PANE_ID" -p 2>/dev/null | grep -qE '❯|>'; then
    break
  fi
  sleep 0.5
done

# Send the task prompt
tmux send-keys -t "$PANE_ID" -l -- "$(cat "$PROMPT_FILE")"
sleep 0.1
tmux send-keys -t "$PANE_ID" Enter

echo "Dispatched task '$LABEL' to pane worker:$LABEL ($PANE_ID) using $MODEL"
