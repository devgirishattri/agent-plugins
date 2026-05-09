#!/usr/bin/env bash
# lib.sh — Shared functions for session-chat plugin
# Source this file: source "$(dirname "$0")/lib.sh"
# Supported platforms: macOS, Linux

# --- tmux checks ---

ensure_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux is required for this session-chat action." >&2
    echo "Install it with: brew install tmux (macOS) or apt install tmux (Ubuntu)." >&2
    exit 1
  fi
  if [ -z "${TMUX:-}" ]; then
    echo "This session-chat action needs to run inside tmux." >&2
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

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
MESSAGES_DIR="$CODEX_DIR/messages"

ensure_messages_dir() {
  mkdir -p "$MESSAGES_DIR"
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
  get_pane_name "${TMUX_PANE:-}"
}

# --- Pane resolution (searches ALL tmux sessions) ---

resolve_pane() {
  local label="$1"
  local matches
  local count
  local panes
  matches=$(tmux list-panes -a -F '#{pane_id} #{@name}' 2>/dev/null | awk -v label="$label" '$2 == label { print $1 }')
  count=$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')

  if [ "$count" -eq 0 ]; then
    echo "ERROR: No pane named '$label'. Run /panes to see available." >&2
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    panes=$(printf '%s\n' "$matches" | sed '/^$/d' | awk 'BEGIN { out="" } { out = out (out ? ", " : "") $0 } END { print out }')
    echo "ERROR: Multiple panes named '$label' ($panes). Rename one with /whoami in that pane." >&2
    return 1
  fi

  printf '%s\n' "$matches" | sed '/^$/d' | head -1
}

# --- Communication ---

SEND_MAX_LEN="${SESSION_CHAT_SEND_MAX_LEN:-1024}"

generate_id() {
  if command -v od >/dev/null 2>&1; then
    od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
  else
    printf '%s%s' "$$" "${RANDOM:-0}${RANDOM:-0}"
  fi
}

send_text() {
  local pane_id="$1"
  local text="$2"
  local marker_supplied="${3+x}"
  local marker="${3:-$text}"
  local settle_ms="${SESSION_CHAT_SETTLE_MS:-300}"
  # Literal mode + split text/Enter for TUI safety (smux pattern)
  tmux send-keys -t "$pane_id" -l -- "$text" || return 1

  if [ "${SESSION_CHAT_SKIP_VERIFY:-}" != "1" ]; then
    local timeout_ms="${SESSION_CHAT_VERIFY_TIMEOUT_MS:-2000}"
    local captured
    local attempts
    local i

    case "$timeout_ms" in
      ''|*[!0-9]*) timeout_ms=2000 ;;
    esac

    if [ -z "$marker_supplied" ] && [ "${#marker}" -gt 40 ]; then
      marker="${marker: -40}"
    fi

    attempts=$(( (timeout_ms + 49) / 50 ))
    i=0
    while [ "$i" -lt "$attempts" ]; do
      captured=$(tmux capture-pane -t "$pane_id" -p -S -200 2>/dev/null || true)
      if [[ "$captured" == *"$marker"* ]]; then
        break
      fi
      sleep 0.05
      i=$((i + 1))
    done

    if [ "$i" -ge "$attempts" ]; then
      tmux send-keys -t "$pane_id" C-u >/dev/null 2>&1 || true
      echo "ERROR: send to $pane_id did not land within ${timeout_ms}ms — recipient may be busy." >&2
      return 1
    fi
  fi

  tmux send-keys -t "$pane_id" Enter || return 1

  case "$settle_ms" in
    ''|*[!0-9]*) settle_ms=300 ;;
  esac
  local settle_sec=$((settle_ms / 1000))
  local settle_rem=$((settle_ms % 1000))
  sleep "${settle_sec}.$(printf '%03d' "$settle_rem")"
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
  case "$SEND_MAX_LEN" in
    ''|*[!0-9]*) SEND_MAX_LEN=1024 ;;
  esac
  if [[ "$message" == *$'\n'* ]]; then
    echo "ERROR: /send only supports single-line messages. Use /dispatch <target> <task> for multi-line content." >&2
    return 1
  fi
  if [ "${#message}" -gt "$SEND_MAX_LEN" ]; then
    echo "ERROR: /send payload exceeds ${SEND_MAX_LEN} characters. Use /dispatch <target> <task> for long content." >&2
    return 1
  fi
  local target_pane
  target_pane=$(resolve_pane "$target_name") || return 1
  local uid
  uid=$(generate_id)
  local formatted="[from:${my_name} pane:${TMUX_PANE:-} id:${uid}] ${message}"
  send_text "$target_pane" "$formatted" "id:${uid}" || return 1
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
  local uid
  uid=$(generate_id)
  local msg_id
  msg_id="$(date +%s)-$$-${uid}-${my_name}-to-${target_name}"
  local msg_file="$MESSAGES_DIR/${msg_id}.md"
  printf '%s\n' "$message" > "$msg_file"

  # Send single-line notification with file reference
  local line_count
  line_count=$(printf '%s\n' "$message" | wc -l | tr -d ' ')
  send_text "$target_pane" "[from:${my_name} pane:${TMUX_PANE:-} msg:${msg_file} id:${uid}] dispatch (${line_count} lines) — read msg file for full task" "id:${uid}" || return 1
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
