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

MESSAGES_DIR="${CLAUDE_HOME:-$HOME/.claude}/messages"

ensure_messages_dir() {
  local messages_dir="${1:-$MESSAGES_DIR}"
  mkdir -p "$messages_dir"
}

# Resolve the trusted messages dir for the *recipient* pane's runtime so a
# cross-runtime dispatch/fallback lands where that pane actually drains. A
# Claude pane drains ~/.claude/messages; a Codex pane drains ~/.codex/messages,
# and each runtime only trusts dispatch files inside its own messages dir.
# Detection uses the pane's foreground command: Codex panes report a *codex*
# binary, Claude panes report node. SESSION_CHAT_TARGET_MESSAGES_DIR overrides.
target_messages_dir_for_pane() {
  local pane_id="$1"
  if [ -n "${SESSION_CHAT_TARGET_MESSAGES_DIR:-}" ]; then
    printf '%s\n' "$SESSION_CHAT_TARGET_MESSAGES_DIR"
    return 0
  fi
  local command=""
  command=$(tmux display-message -p -t "$pane_id" '#{pane_current_command}' 2>/dev/null || true)
  # Codex panes report a *codex* binary (e.g. codex-aarch64-a); Claude panes
  # report the CLI version (e.g. 2.1.156) or claude/node. Codex detection is the
  # reliable signal — when in doubt we keep messages in our own (Claude) dir.
  case "$command" in
    codex|codex-*|*codex*)
      printf '%s/messages\n' "${CODEX_HOME:-$HOME/.codex}"
      ;;
    claude|claude-*|*claude*|node|*node*|[0-9]*.[0-9]*.[0-9]*)
      printf '%s\n' "$MESSAGES_DIR"
      ;;
    *)
      printf '%s\n' "$MESSAGES_DIR"
      ;;
  esac
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
    echo "ERROR: No pane named '$label'. Run /panes all to see all available named panes." >&2
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    echo "ERROR: Multiple panes named '$label' ($matches). Rename one with /whoami in that pane." >&2
    return 1
  fi
  printf '%s\n' "$matches"
}

# --- Small numeric helpers ---

normalize_positive_int() {
  local value="$1"
  local fallback="$2"
  case "$value" in
    ''|*[!0-9]*) printf '%s\n' "$fallback" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

is_nonnegative_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

now_ms() {
  local seconds
  seconds=$(date +%s 2>/dev/null || printf '0')
  case "$seconds" in
    ''|*[!0-9]*) seconds=0 ;;
  esac
  printf '%s000\n' "$seconds"
}

# --- Unique id for verify markers (guaranteed unique per call) ---

generate_id() {
  # 8 hex chars from /dev/urandom; no python/awk dependency
  if command -v od >/dev/null 2>&1; then
    od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
  else
    printf '%08x%04x%04x\n' "$$" "${RANDOM:-0}" "${RANDOM:-0}"
  fi
}

# --- Send budget ---
# Worst-case duration of one send_text call: (retries+1) verify windows plus a
# little backoff/settle headroom. Lock waits derive from this so that fan-in
# (many panes acking one orchestrator) queues instead of failing.
per_send_budget_ms() {
  local retries verify_ms
  retries=$(normalize_positive_int "${SESSION_CHAT_SEND_RETRIES:-2}" 2)
  verify_ms=$(normalize_positive_int "${SESSION_CHAT_VERIFY_TIMEOUT_MS:-4000}" 4000)
  printf '%s' "$(( (retries + 1) * verify_ms + 1500 ))"
}

# --- Per-target send lock ---
# Serializes sends targeting the same pane so concurrent senders don't
# interleave keystrokes. Lock dir is created with mkdir (atomic). Stale locks
# (owner PID gone) are reclaimed. The wait budget scales with the per-send
# budget AND resets whenever the lock holder changes — so a burst of executors
# acking the same orchestrator queues up instead of erroring out. When the user
# sets SESSION_CHAT_LOCK_TIMEOUT_MS explicitly, it is treated as a hard cap
# (no holder-change reset), so the total wait can never exceed it.

session_chat_lock_path() {
  local safe
  safe=$(printf '%s' "$1" | tr -c 'a-zA-Z0-9._-' '_')
  printf '%s/session-chat-locks/%s.lock' "${TMPDIR:-/tmp}" "$safe"
}

acquire_lock() {
  local pane="$1"
  local lock
  lock="${2:-}"
  [ -n "$lock" ] || lock=$(session_chat_lock_path "$pane")
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  local default_ms
  default_ms=$(( $(per_send_budget_ms) * 4 ))
  local timeout_ms
  timeout_ms=$(normalize_positive_int "${SESSION_CHAT_LOCK_TIMEOUT_MS:-$default_ms}" "$default_ms")
  local explicit_timeout=0
  [ "${SESSION_CHAT_LOCK_TIMEOUT_MS+x}" = "x" ] && explicit_timeout=1
  local elapsed=0
  local last_owner=""
  while [ "$elapsed" -lt "$timeout_ms" ]; do
    if mkdir "$lock" 2>/dev/null; then
      printf '%s\n' "$$" > "$lock/pid"
      return 0
    fi
    local owner_pid=""
    [ -f "$lock/pid" ] && owner_pid=$(tr -d '[:space:]' < "$lock/pid" 2>/dev/null)
    if [ -n "$owner_pid" ] && ! kill -0 "$owner_pid" 2>/dev/null; then
      rm -rf "$lock" 2>/dev/null
      continue
    fi
    # Holder changed => the queue is moving; reset patience so legitimate
    # fan-in of many senders to one pane never trips the auto-sized timeout.
    # An explicitly-set SESSION_CHAT_LOCK_TIMEOUT_MS is an absolute ceiling.
    if [ "$explicit_timeout" = "0" ] && [ -n "$owner_pid" ] && [ "$owner_pid" != "$last_owner" ]; then
      last_owner="$owner_pid"
      elapsed=0
    fi
    sleep 0.05
    elapsed=$((elapsed + 50))
  done
  echo "ERROR: could not acquire send-lock for ${pane} within ${timeout_ms}ms (held by another sender)." >&2
  return 1
}

release_lock() {
  local pane="$1"
  local lock
  lock="${2:-}"
  [ -n "$lock" ] || lock=$(session_chat_lock_path "$pane")
  rm -rf "$lock" 2>/dev/null
}

# --- Durable per-recipient inbox (delivery fallback) ---
# Every message is enqueued BEFORE the live paste. A successful paste delivers
# it live and the entry is removed; a failed paste (busy recipient) leaves the
# entry so the recipient's UserPromptSubmit hook recovers it on its next turn.
# Records are single-line TAB-separated:  <id>\t<type>\t<from>\t<ready_at>\t<payload>
#   type=send     -> payload = the (single-line) message text
#   type=dispatch -> payload = the trusted msg file path
# Each new record carries a ready-at timestamp so an in-flight live send gets a
# grace window to win before the recipient hook surfaces the durable fallback.
# A per-recipient "recent ids" ledger (TTL'd) dedups across turns so a queued
# entry and its later live paste never both surface.

queue_file_for() {
  local name="$1"
  local messages_dir="${2:-$MESSAGES_DIR}"
  local safe
  safe=$(printf '%s' "$name" | tr -c 'a-zA-Z0-9._-' '_')
  printf '%s/queue/%s.tsv' "$messages_dir" "$safe"
}

recent_file_for() {
  local name="$1"
  local messages_dir="${2:-$MESSAGES_DIR}"
  local safe
  safe=$(printf '%s' "$name" | tr -c 'a-zA-Z0-9._-' '_')
  printf '%s/queue/.recent-%s.tsv' "$messages_dir" "$safe"
}

queue_lock_path() {
  local recipient="$1"
  local messages_dir="${2:-$MESSAGES_DIR}"
  local safe
  safe=$(printf '%s' "$recipient" | tr -c 'a-zA-Z0-9._-' '_')
  printf '%s/queue/.locks/%s.lock' "$messages_dir" "${safe:-pane}"
}

queue_recovery_delay_ms() {
  local send_budget default_lock_budget default_delay
  send_budget=$(per_send_budget_ms)
  default_lock_budget=$(normalize_positive_int "${SESSION_CHAT_LOCK_TIMEOUT_MS:-$((send_budget * 4))}" "$((send_budget * 4))")
  default_delay=$((default_lock_budget + send_budget + 1000))
  normalize_positive_int "${SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS:-$default_delay}" "$default_delay"
}

recent_id_ttl_ms() {
  normalize_positive_int "${SESSION_CHAT_RECENT_ID_TTL_MS:-600000}" 600000
}

queue_ready_at_ms() {
  printf '%s\n' "$(( $(now_ms) + $(queue_recovery_delay_ms) ))"
}

# Re-emit a queue record, tolerating legacy 4-field rows (no ready_at column)
# by treating them as ready-now (ready_at=0).
normalize_queue_record() {
  local qid="$1" qtype="$2" qfrom="$3" qready="$4" qpayload="$5"
  if is_nonnegative_int "$qready"; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$qid" "$qtype" "$qfrom" "$qready" "$qpayload"
  else
    [ -n "$qpayload" ] && qready="${qready}	${qpayload}"
    printf '%s\t%s\t%s\t0\t%s\n' "$qid" "$qtype" "$qfrom" "$qready"
  fi
}

prune_recent_ids_unlocked() {
  local recipient="$1" now="$2"
  local rf tmp
  rf=$(recent_file_for "$recipient")
  [ -f "$rf" ] || return 0
  tmp="${rf}.tmp.$$"
  awk -F'\t' -v now="$now" '$1 != "" && $2 ~ /^[0-9]+$/ && $2 > now' "$rf" > "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$rf" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

recent_ids_unlocked() {
  local recipient="$1"
  local rf
  rf=$(recent_file_for "$recipient")
  [ -f "$rf" ] || return 0
  awk -F'\t' '$1 != "" { print $1 }' "$rf" 2>/dev/null || true
}

mark_recent_id_unlocked() {
  local recipient="$1" id="$2" now="$3"
  [ -n "$recipient" ] && [ -n "$id" ] || return 0
  local rf expires
  rf=$(recent_file_for "$recipient")
  mkdir -p "$(dirname "$rf")" 2>/dev/null || true
  expires=$((now + $(recent_id_ttl_ms)))
  awk -F'\t' -v id="$id" '$1 != id' "$rf" > "${rf}.tmp.$$" 2>/dev/null || true
  mv -f "${rf}.tmp.$$" "$rf" 2>/dev/null || rm -f "${rf}.tmp.$$" 2>/dev/null
  printf '%s\t%s\n' "$id" "$expires" >> "$rf"
}

# Returns 0 if this id was already surfaced recently (TTL window), else 1.
recent_id_seen() {
  local recipient="$1" id="$2"
  [ -n "$recipient" ] && [ -n "$id" ] || return 1
  ensure_messages_dir
  local now found=1
  local lock
  lock=$(queue_lock_path "$recipient")
  acquire_lock "queue:${recipient}" "$lock" || return 1
  now=$(now_ms)
  prune_recent_ids_unlocked "$recipient" "$now"
  if recent_ids_unlocked "$recipient" | grep -Fx "$id" >/dev/null 2>&1; then
    found=0
  fi
  release_lock "queue:${recipient}" "$lock"
  return "$found"
}

mark_recent_id() {
  local recipient="$1" id="$2"
  [ -n "$recipient" ] && [ -n "$id" ] || return 0
  ensure_messages_dir
  local now
  local lock
  lock=$(queue_lock_path "$recipient")
  acquire_lock "queue:${recipient}" "$lock" || return 1
  now=$(now_ms)
  prune_recent_ids_unlocked "$recipient" "$now"
  mark_recent_id_unlocked "$recipient" "$id" "$now"
  release_lock "queue:${recipient}" "$lock"
}

enqueue_message() {
  # enqueue_message <recipient_name> <id> <type> <from> <payload> [messages_dir]
  local recipient="$1" id="$2" type="$3" from="$4" payload="$5"
  local messages_dir="${6:-$MESSAGES_DIR}"
  ensure_messages_dir "$messages_dir"
  local qf ready_at lock
  qf=$(queue_file_for "$recipient" "$messages_dir")
  mkdir -p "$(dirname "$qf")" 2>/dev/null || true
  ready_at=$(queue_ready_at_ms)
  lock=$(queue_lock_path "$recipient" "$messages_dir")
  acquire_lock "queue:${recipient}" "$lock" || return 1
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$type" "$from" "$ready_at" "$payload" >> "$qf"
  release_lock "queue:${recipient}" "$lock"
}

dequeue_message_id() {
  # dequeue_message_id <recipient_name> <id> [messages_dir] — remove this id
  local recipient="$1" id="$2"
  local messages_dir="${3:-$MESSAGES_DIR}"
  local qf lock
  qf=$(queue_file_for "$recipient" "$messages_dir")
  [ -f "$qf" ] || return 0
  lock=$(queue_lock_path "$recipient" "$messages_dir")
  acquire_lock "queue:${recipient}" "$lock" || return 1
  local tmp="${qf}.tmp.$$"
  awk -F'\t' -v id="$id" '$1 != id' "$qf" > "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$qf" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  release_lock "queue:${recipient}" "$lock"
}

# mark_message_ready <recipient> <id> — set a row's ready_at to now so the
# recipient hook surfaces it immediately (used when the live paste is known to
# have failed; no point waiting out the grace window).
mark_message_ready() {
  local recipient="$1" id="$2"
  local messages_dir="${3:-$MESSAGES_DIR}"
  local qf tmp now qid qtype qfrom qready qpayload lock
  qf=$(queue_file_for "$recipient" "$messages_dir")
  [ -f "$qf" ] || return 0
  lock=$(queue_lock_path "$recipient" "$messages_dir")
  acquire_lock "queue:${recipient}" "$lock" || return 1
  tmp="${qf}.tmp.$$"
  now=$(now_ms)
  : > "$tmp"
  while IFS=$'\t' read -r qid qtype qfrom qready qpayload; do
    [ -z "$qid" ] && continue
    if [ "$qid" = "$id" ]; then
      if ! is_nonnegative_int "$qready"; then
        [ -n "$qpayload" ] && qready="${qready}	${qpayload}"
        qpayload="$qready"
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$qid" "$qtype" "$qfrom" "$now" "$qpayload" >> "$tmp"
    else
      normalize_queue_record "$qid" "$qtype" "$qfrom" "$qready" "$qpayload" >> "$tmp"
    fi
  done < "$qf"
  mv -f "$tmp" "$qf" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  release_lock "queue:${recipient}" "$lock"
}

# drain_inbox <skip_ids> <recipient_name>
# Prints queued records (one per line: <id>\t<type>\t<from>\t<payload>) that are
# ready (ready_at <= now), not in <skip_ids>, and not already surfaced (recent
# ledger). Surfaced + skipped ids are marked recent and removed from the queue.
# Not-yet-ready rows are left in place for a future turn.
drain_inbox() {
  local skip_ids="$1"
  local recipient="$2"
  [ -n "$recipient" ] || return 0
  local qf lock
  qf=$(queue_file_for "$recipient")
  [ -f "$qf" ] || return 0
  lock=$(queue_lock_path "$recipient")
  acquire_lock "queue:${recipient}" "$lock" || return 0
  local now recent_ids
  now=$(now_ms)
  prune_recent_ids_unlocked "$recipient" "$now"
  recent_ids=$(recent_ids_unlocked "$recipient" | tr '\n' ' ')
  local remove_ids="" qid qtype qfrom qready qpayload rest
  while IFS=$'\t' read -r qid qtype qfrom qready qpayload; do
    [ -z "$qid" ] && continue
    if ! is_nonnegative_int "$qready"; then
      [ -n "$qpayload" ] && qready="${qready}	${qpayload}"
      qpayload="$qready"
      qready=0
    fi
    # Caller already showed this id live this turn: mark recent, drop, no surface.
    case " $skip_ids $remove_ids " in
      *" $qid "*)
        mark_recent_id_unlocked "$recipient" "$qid" "$now"
        remove_ids="$remove_ids $qid"
        continue
        ;;
    esac
    # Already surfaced on a prior turn (live or recovery): drop, no re-surface.
    case " $recent_ids " in
      *" $qid "*)
        remove_ids="$remove_ids $qid"
        continue
        ;;
    esac
    # Still within its grace window: leave it for a later turn.
    if [ "$qready" -gt "$now" ]; then
      continue
    fi
    printf '%s\t%s\t%s\t%s\n' "$qid" "$qtype" "$qfrom" "$qpayload"
    mark_recent_id_unlocked "$recipient" "$qid" "$now"
    remove_ids="$remove_ids $qid"
  done < "$qf"
  # Rewrite the queue, keeping only rows we neither surfaced, skipped, nor
  # deferred. Deferred (not-ready) rows are re-emitted normalized.
  local tmp="${qf}.tmp.$$"
  : > "$tmp"
  while IFS=$'\t' read -r qid qtype qfrom qready qpayload; do
    [ -z "$qid" ] && continue
    case " $skip_ids $remove_ids " in *" $qid "*) continue ;; esac
    normalize_queue_record "$qid" "$qtype" "$qfrom" "$qready" "$qpayload" >> "$tmp"
  done < "$qf"
  mv -f "$tmp" "$qf" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  release_lock "queue:${recipient}" "$lock"
}

# --- Communication ---

# Single paste→verify→Enter attempt. On verify failure: C-u to clear the
# partial paste, return 1 (no error message — caller decides whether to retry).
_send_text_attempt() {
  local pane_id="$1"
  local text="$2"
  local marker="$3"
  tmux send-keys -t "$pane_id" -l -- "$text"
  if [ "${SESSION_CHAT_SKIP_VERIFY:-0}" != "1" ]; then
    local timeout_ms="${SESSION_CHAT_VERIFY_TIMEOUT_MS:-4000}"
    if [ -z "$marker" ]; then
      marker="${text: -40}"
    fi
    local elapsed=0
    local landed=0
    while [ "$elapsed" -lt "$timeout_ms" ]; do
      if tmux capture-pane -t "$pane_id" -p -S -200 2>/dev/null | grep -qF -- "$marker"; then
        landed=1
        break
      fi
      sleep 0.05
      elapsed=$((elapsed + 50))
    done
    if [ "$landed" -ne 1 ]; then
      tmux send-keys -t "$pane_id" C-u 2>/dev/null || true
      return 1
    fi
  fi
  tmux send-keys -t "$pane_id" Enter
  local settle_ms="${SESSION_CHAT_SETTLE_MS:-300}"
  if [ "$settle_ms" -gt 0 ] 2>/dev/null; then
    local settle_s
    settle_s=$(awk -v ms="$settle_ms" 'BEGIN { printf "%.3f", ms/1000 }')
    sleep "$settle_s"
  fi
  return 0
}

send_text() {
  local pane_id="$1"
  local text="$2"
  local marker="${3:-}"

  acquire_lock "$pane_id" || return 1

  local retries="${SESSION_CHAT_SEND_RETRIES:-2}"
  local backoff_ms="${SESSION_CHAT_RETRY_BACKOFF_MS:-200}"
  local attempt=0
  while :; do
    if _send_text_attempt "$pane_id" "$text" "$marker"; then
      release_lock "$pane_id"
      return 0
    fi
    if [ "$attempt" -ge "$retries" ]; then
      release_lock "$pane_id"
      local timeout_ms="${SESSION_CHAT_VERIFY_TIMEOUT_MS:-4000}"
      echo "ERROR: send to ${pane_id} did not land within ${timeout_ms}ms after $((retries + 1)) attempts; recipient input cleared (C-u). Recipient may be busy or in an approval gate." >&2
      return 1
    fi
    attempt=$((attempt + 1))
    local wait_ms=$((backoff_ms * attempt))
    local wait_s
    wait_s=$(awk -v ms="$wait_ms" 'BEGIN { printf "%.3f", ms/1000 }')
    sleep "$wait_s"
  done
}

SEND_MAX_LEN="${SESSION_CHAT_SEND_MAX_LEN:-1024}"

# Return codes for send_message / dispatch_message:
#   0 = delivered live (durable copy cleared)
#   3 = recipient busy; message left in their durable inbox, arrives next turn
#   1 = hard failure (no name, unknown/ambiguous target, enqueue failed)

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
  # Durable rows land in the recipient runtime's dir so a Codex target drains
  # them on its next turn (Codex hooks read ~/.codex/messages, not ~/.claude).
  local target_messages_dir
  target_messages_dir=$(target_messages_dir_for_pane "$target_pane")
  local uid
  uid=$(generate_id)
  # Durable copy first so a busy/failed paste is never a lost message.
  enqueue_message "$target_name" "$uid" "send" "$my_name" "$message" "$target_messages_dir" || return 1
  local formatted="[from:${my_name} pane:${TMUX_PANE} id:${uid}] ${message}"
  if send_text "$target_pane" "$formatted" "id:${uid}"; then
    dequeue_message_id "$target_name" "$uid" "$target_messages_dir"
    return 0
  fi
  # Live paste failed; surface from the inbox on the recipient's next turn now.
  mark_message_ready "$target_name" "$uid" "$target_messages_dir" || true
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
  # Resolve the recipient runtime's trusted dir: the task file must live where
  # that pane's hook will trust + read it (each runtime trusts only its own).
  local target_messages_dir
  target_messages_dir=$(target_messages_dir_for_pane "$target_pane")

  # Write full message to file (handles multi-line + special chars)
  ensure_messages_dir "$target_messages_dir"
  local uid
  uid=$(generate_id)
  # PID + uid prevents same-second / same-target collisions overwriting files.
  local msg_id
  msg_id="$(date +%s)-$$-${uid}-${my_name}-to-${target_name}"
  local msg_file="$target_messages_dir/${msg_id}.md"
  cat > "$msg_file" <<EOF
$message
EOF
  local line_count
  line_count=$(printf '%s' "$message" | awk 'END { print NR + 1 }')
  # Durable copy first (points at the task file), then the live nudge.
  enqueue_message "$target_name" "$uid" "dispatch" "$my_name" "$msg_file" "$target_messages_dir" || return 1
  # Notification line: no truncated preview. Recipient hook + receiver agent
  # are responsible for reading $msg_file. The 'id:' field is the verify marker.
  if send_text "$target_pane" \
    "[from:${my_name} pane:${TMUX_PANE} msg:${msg_file} id:${uid}] dispatch (${line_count} lines) — read msg file for full task" \
    "id:${uid}"; then
    dequeue_message_id "$target_name" "$uid" "$target_messages_dir"
    return 0
  fi
  mark_message_ready "$target_name" "$uid" "$target_messages_dir" || true
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
