#!/usr/bin/env bash
# auto-name-pane.sh — Auto-set tmux pane @name from Codex session metadata
# Called from SessionStart only (not UserPromptSubmit, to preserve a manual name).
# Supported platforms: macOS, Linux

# Quick exit if not inside tmux
[ -z "${TMUX:-}" ] && exit 0

# Quick exit if pane already has a name.
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
    transcripts=()
    while IFS= read -r -d '' transcript; do
      transcripts+=("$transcript")
    done < <(find "$SESSIONS_DIR" -type f -name '*.jsonl' -print0 2>/dev/null)
    if [ "${#transcripts[@]}" -gt 0 ]; then
      TRANSCRIPT=$(ls -t "${transcripts[@]}" 2>/dev/null | head -1) || true
    fi
  fi
fi

# Give up if no transcript found
[ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ] && exit 0

# Extract the first user message as a best-effort session name.
SESSION_NAME=$(grep -a '"type":"user_message"' "$TRANSCRIPT" 2>/dev/null | head -1 | sed -n 's/.*"message":"\([^"]*\)".*/\1/p' | cut -c1-48) || true

# Sanitize: prompts are free-form prose, but pane labels must stay in
# [a-zA-Z0-9_-] or resolve_pane can never reach this pane again (the failure
# mode is a silently dead outbound channel).
SESSION_NAME=$(printf '%s' "$SESSION_NAME" \
  | tr -s '[:space:]' '-' \
  | tr -cd 'a-zA-Z0-9_-' \
  | sed 's/--*/-/g; s/^-*//; s/-*$//' \
  | cut -c1-48)

# Set @name only if we found a session name (pane has no name at this point)
if [ -n "$SESSION_NAME" ]; then
  tmux set-option -p -t "${TMUX_PANE:-}" @name "$SESSION_NAME" 2>/dev/null || true
fi

exit 0
