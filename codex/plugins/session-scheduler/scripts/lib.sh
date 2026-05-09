#!/usr/bin/env bash
# lib.sh — Shared functions for session-scheduler plugin
# Source this file: source "$(dirname "$0")/lib.sh"
# Supported platforms: macOS, Linux

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCHEDULER_DIR="${SESSION_SCHEDULER_HOME:-$PROJECT_ROOT/tmp/scheduler}"
TASKS_DIR="$SCHEDULER_DIR/tasks"
PROMPTS_DIR="$SCHEDULER_DIR/prompts"
SESSION_CHAT_MIN_VERSION="0.11.0"

ensure_dirs() {
  mkdir -p "$TASKS_DIR" "$PROMPTS_DIR"
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required for session-scheduler." >&2
    return 1
  fi
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

now_epoch() {
  date +%s
}

generate_id() {
  local rand
  if command -v od >/dev/null 2>&1; then
    rand=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  else
    rand="${RANDOM:-0}${RANDOM:-0}"
  fi
  printf 'task-%s-%s\n' "$(now_epoch)" "$rand"
}

validate_task_id() {
  local id="$1"
  if [ -z "$id" ] || ! [[ "$id" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo "ERROR: Invalid task id: $id" >&2
    return 1
  fi
}

task_file() {
  local id="$1"
  validate_task_id "$id" || return 1
  printf '%s/%s.json\n' "$TASKS_DIR" "$id"
}

prompt_file() {
  local id="$1"
  validate_task_id "$id" || return 1
  printf '%s/%s.md\n' "$PROMPTS_DIR" "$id"
}

current_pane_name() {
  if command -v tmux >/dev/null 2>&1 && [ -n "${TMUX_PANE:-}" ]; then
    tmux display-message -p -t "$TMUX_PANE" '#{@name}' 2>/dev/null || true
  fi
}

session_chat_root() {
  if [ -n "${SESSION_CHAT_ROOT_OVERRIDE:-}" ] && [ -d "$SESSION_CHAT_ROOT_OVERRIDE" ]; then
    printf '%s\n' "$SESSION_CHAT_ROOT_OVERRIDE"
    return 0
  fi
  if [ -n "${SESSION_CHAT_PLUGIN_ROOT:-}" ] && [ -d "$SESSION_CHAT_PLUGIN_ROOT" ]; then
    printf '%s\n' "$SESSION_CHAT_PLUGIN_ROOT"
    return 0
  fi
  local cached="$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/$SESSION_CHAT_MIN_VERSION"
  if [ -d "$cached" ]; then
    printf '%s\n' "$cached"
    return 0
  fi
  local sibling="$PLUGIN_ROOT/../session-chat"
  if [ -d "$sibling" ]; then
    printf '%s\n' "$sibling"
    return 0
  fi
  echo "ERROR: session-chat >= $SESSION_CHAT_MIN_VERSION is required but was not found." >&2
  return 1
}

session_chat_version() {
  local root="$1"
  jq -r '.version // "unknown"' "$root/.codex-plugin/plugin.json" 2>/dev/null || echo "unknown"
}

write_json_atomic() {
  local file="$1"
  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
  cat > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$file"
}

append_history_update() {
  local file="$1"
  local status="$2"
  local event="$3"
  local actor="$4"
  local note="$5"
  local now
  now=$(now_iso)
  jq \
    --arg status "$status" \
    --arg now "$now" \
    --arg event "$event" \
    --arg actor "$actor" \
    --arg note "$note" \
    '.status=$status
     | .updated_at=$now
     | .history += [{ts:$now,event:$event,actor:$actor,note:$note}]' \
    "$file" | write_json_atomic "$file"
}

file_mtime() {
  local file="$1"
  stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null
}
