#!/usr/bin/env bash
# auto-name-pane.sh — Auto-set tmux pane @name from Codex session metadata
# Called from SessionStart hook ONLY (not UserPromptSubmit, to avoid overwriting /whoami)
# Supported platforms: macOS, Linux

# Quick exit if not inside tmux
[ -z "${TMUX:-}" ] && exit 0

# Quick exit if pane already has a name (don't overwrite manual /whoami)
CURRENT_NAME=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@name}' 2>/dev/null) || true
[ -n "$CURRENT_NAME" ] && exit 0

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Try to get transcript_path from hook input
TRANSCRIPT=$(echo "$HOOK_INPUT" | grep -oE '"transcript_path":"[^"]*"' | head -1 | cut -d'"' -f4) || true

# Fallback: find most recent JSONL in the current project's session dir
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  SESSIONS_DIR="${CODEX_HOME:-$HOME/.codex}/sessions"
  if [ -d "$SESSIONS_DIR" ]; then
    TRANSCRIPT=$(find "$SESSIONS_DIR" -type f -name '*.jsonl' 2>/dev/null | xargs ls -t 2>/dev/null | head -1) || true
  fi
fi

# Give up if no transcript found
[ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0

# Extract the first user message as a best-effort session name.
SESSION_NAME=$(grep -a '"type":"user_message"' "$TRANSCRIPT" 2>/dev/null | head -1 | sed -n 's/.*"message":"\([^"]*\)".*/\1/p' | cut -c1-48) || true

# Set @name only if we found a session name (pane has no name at this point)
if [ -n "$SESSION_NAME" ]; then
  tmux set-option -p -t "${TMUX_PANE:-}" @name "$SESSION_NAME" 2>/dev/null || true
fi

exit 0
