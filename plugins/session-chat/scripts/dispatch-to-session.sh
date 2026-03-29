#!/usr/bin/env bash
# dispatch-to-session.sh — Send a tracked task to an existing named session
# Usage: dispatch-to-session.sh <target-name> <prompt-file>
# Supported platforms: macOS, Linux

source "$(dirname "$0")/lib.sh"

TARGET_NAME="${1:-}"
PROMPT_FILE="${2:-}"

if [ -z "$TARGET_NAME" ] || [ -z "$PROMPT_FILE" ]; then
  echo "ERROR: Usage: dispatch-to-session.sh <target-name> <prompt-file>"
  exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: Prompt file not found: $PROMPT_FILE"
  exit 1
fi

ensure_tmux

# Verify sender has a name
MY_NAME=$(get_my_name)
if [ -z "$MY_NAME" ]; then
  echo "ERROR: This pane has no name. Run /whoami <name> first."
  exit 1
fi

# Resolve target pane
TARGET_PANE=$(resolve_pane "$TARGET_NAME") || exit 1

# Create task state directory using target name as label
ensure_dispatch_dir
TASK_DIR=$(task_dir "$TARGET_NAME")
if [ -d "$TASK_DIR" ]; then
  # Clear previous completed/cancelled task for this target
  OLD_STATUS=$(cat "$TASK_DIR/status.txt" 2>/dev/null || echo "")
  if [ "$OLD_STATUS" = "completed" ] || [ "$OLD_STATUS" = "cancelled" ] || [ "$OLD_STATUS" = "failed" ]; then
    rm -rf "$TASK_DIR"
  else
    echo "ERROR: Task '$TARGET_NAME' is still running. Wait for it to complete or cancel it first."
    exit 1
  fi
fi
mkdir -p "$TASK_DIR"

# Write task files
cp "$PROMPT_FILE" "$TASK_DIR/prompt.txt"
echo "running" > "$TASK_DIR/status.txt"

cat > "$TASK_DIR/meta.txt" <<EOF
label: $TARGET_NAME
type: existing
pane_id: $TARGET_PANE
sender_pane: $TMUX_PANE
sender_name: $MY_NAME
created_at: $(portable_date_iso)
cwd: $(pwd)
EOF

# Send the task as a message (the auto-reply hook will process it)
PROMPT_TEXT=$(cat "$PROMPT_FILE")
send_message "$TARGET_NAME" "$PROMPT_TEXT"

echo "Dispatched task to existing session '$TARGET_NAME' ($TARGET_PANE)"
