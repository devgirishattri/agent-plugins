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
    echo "ERROR: No pane named '$label'. Run /panes all to see all available named panes." >&2
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

normalize_positive_int() {
  local value="$1"
  local fallback="$2"
  case "$value" in
    ''|*[!0-9]*) printf '%s\n' "$fallback" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

sleep_ms() {
  local ms
  ms=$(normalize_positive_int "${1:-0}" 0)
  local sec=$((ms / 1000))
  local rem=$((ms % 1000))
  sleep "${sec}.$(printf '%03d' "$rem")"
}

generate_id() {
  if command -v od >/dev/null 2>&1; then
    od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
  else
    printf '%s%s' "$$" "${RANDOM:-0}${RANDOM:-0}"
  fi
}

send_lock_path() {
  local pane_id="$1"
  local safe_id
  safe_id=$(printf '%s' "$pane_id" | tr -c 'a-zA-Z0-9_.-' '_')
  printf '%s/session-chat-locks/%s.lock\n' "${TMPDIR:-/tmp}" "${safe_id:-pane}"
}

process_is_alive() {
  local pid="$1"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
}

# Worst-case duration of one send_text call: (retries+1) verify windows plus a
# little headroom. Lock waits derive from this so fan-in (many panes acking one
# orchestrator) queues instead of failing.
per_send_budget_ms() {
  local retries verify_ms
  retries=$(normalize_positive_int "${SESSION_CHAT_SEND_RETRIES:-2}" 2)
  verify_ms=$(normalize_positive_int "${SESSION_CHAT_VERIFY_TIMEOUT_MS:-4000}" 4000)
  printf '%s\n' "$(( (retries + 1) * verify_ms + 1500 ))"
}

acquire_send_lock() {
  local lock_dir="$1"
  local pane_id="$2"
  local default_ms timeout_ms
  default_ms=$(( $(per_send_budget_ms) * 4 ))
  timeout_ms=$(normalize_positive_int "${SESSION_CHAT_LOCK_TIMEOUT_MS:-$default_ms}" "$default_ms")
  local elapsed=0
  local last_owner=""
  local pid

  mkdir -p "$(dirname "$lock_dir")"
  while [ "$elapsed" -lt "$timeout_ms" ]; do
    if mkdir "$lock_dir" 2>/dev/null; then
      printf '%s\n' "$$" > "$lock_dir/pid"
      return 0
    fi

    pid=""
    [ -f "$lock_dir/pid" ] && pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && ! process_is_alive "$pid"; then
      rm -f "$lock_dir/pid"
      rmdir "$lock_dir" 2>/dev/null || true
      continue
    fi

    # Holder changed => the queue is moving; reset patience so legitimate
    # fan-in of many senders to one pane never trips the timeout.
    if [ -n "$pid" ] && [ "$pid" != "$last_owner" ]; then
      last_owner="$pid"
      elapsed=0
    fi

    sleep 0.05
    elapsed=$((elapsed + 50))
  done

  echo "ERROR: timed out waiting for send lock for $pane_id after ${timeout_ms}ms." >&2
  return 1
}

release_send_lock() {
  local lock_dir="$1"
  rm -f "$lock_dir/pid" 2>/dev/null || true
  rmdir "$lock_dir" 2>/dev/null || true
}

# --- Durable per-recipient inbox (delivery fallback) ---
# Every message is enqueued BEFORE the live paste. A successful paste delivers it
# live and the entry is removed; a failed paste (busy recipient) leaves it so the
# recipient's UserPromptSubmit hook recovers it on its next turn.
# Records are single-line TAB-separated:  <id>\t<type>\t<from>\t<payload>
#   type=send     -> payload = the (single-line) message text
#   type=dispatch -> payload = the trusted msg file path
# Dedup across the live paste and the inbox is by <id>.

queue_file_for() {
  local name="$1"
  local safe
  safe=$(printf '%s' "$name" | tr -c 'a-zA-Z0-9._-' '_')
  printf '%s/queue/%s.tsv\n' "$MESSAGES_DIR" "$safe"
}

enqueue_message() {
  local recipient="$1" id="$2" type="$3" from="$4" payload="$5"
  ensure_messages_dir
  local qf lock
  qf=$(queue_file_for "$recipient")
  mkdir -p "$(dirname "$qf")" 2>/dev/null || true
  lock=$(send_lock_path "queue:${recipient}")
  acquire_send_lock "$lock" "queue:${recipient}" || return 1
  printf '%s\t%s\t%s\t%s\n' "$id" "$type" "$from" "$payload" >> "$qf"
  release_send_lock "$lock"
}

dequeue_message_id() {
  local recipient="$1" id="$2"
  local qf lock tmp
  qf=$(queue_file_for "$recipient")
  [ -f "$qf" ] || return 0
  lock=$(send_lock_path "queue:${recipient}")
  acquire_send_lock "$lock" "queue:${recipient}" || return 1
  tmp="${qf}.tmp.$$"
  awk -F'\t' -v id="$id" '$1 != id' "$qf" > "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$qf" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  release_send_lock "$lock"
}

# drain_inbox <skip_ids> <recipient_name>: print queued records whose id is not
# in the space-separated <skip_ids>, then remove every surfaced/skipped id.
drain_inbox() {
  local skip_ids="$1"
  local recipient="$2"
  [ -n "$recipient" ] || return 0
  local qf lock
  qf=$(queue_file_for "$recipient")
  [ -f "$qf" ] || return 0
  lock=$(send_lock_path "queue:${recipient}")
  acquire_send_lock "$lock" "queue:${recipient}" || return 0
  local surfaced="" qid qtype qfrom qpayload rest
  while IFS=$'\t' read -r qid qtype qfrom qpayload; do
    [ -z "$qid" ] && continue
    case " $skip_ids $surfaced " in *" $qid "*) continue ;; esac
    printf '%s\t%s\t%s\t%s\n' "$qid" "$qtype" "$qfrom" "$qpayload"
    surfaced="$surfaced $qid"
  done < "$qf"
  local tmp="${qf}.tmp.$$"
  : > "$tmp"
  while IFS=$'\t' read -r qid rest; do
    [ -z "$qid" ] && continue
    case " $skip_ids $surfaced " in *" $qid "*) continue ;; esac
    printf '%s\t%s\n' "$qid" "$rest" >> "$tmp"
  done < "$qf"
  mv -f "$tmp" "$qf" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  release_send_lock "$lock"
}

send_text_once() {
  local pane_id="$1"
  local text="$2"
  local marker_supplied="${3+x}"
  local marker="${3:-$text}"
  local settle_ms="${SESSION_CHAT_SETTLE_MS:-300}"
  # Literal mode + split text/Enter for TUI safety (smux pattern)
  tmux send-keys -t "$pane_id" -l -- "$text" || return 1

  if [ "${SESSION_CHAT_SKIP_VERIFY:-}" != "1" ]; then
    local timeout_ms="${SESSION_CHAT_VERIFY_TIMEOUT_MS:-4000}"
    local captured
    local attempts
    local i

    case "$timeout_ms" in
      ''|*[!0-9]*) timeout_ms=4000 ;;
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
      return 2
    fi
  fi

  tmux send-keys -t "$pane_id" Enter || return 1

  case "$settle_ms" in
    ''|*[!0-9]*) settle_ms=300 ;;
  esac
  sleep_ms "$settle_ms"
}

send_text() {
  local pane_id="$1"
  local text="$2"
  local marker_supplied="${3+x}"
  local marker="${3:-$text}"
  local retries
  local backoff_ms
  local max_attempts
  local attempt=1
  local status=0
  local lock_dir

  retries=$(normalize_positive_int "${SESSION_CHAT_SEND_RETRIES:-2}" 2)
  backoff_ms=$(normalize_positive_int "${SESSION_CHAT_RETRY_BACKOFF_MS:-200}" 200)
  max_attempts=$((retries + 1))
  lock_dir=$(send_lock_path "$pane_id")

  while [ "$attempt" -le "$max_attempts" ]; do
    acquire_send_lock "$lock_dir" "$pane_id" || return 1
    if [ -n "$marker_supplied" ]; then
      send_text_once "$pane_id" "$text" "$marker"
    else
      send_text_once "$pane_id" "$text"
    fi
    status=$?
    release_send_lock "$lock_dir"

    if [ "$status" -eq 0 ]; then
      return 0
    fi
    if [ "$status" -ne 2 ]; then
      return "$status"
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      local timeout_ms
      timeout_ms=$(normalize_positive_int "${SESSION_CHAT_VERIFY_TIMEOUT_MS:-4000}" 4000)
      echo "ERROR: send to $pane_id did not land within ${timeout_ms}ms after ${max_attempts} attempts — recipient may be busy." >&2
      return 1
    fi

    sleep_ms $((backoff_ms * attempt))
    attempt=$((attempt + 1))
  done

  return 1
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
  # Durable copy first so a busy/failed paste is never a lost message.
  enqueue_message "$target_name" "$uid" "send" "$my_name" "$message" || return 1
  local formatted="[from:${my_name} pane:${TMUX_PANE:-} id:${uid}] ${message}"
  if send_text "$target_pane" "$formatted" "id:${uid}"; then
    dequeue_message_id "$target_name" "$uid"
    return 0
  fi
  return 3
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
  # Durable copy first (points at the task file), then the live nudge.
  enqueue_message "$target_name" "$uid" "dispatch" "$my_name" "$msg_file" || return 1
  if send_text "$target_pane" "[from:${my_name} pane:${TMUX_PANE:-} msg:${msg_file} id:${uid}] dispatch (${line_count} lines) — read msg file for full task" "id:${uid}"; then
    dequeue_message_id "$target_name" "$uid"
    return 0
  fi
  return 3
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
