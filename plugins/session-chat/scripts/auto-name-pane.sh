#!/usr/bin/env bash
# auto-name-pane.sh — Auto-set tmux pane @name from Claude session name
# Called from SessionStart and UserPromptSubmit hooks
# Supported platforms: macOS, Linux

# Quick exit if not inside tmux
[ -z "${TMUX:-}" ] && exit 0

# Source lib for set_pane_name
source "$(dirname "$0")/lib.sh"

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Extract transcript path from hook input
TRANSCRIPT=$(echo "$HOOK_INPUT" | sed -n 's/.*"transcript_path":"\([^"]*\)".*/\1/p' | head -1)

[ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0

# Extract last custom-title from transcript (session name)
SESSION_NAME=$(grep -a '"type":"custom-title"' "$TRANSCRIPT" 2>/dev/null | tail -1 | sed -n 's/.*"customTitle":"\([^"]*\)".*/\1/p') || true

[ -z "$SESSION_NAME" ] && exit 0

# Get current @name
CURRENT_NAME=$(tmux display-message -p -t "$TMUX_PANE" '#{@name}' 2>/dev/null)

# Only update if different (avoid unnecessary tmux calls)
if [ "$CURRENT_NAME" != "$SESSION_NAME" ]; then
  tmux set-option -p -t "$TMUX_PANE" @name "$SESSION_NAME" 2>/dev/null || true
fi

exit 0
