#!/usr/bin/env bash
# lib.sh — Shared functions for task-dispatcher plugin
# Source this file: source "$(dirname "$0")/lib.sh"
# Supported platforms: macOS, Linux

# --- tmux checks ---

ensure_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "ERROR: tmux is not installed." >&2
    echo "Install with: brew install tmux (macOS) or apt install tmux (Ubuntu)" >&2
    exit 1
  fi
  if [ -z "$TMUX" ]; then
    echo "ERROR: Not inside a tmux session." >&2
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

validate_model() {
  local model="$1"
  if ! [[ "$model" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "ERROR: Invalid model name." >&2
    return 1
  fi
}

# --- Dispatch directory ---

ensure_dispatch_dir() {
  mkdir -p ".claude/dispatch/tasks"
}

task_dir() {
  local label="$1"
  echo ".claude/dispatch/tasks/$label"
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

read_pane() {
  local pane_id="$1"
  local lines="${2:-50}"
  tmux capture-pane -t "$pane_id" -p | tail -"$lines"
}

# --- Platform-compatible utilities ---

portable_date_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

# --- Field read/write for plain-text state files ---

read_field() {
  local file="$1"
  local field="$2"
  grep "^${field}:" "$file" 2>/dev/null | sed "s/^${field}: *//"
}

write_field() {
  local file="$1"
  local field="$2"
  local value="$3"
  if grep -q "^${field}:" "$file" 2>/dev/null; then
    local tmp="${file}.tmp.$$"
    sed "s|^${field}:.*|${field}: ${value}|" "$file" > "$tmp"
    mv "$tmp" "$file"
  else
    echo "${field}: ${value}" >> "$file"
  fi
}
