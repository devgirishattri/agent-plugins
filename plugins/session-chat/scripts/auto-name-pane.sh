#!/usr/bin/env bash
# auto-name-pane.sh — Auto-set tmux pane @name from Claude session name
# Called from SessionStart and UserPromptSubmit hooks
# Supported platforms: macOS, Linux

# Quick exit if not inside tmux
[ -z "${TMUX:-}" ] && exit 0

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Try multiple methods to extract transcript_path from hook input JSON
TRANSCRIPT=""

# Method 1: grep + cut (handles most JSON formats)
TRANSCRIPT=$(echo "$HOOK_INPUT" | grep -oE '"transcript_path":"[^"]*"' | head -1 | cut -d'"' -f4) || true

# Method 2: sed fallback
if [ -z "$TRANSCRIPT" ]; then
  TRANSCRIPT=$(echo "$HOOK_INPUT" | sed -n 's/.*"transcript_path":"\([^"]*\)".*/\1/p' | head -1) || true
fi

# Method 3: if no transcript_path in input, try to find it from the session
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  # Look for the most recently modified JSONL in the current project's dir
  CLAUDE_DIR="$HOME/.claude"
  CWD_ENCODED=$(printf '%s' "$(pwd)" | sed 's|/|-|g')
  PROJECT_DIR="$CLAUDE_DIR/projects/$CWD_ENCODED"
  if [ -d "$PROJECT_DIR" ]; then
    TRANSCRIPT=$(find "$PROJECT_DIR" -maxdepth 1 -name '*.jsonl' -type f 2>/dev/null | while read -r f; do
      mod=$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null || echo "0")
      echo "$mod $f"
    done | sort -rn | head -1 | cut -d' ' -f2-) || true
  fi
fi

# Give up if no transcript found
[ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0

# Extract last custom-title from transcript (session name)
SESSION_NAME=$(grep -a '"type":"custom-title"' "$TRANSCRIPT" 2>/dev/null | tail -1 | sed -n 's/.*"customTitle":"\([^"]*\)".*/\1/p') || true

[ -z "$SESSION_NAME" ] && exit 0

# Get current @name
CURRENT_NAME=$(tmux display-message -p -t "$TMUX_PANE" '#{@name}' 2>/dev/null) || true

# Only update if different
if [ "$CURRENT_NAME" != "$SESSION_NAME" ]; then
  tmux set-option -p -t "$TMUX_PANE" @name "$SESSION_NAME" 2>/dev/null || true
fi

exit 0
