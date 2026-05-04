#!/usr/bin/env bash
# lib.sh — Shared functions for session-context plugin
# Source this file: source "$(dirname "$0")/lib.sh"
# Supported platforms: macOS, Linux

# --- tmux checks ---

ensure_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "ERROR: tmux is required to share context with another session." >&2
    echo "Install with: brew install tmux (macOS) or apt install tmux (Ubuntu)" >&2
    exit 1
  fi
  if [ -z "$TMUX" ]; then
    echo "ERROR: Sharing context with another session must run inside tmux." >&2
    echo "Start one with: tmux new -s <name>" >&2
    exit 1
  fi
}

# --- Input validation ---

validate_label() {
  local label="$1"
  if [ -z "$label" ]; then
    echo "ERROR: Label cannot be empty." >&2
    return 1
  fi
  if ! [[ "$label" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: Label must contain only alphanumeric characters, hyphens, and underscores." >&2
    return 1
  fi
}

# --- Message directory ---

MESSAGES_DIR="$HOME/.claude/messages"

ensure_messages_dir() {
  mkdir -p "$MESSAGES_DIR"
}

# --- Context snapshots directory (project-local) ---

get_contexts_dir() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  echo "$root/tmp/contexts"
}

# --- Pane naming (smux @name pattern) ---

set_pane_name() {
  local pane_id="$1"
  local name="$2"
  tmux set-option -p -t "$pane_id" @name "$name"
}

get_pane_name() {
  local pane_id="$1"
  tmux display-message -p -t "$pane_id" '#{@name}' 2>/dev/null
}

get_my_name() {
  get_pane_name "$TMUX_PANE"
}

# --- Pane resolution (searches ALL tmux sessions) ---

resolve_pane() {
  local label="$1"
  local result
  result=$(tmux list-panes -a -F '#{pane_id} #{@name}' 2>/dev/null | while read -r pid pname; do
    if [ "$pname" = "$label" ]; then
      echo "$pid"
      break
    fi
  done)
  if [ -z "$result" ]; then
    echo "ERROR: No pane named '$label'. Run /panes to see available." >&2
    return 1
  fi
  echo "$result"
}

# --- Communication ---

send_text() {
  local pane_id="$1"
  local text="$2"
  # Literal mode + split text/Enter for TUI safety (smux pattern)
  tmux send-keys -t "$pane_id" -l -- "$text"
  sleep 0.1
  tmux send-keys -t "$pane_id" Enter
}

send_message() {
  local target_name="$1"
  local message="$2"
  local my_name
  my_name=$(get_my_name)
  if [ -z "$my_name" ]; then
    echo "ERROR: This pane has no name. Run /whoami <name> first." >&2
    return 1
  fi
  local target_pane
  target_pane=$(resolve_pane "$target_name") || return 1
  local formatted="[from:${my_name} pane:${TMUX_PANE}] ${message}"
  send_text "$target_pane" "$formatted"
}

dispatch_message() {
  local target_name="$1"
  local message="$2"
  local my_name
  my_name=$(get_my_name)
  if [ -z "$my_name" ]; then
    echo "ERROR: This pane has no name. Run /whoami <name> first." >&2
    return 1
  fi
  local target_pane
  target_pane=$(resolve_pane "$target_name") || return 1

  # Write full message to file (handles multi-line + special chars)
  ensure_messages_dir
  local msg_id
  msg_id="$(date +%s)-${my_name}-to-${target_name}"
  local msg_file="$MESSAGES_DIR/${msg_id}.md"
  cat > "$msg_file" <<EOF
$message
EOF

  # Send single-line notification with file reference
  local preview
  preview=$(echo "$message" | head -1 | cut -c1-80)
  send_text "$target_pane" "[from:${my_name} pane:${TMUX_PANE} msg:${msg_file}] ${preview}"
}

read_pane() {
  local pane_id="$1"
  local lines="${2:-50}"
  tmux capture-pane -t "$pane_id" -p | tail -"$lines"
}

# --- Platform-compatible utilities ---

portable_date_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}
