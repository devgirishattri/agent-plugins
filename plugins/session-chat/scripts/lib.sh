#!/usr/bin/env bash
# lib.sh — Shared functions for session-chat plugin
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

# --- Message directory ---

MESSAGES_DIR="$HOME/.claude/messages"

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
  get_pane_name "$TMUX_PANE"
}

# --- Pane resolution (searches ALL tmux sessions) ---

resolve_pane() {
  local label="$1"
  local matches
  matches=$(tmux list-panes -a -F '#{pane_id} #{@name}' 2>/dev/null | awk -v want="$label" '$2 == want { print $1 }')
  local count
  count=$(printf '%s\n' "$matches" | grep -c .)
  if [ "$count" -eq 0 ]; then
    echo "ERROR: No pane named '$label'. Run /panes to see available." >&2
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    echo "ERROR: Multiple panes named '$label' ($matches). Rename one with /whoami in that pane." >&2
    return 1
  fi
  printf '%s\n' "$matches"
}

# --- Unique id for verify markers (guaranteed unique per call) ---

generate_id() {
  # 8 hex chars from /dev/urandom; no python/awk dependency
  if command -v od >/dev/null 2>&1; then
    od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
  else
    printf '%s%s' "$$" "${RANDOM:-0}${RANDOM:-0}"
  fi
}

# --- Communication ---

send_text() {
  local pane_id="$1"
  local text="$2"
  local marker="${3:-}"
  # Literal mode + split text/Enter for TUI safety (smux pattern)
  tmux send-keys -t "$pane_id" -l -- "$text"

  # Verify the literal text drained into the recipient pane before pressing Enter.
  # Without this, back-to-back sends to different panes can race: the second
  # send-keys can fire before the first paste has finished, dropping the first
  # message silently. Opt out via SESSION_CHAT_SKIP_VERIFY=1.
  if [ "${SESSION_CHAT_SKIP_VERIFY:-0}" != "1" ]; then
    local timeout_ms="${SESSION_CHAT_VERIFY_TIMEOUT_MS:-2000}"
    # Prefer caller-supplied unique marker (e.g. "id:abcd1234"). Fall back to
    # last 40 chars of payload only if no marker was given.
    if [ -z "$marker" ]; then
      marker="${text: -40}"
    fi
    local elapsed=0
    local landed=0
    while [ "$elapsed" -lt "$timeout_ms" ]; do
      # Capture a generous scrollback window: busy TUIs (spinners, list
      # output, approval prompts) push the input line past 20 lines fast.
      if tmux capture-pane -t "$pane_id" -p -S -200 2>/dev/null | grep -qF -- "$marker"; then
        landed=1
        break
      fi
      sleep 0.05
      elapsed=$((elapsed + 50))
    done
    if [ "$landed" -ne 1 ]; then
      # Clear partial paste from recipient's prompt buffer so it doesn't
      # poison the next interaction or concatenate with later sends.
      tmux send-keys -t "$pane_id" C-u 2>/dev/null || true
      echo "ERROR: send to ${pane_id} did not land within ${timeout_ms}ms; recipient input cleared (C-u). Recipient may be busy or in an approval gate." >&2
      return 1
    fi
  fi

  tmux send-keys -t "$pane_id" Enter

  # Settle window so the next send (often to a different pane) doesn't race
  # this pane's paste buffer drain. Override via SESSION_CHAT_SETTLE_MS.
  local settle_ms="${SESSION_CHAT_SETTLE_MS:-300}"
  if [ "$settle_ms" -gt 0 ] 2>/dev/null; then
    local settle_s
    settle_s=$(awk -v ms="$settle_ms" 'BEGIN { printf "%.3f", ms/1000 }')
    sleep "$settle_s"
  fi
}

SEND_MAX_LEN="${SESSION_CHAT_SEND_MAX_LEN:-1024}"

send_message() {
  local target_name="$1"
  local message="$2"
  local my_name
  my_name=$(get_my_name)
  if [ -z "$my_name" ]; then
    echo "ERROR: This pane has no name. Run /whoami <name> first." >&2
    return 1
  fi
  # Length / newline guard: tmux send-keys -l truncates large literal pastes
  # and the first \n submits a partial prompt. Refuse and steer to /dispatch.
  case "$message" in
    *$'\n'*)
      echo "ERROR: /send payload contains newlines. Use /dispatch <target> <task> for multi-line content." >&2
      return 1
      ;;
  esac
  if [ "${#message}" -gt "$SEND_MAX_LEN" ]; then
    echo "ERROR: /send payload is ${#message} chars (>${SEND_MAX_LEN}). Use /dispatch <target> <task> for long content." >&2
    return 1
  fi
  local target_pane
  target_pane=$(resolve_pane "$target_name") || return 1
  local uid
  uid=$(generate_id)
  local formatted="[from:${my_name} pane:${TMUX_PANE} id:${uid}] ${message}"
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
  # PID + uid prevents same-second / same-target collisions overwriting files.
  local msg_id
  msg_id="$(date +%s)-$$-${uid}-${my_name}-to-${target_name}"
  local msg_file="$MESSAGES_DIR/${msg_id}.md"
  cat > "$msg_file" <<EOF
$message
EOF
  local line_count
  line_count=$(printf '%s' "$message" | awk 'END { print NR + 1 }')
  # Notification line: no truncated preview. Recipient hook + receiver agent
  # are responsible for reading $msg_file. The 'id:' field is the verify marker.
  send_text "$target_pane" \
    "[from:${my_name} pane:${TMUX_PANE} msg:${msg_file} id:${uid}] dispatch (${line_count} lines) — read msg file for full task" \
    "id:${uid}" || return 1
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

