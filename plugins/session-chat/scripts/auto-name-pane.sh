#!/usr/bin/env bash
# auto-name-pane.sh — Auto-set tmux pane @name from Claude session name
# Called from SessionStart hook ONLY (not UserPromptSubmit, to avoid overwriting /whoami)
# Supported platforms: macOS, Linux

# Quick exit if not inside tmux
[ -z "${TMUX:-}" ] && exit 0

# Quick exit if pane already has a name (don't overwrite manual /whoami)
CURRENT_NAME=$(tmux display-message -p -t "$TMUX_PANE" '#{@name}' 2>/dev/null) || true
[ -n "$CURRENT_NAME" ] && exit 0

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Try to get transcript_path from hook input
TRANSCRIPT=$(echo "$HOOK_INPUT" | grep -oE '"transcript_path":"[^"]*"' | head -1 | cut -d'"' -f4) || true

# Fallback: find most recent JSONL in the current project's session dir
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  PROJECT_DIR="$HOME/.claude/projects/$(printf '%s' "$(pwd)" | sed 's|/|-|g')"
  if [ -d "$PROJECT_DIR" ]; then
    TRANSCRIPT=$(ls -t "$PROJECT_DIR"/*.jsonl 2>/dev/null | head -1) || true
  fi
fi

# Give up if no transcript found
[ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0

# Extract last custom-title from transcript
SESSION_NAME=$(grep -a '"customTitle":"[^"]*"' "$TRANSCRIPT" 2>/dev/null | tail -1 | grep -oE '"customTitle":"[^"]*"' | cut -d'"' -f4) || true

# Sanitize: session titles are free-form prose, but pane labels must stay in
# [a-zA-Z0-9_-] or resolve_pane can never reach this pane again (the failure
# mode is a silently dead outbound channel).
SESSION_NAME=$(printf '%s' "$SESSION_NAME" \
  | tr -s '[:space:]' '-' \
  | tr -cd 'a-zA-Z0-9_-' \
  | sed 's/--*/-/g; s/^-*//; s/-*$//' \
  | cut -c1-48)

# Set @name only if we found a session name (pane has no name at this point)
if [ -n "$SESSION_NAME" ]; then
  tmux set-option -p -t "$TMUX_PANE" @name "$SESSION_NAME" 2>/dev/null || true
fi

exit 0
