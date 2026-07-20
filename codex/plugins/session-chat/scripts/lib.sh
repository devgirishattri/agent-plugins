#!/usr/bin/env bash
# lib.sh — Shared functions for session-chat plugin
# Source this file: source "$(dirname "$0")/lib.sh"
# Supported platforms: macOS, Linux

# Queue rows, dispatch bodies, archives, and reply ledgers can contain private
# task content. Every file created by session-chat must be owner-only.
umask 077

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

validate_reply_id() {
  local reply_id="$1"
  if ! [[ "$reply_id" =~ ^[a-f0-9]{8,16}$ ]]; then
    echo "ERROR: Reply id must be 8-16 lowercase hexadecimal characters." >&2
    return 1
  fi
}

correlate_reply() {
  # correlate_reply <reply-id> <message> — transport-owned correlation. Keep an
  # already-present exact token, otherwise prepend it once. Callers must never
  # ask an agent to compose this protocol marker by hand.
  local reply_id="$1" message="$2" token conflicting cleaned
  validate_reply_id "$reply_id" || return 1
  token="[re:${reply_id}]"
  conflicting=$(printf '%s' "$message" \
    | grep -oE '\[re:[a-f0-9]{8,16}\]' 2>/dev/null \
    | grep -Fvx "$token" | head -1 || true)
  if [ -n "$conflicting" ]; then
    echo "ERROR: Reply contains conflicting correlation token $conflicting; use --reply-to $reply_id only." >&2
    return 1
  fi
  cleaned=$(printf '%s' "$message" | sed "s/\\[re:${reply_id}\\][[:space:]]*//g")
  if [ -n "$cleaned" ]; then
    printf '%s %s' "$token" "$cleaned"
  else
    printf '%s' "$token"
  fi
}

# Coerce free-form text (session titles, prompts) into a valid pane label:
# whitespace runs become single hyphens, every other invalid char is dropped,
# repeated/edge hyphens collapse, length capped at 48. Empty output means the
# input had nothing usable — caller should skip naming rather than set "".
sanitize_label() {
  printf '%s' "$1" \
    | tr -s '[:space:]' '-' \
    | tr -cd 'a-zA-Z0-9_-' \
    | sed 's/--*/-/g; s/^-*//; s/-*$//' \
    | cut -c1-48
}

# --- Message directory ---

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
MESSAGES_DIR="${SESSION_CHAT_TARGET_MESSAGES_DIR:-$CODEX_DIR/messages}"

_require_private_message_dir() {
  local path="$1"
  if [ -L "$path" ]; then
    echo "ERROR: Refusing symbolic-link message directory: $path" >&2
    return 1
  fi
  if [ ! -e "$path" ]; then
    mkdir -p "$path" 2>/dev/null || return 1
  fi
  if [ ! -d "$path" ] || [ ! -O "$path" ]; then
    echo "ERROR: Refusing unsafe message directory: $path" >&2
    return 1
  fi
  chmod 700 "$path" 2>/dev/null || return 1
}

_require_private_message_file_or_absent() {
  local path="$1"
  _require_private_message_dir "$(dirname "$path")" || return 1
  if [ -L "$path" ]; then
    echo "ERROR: Refusing symbolic-link message file: $path" >&2
    return 1
  fi
  if [ -e "$path" ]; then
    if [ ! -f "$path" ] || [ ! -O "$path" ]; then
      echo "ERROR: Refusing unsafe message file: $path" >&2
      return 1
    fi
    local links
    links=$(stat -c '%h' "$path" 2>/dev/null || stat -f '%l' "$path" 2>/dev/null) || return 1
    if [ "$links" != "1" ]; then
      echo "ERROR: Refusing multiply-linked message file: $path" >&2
      return 1
    fi
    chmod 600 "$path" 2>/dev/null || return 1
  fi
}

_message_temp_file() {
  local target="$1"
  _require_private_message_dir "$(dirname "$target")" || return 1
  mktemp "${target}.tmp.XXXXXX" 2>/dev/null || {
    echo "ERROR: Could not create private message temp file beside: $target" >&2
    return 1
  }
}

_write_private_message_file() {
  local path="$1" text="$2"
  _require_private_message_file_or_absent "$path" || return 1
  if ! (set -o noclobber; umask 077; printf '%s\n' "$text" > "$path") 2>/dev/null; then
    echo "ERROR: Refusing to overwrite existing dispatch file: $path" >&2
    return 1
  fi
  _require_private_message_file_or_absent "$path" || { rm -f "$path" 2>/dev/null; return 1; }
}

harden_messages_dir() {
  local messages_dir="${1:-$MESSAGES_DIR}"
  if [ -L "$messages_dir" ] || [ ! -d "$messages_dir" ] || [ ! -O "$messages_dir" ]; then
    echo "ERROR: Refusing unsafe messages directory: $messages_dir" >&2
    return 1
  fi
  chmod 700 "$messages_dir" 2>/dev/null || return 1
  local marker="$messages_dir/.perms-hardened-v1"
  _require_private_message_file_or_absent "$marker" || return 1
  if [ ! -e "$marker" ]; then
    if find "$messages_dir" -type l -print -quit 2>/dev/null | grep . >/dev/null 2>&1; then
      echo "ERROR: Refusing symbolic link below messages directory: $messages_dir" >&2
      return 1
    fi
    find "$messages_dir" -type d -exec chmod 700 {} + 2>/dev/null || return 1
    find "$messages_dir" -type f -exec chmod 600 {} + 2>/dev/null || return 1
    : > "$marker" || return 1
    chmod 600 "$marker" 2>/dev/null || return 1
  fi
  local dir file
  for dir in "$messages_dir/queue" "$messages_dir/archive"; do
    [ ! -e "$dir" ] && [ ! -L "$dir" ] || _require_private_message_dir "$dir" || return 1
  done
  if [ -e "$messages_dir/queue" ]; then
    dir="$messages_dir/queue/.locks"
    [ ! -e "$dir" ] && [ ! -L "$dir" ] || _require_private_message_dir "$dir" || return 1
  fi
  for file in "$messages_dir/sent-log.tsv" "$messages_dir/replies-log.tsv"; do
    _require_private_message_file_or_absent "$file" || return 1
  done
}

ensure_messages_dir() {
  local messages_dir="${1:-$MESSAGES_DIR}"
  if [ ! -e "$messages_dir" ]; then
    mkdir -p "$messages_dir" || return 1
  fi
  harden_messages_dir "$messages_dir"
}

# --- Pane naming (smux @name pattern) ---

set_pane_name() {
  local pane_id="$1"
  local name="$2"
  # Invalid names (spaces etc.) would be unreachable via resolve_pane forever.
  validate_label "$name" || return 1
  tmux set-option -p -t "$pane_id" @name "$name"
}

# Build private runtime state under a physical, UID-scoped temp root. The
# root is intentionally predictable so every sender for this Unix account
# shares the same pane locks, but it is only trusted when it is a real 0700
# directory owned by this process's effective user. Canonicalizing TMPDIR
# before appending the root name avoids returning a path through a symlinked
# alias (notably /var -> /private/var on macOS).
_private_tmp_root() {
  local tmp_parent uid root canonical mode
  tmp_parent=$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P) || {
    echo "ERROR: Refusing unusable session-chat temp parent: ${TMPDIR:-/tmp}" >&2
    return 1
  }
  uid="${EUID:-}"
  case "$uid" in
    ''|*[!0-9]*) uid=$(id -u 2>/dev/null) || return 1 ;;
  esac
  case "$uid" in
    ''|*[!0-9]*)
      echo "ERROR: Could not determine the current UID for session-chat temp state." >&2
      return 1
      ;;
  esac

  root="$tmp_parent/session-chat-$uid"
  if [ ! -e "$root" ]; then
    # Another sender may win this mkdir between the existence check and this
    # call. Accept that race only when the winner left a path for the strict
    # validation immediately below.
    if ! mkdir -m 700 "$root" 2>/dev/null && [ ! -e "$root" ]; then
      echo "ERROR: Could not create private session-chat temp root: $root" >&2
      return 1
    fi
  fi
  if [ ! -d "$root" ] || [ -L "$root" ] || [ ! -O "$root" ]; then
    echo "ERROR: Refusing unsafe session-chat temp root: $root" >&2
    return 1
  fi
  mode=$(stat -c '%a' "$root" 2>/dev/null || stat -f '%Lp' "$root" 2>/dev/null) || {
    echo "ERROR: Could not inspect session-chat temp root permissions: $root" >&2
    return 1
  }
  if [ "$mode" != "700" ]; then
    echo "ERROR: Refusing non-private session-chat temp root (mode $mode): $root" >&2
    return 1
  fi
  canonical=$(cd "$root" 2>/dev/null && pwd -P) || return 1
  if [ "$canonical" != "$root" ]; then
    echo "ERROR: Refusing non-canonical session-chat temp root: $root" >&2
    return 1
  fi
  printf '%s\n' "$root"
}

_private_tmp_subdir() {
  local name="$1" root dir mode canonical
  validate_label "$name" >/dev/null 2>&1 || return 1
  root=$(_private_tmp_root) || return 1
  dir="$root/$name"
  if [ ! -e "$dir" ]; then
    if ! mkdir -m 700 "$dir" 2>/dev/null && [ ! -e "$dir" ]; then
      echo "ERROR: Could not create private session-chat temp directory: $dir" >&2
      return 1
    fi
  fi
  if [ ! -d "$dir" ] || [ -L "$dir" ] || [ ! -O "$dir" ]; then
    echo "ERROR: Refusing unsafe session-chat temp directory: $dir" >&2
    return 1
  fi
  mode=$(stat -c '%a' "$dir" 2>/dev/null || stat -f '%Lp' "$dir" 2>/dev/null) || return 1
  if [ "$mode" != "700" ]; then
    echo "ERROR: Refusing non-private session-chat temp directory (mode $mode): $dir" >&2
    return 1
  fi
  canonical=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  if [ "$canonical" != "$dir" ]; then
    echo "ERROR: Refusing non-canonical session-chat temp directory: $dir" >&2
    return 1
  fi
  printf '%s\n' "$dir"
}

# get_pane_name normally swallows tmux's stderr so callers get a clean
# empty-string result, but a silent "no name" is indistinguishable from tmux
# failing to reach the pane at all (wrong/stale socket, dead server). Its
# stderr is captured to a per-process file instead of a plain variable
# because callers invoke it as `x=$(get_my_name)` — a command-substitution
# subshell — so a variable assigned inside get_pane_name never makes it back
# to the caller's shell. `$$` (unlike `$BASHPID`) stays fixed across that
# subshell, so the file path below is predictable from either side. That
# predictability is only safe inside a private (0700), ownership-checked
# directory — a bare predictable path directly under the world-writable
# $TMPDIR would let another local user pre-plant a symlink there and have
# our `2>` redirect follow it into an arbitrary file of theirs.
_pane_name_scratch_dir() {
  _private_tmp_subdir scratch
}

# Per-tag stderr capture file inside the private scratch dir — one file per
# (tag, process) so unrelated tmux calls in the same process (e.g. the
# self-name query in get_my_name vs. the pane search in resolve_pane) don't
# clobber each other's captured stderr.
_tmux_err_file() {
  local tag="${1:-tmux}"
  local dir
  dir="$(_pane_name_scratch_dir)"
  [ -n "$dir" ] || return 1
  printf '%s/%s.%s' "$dir" "$tag" "$$"
}

# Read + clear the tmux stderr captured under <tag> by this process (see
# _tmux_err_file). Call once, right after the `x=$(...)` that ran the tmux
# command, to both retrieve and clean up.
_pop_tmux_err() {
  local tag="$1" err_file
  err_file="$(_tmux_err_file "$tag")"
  [ -f "$err_file" ] || return 0
  cat "$err_file" 2>/dev/null
  rm -f "$err_file" 2>/dev/null
}

get_pane_name() {
  local pane_id="$1" err_file
  if err_file="$(_tmux_err_file get-pane-name)"; then
    tmux display-message -p -t "$pane_id" '#{@name}' 2>"$err_file"
  else
    tmux display-message -p -t "$pane_id" '#{@name}' 2>/dev/null
  fi
}

get_my_name() {
  # SESSION_CHAT_PANE_NAME lets a caller assert its own identity directly,
  # bypassing the tmux self-query. Escape hatch for environments (e.g. some
  # sandboxed exec contexts) where `tmux display-message -t $TMUX_PANE` on
  # one's own pane can fail even though the pane genuinely has a name.
  if [ -n "${SESSION_CHAT_PANE_NAME:-}" ]; then
    printf '%s' "$SESSION_CHAT_PANE_NAME"
    return 0
  fi
  get_pane_name "${TMUX_PANE:-}"
}

pop_pane_name_err() {
  _pop_tmux_err get-pane-name
}

# Format the "(tmux: ...)" suffix for a tmux-command error. Permission errors
# are the signature of a sandboxed exec denying the tmux socket outright. This
# is not fixable inside the current process: the caller must rerun the whole
# command escalated/approved, not merely retry one tmux call.
tmux_err_detail() {
  local tmux_err="$1"
  local allow_name_override="${2:-}"
  [ -n "$tmux_err" ] || return 0
  local hint=""
  case "$tmux_err" in
    *"Operation not permitted"*|*"Permission denied"*)
      hint=" — looks like a sandboxed exec denied the tmux socket; re-run this command escalated/approved"
      if [ "$allow_name_override" = "allow-name-override" ]; then
        hint="$hint, or set SESSION_CHAT_PANE_NAME to skip self-name resolution"
      fi
      ;;
  esac
  printf ' (tmux: %s)%s' "$tmux_err" "$hint"
}

pane_name_err_detail() {
  tmux_err_detail "$1" allow-name-override
}

report_current_pane_name_failure() {
  local tmux_err="$1"
  if [ -n "$tmux_err" ]; then
    echo "ERROR: Cannot read the current tmux pane name$(pane_name_err_detail "$tmux_err")" >&2
  else
    echo "ERROR: This pane has no name. Run \$session-chat:whoami <name> first." >&2
  fi
}

# Run a tmux command whose stdout is data consumed by a user-facing script.
# On failure, preserve stderr, print one actionable error, and return non-zero.
# Legitimate empty stdout remains a successful empty result.
tmux_capture_checked() {
  local tag="$1"
  local action="$2"
  shift 2

  local err_file output rc tmux_err
  if err_file="$(_tmux_err_file "$tag")"; then
    output=$(tmux "$@" 2>"$err_file")
    rc=$?
    tmux_err=$(_pop_tmux_err "$tag")
  else
    output=$(tmux "$@" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      tmux_err="$output"
      output=""
    else
      tmux_err=""
    fi
  fi

  if [ "$rc" -ne 0 ]; then
    echo "ERROR: ${action}$(tmux_err_detail "$tmux_err")" >&2
    return "$rc"
  fi
  printf '%s' "$output"
}

# --- Pane resolution (searches ALL tmux sessions) ---

resolve_pane() {
  local label="$1"
  validate_label "$label" || return 1
  local matches
  local count
  local panes
  local err_file tmux_err
  # Tab delimiter: a legacy/manually-set name containing whitespace must not
  # shift awk fields and silently become unreachable.
  if err_file="$(_tmux_err_file resolve-pane)"; then
    matches=$(tmux list-panes -a -F $'#{pane_id}\t#{@name}' 2>"$err_file" | awk -F'\t' -v label="$label" '$2 == label { print $1 }')
  else
    matches=$(tmux list-panes -a -F $'#{pane_id}\t#{@name}' 2>/dev/null | awk -F'\t' -v label="$label" '$2 == label { print $1 }')
  fi
  tmux_err=$(_pop_tmux_err resolve-pane)
  count=$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')

  if [ "$count" -eq 0 ]; then
    # An empty result here is ambiguous by itself: either no pane is named
    # $label, or `tmux list-panes` itself failed (e.g. a sandboxed exec
    # denying the socket) and silently returned nothing. Surface the real
    # cause when we have one instead of always implying the target is
    # unregistered — confirmed live 2026-07-09 in fresh Codex sessions: this
    # was the actual, and only, failure point in 4/4 attempts.
    if [ -n "$tmux_err" ]; then
      echo "ERROR: Cannot resolve tmux pane '$label'$(tmux_err_detail "$tmux_err")" >&2
    else
      echo "ERROR: No pane named '$label'. Run \$session-chat:panes all to see all available named panes." >&2
    fi
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    panes=$(printf '%s\n' "$matches" | sed '/^$/d' | awk 'BEGIN { out="" } { out = out (out ? ", " : "") $0 } END { print out }')
    echo "ERROR: Multiple panes named '$label' ($panes). Rename one with \$session-chat:whoami in that pane." >&2
    return 1
  fi

  printf '%s\n' "$matches" | sed '/^$/d' | head -1
}

target_messages_dir_for_pane() {
  local pane_id="$1"
  if [ -n "${SESSION_CHAT_TARGET_MESSAGES_DIR:-}" ]; then
    printf '%s\n' "$SESSION_CHAT_TARGET_MESSAGES_DIR"
    return 0
  fi

  local command
  command=$(tmux display-message -p -t "$pane_id" '#{pane_current_command}' 2>/dev/null || true)
  case "$command" in
    codex|codex-*|*codex*)
      printf '%s\n' "$MESSAGES_DIR"
      ;;
    claude|claude-*|*claude*|node|*node*|[0-9]*.[0-9]*.[0-9]*)
      printf '%s/messages\n' "${CLAUDE_HOME:-$HOME/.claude}"
      ;;
    *)
      printf '%s\n' "$MESSAGES_DIR"
      ;;
  esac
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

clear_partial_input() {
  local pane_id="$1"
  # Claude/Codex TUIs can leave wrapped tail text behind if we only kill from
  # the prompt start. Move to the logical end first, then kill backward.
  tmux send-keys -t "$pane_id" C-e C-u >/dev/null 2>&1 || true
  tmux send-keys -t "$pane_id" C-a C-k >/dev/null 2>&1 || true
  tmux send-keys -t "$pane_id" C-e C-u >/dev/null 2>&1 || true
}

count_paste_placeholders() {
  awk '{
    while (match($0, /\[Pasted text #[0-9]+\]/)) {
      count++
      $0 = substr($0, RSTART + RLENGTH)
    }
  } END { print count + 0 }'
}

capture_paste_placeholder_count() {
  local pane_id="$1"
  tmux capture-pane -t "$pane_id" -p -S -200 2>/dev/null | count_paste_placeholders
}

generate_id() {
  if command -v od >/dev/null 2>&1; then
    od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
  else
    printf '%08x%04x%04x\n' "$$" "${RANDOM:-0}" "${RANDOM:-0}"
  fi
}

send_lock_path() {
  local pane_id="$1"
  local safe_id lock_root
  safe_id=$(printf '%s' "$pane_id" | tr -c 'a-zA-Z0-9_.-' '_')
  lock_root=$(_private_tmp_subdir send-locks) || return 1
  printf '%s/%s.lock\n' "$lock_root" "${safe_id:-pane}"
}

queue_lock_path() {
  local recipient="$1"
  local messages_dir="${2:-$MESSAGES_DIR}"
  local safe
  safe=$(printf '%s' "$recipient" | tr -c 'a-zA-Z0-9._-' '_')
  printf '%s/queue/.locks/%s.lock\n' "$messages_dir" "${safe:-pane}"
}

process_is_alive() {
  local pid="$1"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null
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
  local default_ms timeout_ms explicit_timeout=0
  default_ms=$(( $(per_send_budget_ms) * 4 ))
  timeout_ms=$(normalize_positive_int "${SESSION_CHAT_LOCK_TIMEOUT_MS:-$default_ms}" "$default_ms")
  if [ "${SESSION_CHAT_LOCK_TIMEOUT_MS+x}" = "x" ]; then
    explicit_timeout=1
  fi
  local elapsed=0
  local last_owner=""
  local pid

  local lock_parent
  lock_parent=$(dirname "$lock_dir")
  _require_private_message_dir "$lock_parent" || return 1
  if [ -L "$lock_dir" ] || { [ -e "$lock_dir" ] && { [ ! -d "$lock_dir" ] || [ ! -O "$lock_dir" ]; }; }; then
    echo "ERROR: Refusing unsafe send lock: $lock_dir" >&2
    return 1
  fi
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
    # fan-in of many senders to one pane never trips the auto-sized timeout.
    # When the user sets SESSION_CHAT_LOCK_TIMEOUT_MS, treat it as a hard cap.
    if [ "$explicit_timeout" = "0" ] && [ -n "$pid" ] && [ "$pid" != "$last_owner" ]; then
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
# Every message is enqueued BEFORE the live paste. A successful paste delivers
# it live and the entry is removed; a failed paste (busy recipient) leaves the
# entry so the recipient's UserPromptSubmit/Stop hooks recover it later.
# Records are single-line TAB-separated. Canonical layout:
#   <id>\t<type>\t<from>\t<ready_at>\tp<prio>:x<expires_ms>\t<payload>
#   type=send     -> payload = the (single-line) message text
#   type=dispatch -> payload = the trusted msg file path
#   prio          -> 0 normal, 1 high; high rows surface first during recovery
#   expires_ms    -> 0 never; expired rows are dropped without surfacing
# Legacy rows (no meta column, or no ready_at column) parse as normal-priority,
# never-expiring, ready-now.
# Each new record carries a ready-at timestamp so an in-flight live send gets a
# grace window to win before the recipient hook surfaces the durable fallback.
# A per-recipient "recent ids" ledger (TTL'd) dedups across turns so a queued
# entry and its later live paste never both surface.

queue_file_for() {
  local name="$1"
  local messages_dir="${2:-$MESSAGES_DIR}"
  local safe
  safe=$(printf '%s' "$name" | tr -c 'a-zA-Z0-9._-' '_')
  printf '%s/queue/%s.tsv\n' "$messages_dir" "$safe"
}

recent_file_for() {
  local name="$1"
  local messages_dir="${2:-$MESSAGES_DIR}"
  local safe
  safe=$(printf '%s' "$name" | tr -c 'a-zA-Z0-9._-' '_')
  printf '%s/queue/.recent-%s.tsv\n' "$messages_dir" "$safe"
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

# parse_queue_record <line> — fills QR_ID QR_TYPE QR_FROM QR_READY QR_PRIO
# QR_EXPIRES QR_PAYLOAD from any record vintage. Returns 1 on blank lines.
# Canonical layout: <id>\t<type>\t<from>\t<ready_at>\tp<prio>:x<expires>\t<payload>
# The meta column is identified by its strict p<0|1>:x<digits> shape, so a
# legacy payload sitting in that position cannot be mistaken for it.
parse_queue_record() {
  local line="$1"
  QR_ID=""; QR_TYPE=""; QR_FROM=""; QR_READY=0; QR_PRIO=0; QR_EXPIRES=0; QR_PAYLOAD=""
  [ -n "$line" ] || return 1
  local f5="" rest=""
  IFS=$'\t' read -r QR_ID QR_TYPE QR_FROM QR_READY f5 rest <<<"$line"
  [ -n "$QR_ID" ] || return 1
  if ! is_nonnegative_int "$QR_READY"; then
    # Legacy 4-field row: no ready_at column; everything after <from> is payload.
    QR_PAYLOAD="$QR_READY"
    [ -n "$f5" ] && QR_PAYLOAD="${QR_PAYLOAD}	${f5}"
    [ -n "$rest" ] && QR_PAYLOAD="${QR_PAYLOAD}	${rest}"
    QR_READY=0
    return 0
  fi
  # Numeric column 4 with nothing after it: enqueue never writes an empty
  # payload, so this can only be a legacy 4-field row whose payload happens
  # to be all digits — treat the number as payload, not ready_at.
  if [ -z "$f5" ] && [ -z "$rest" ]; then
    QR_PAYLOAD="$QR_READY"
    QR_READY=0
    return 0
  fi
  if [[ "$f5" =~ ^p[01]:x[0-9]+$ ]]; then
    QR_PRIO="${f5#p}"; QR_PRIO="${QR_PRIO%%:*}"
    QR_EXPIRES="${f5#*x}"
    QR_PAYLOAD="$rest"
  else
    # Legacy 5-field row: payload starts at column 5.
    QR_PAYLOAD="$f5"
    [ -n "$rest" ] && QR_PAYLOAD="${QR_PAYLOAD}	${rest}"
  fi
  return 0
}

emit_queue_record() {
  # emit_queue_record <id> <type> <from> <ready> <prio> <expires> <payload>
  printf '%s\t%s\t%s\t%s\tp%s:x%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

queue_priority_value() {
  case "${SESSION_CHAT_PRIORITY:-normal}" in
    high|1) printf '1' ;;
    *) printf '0' ;;
  esac
}

queue_expires_at_ms() {
  local ttl
  ttl=$(normalize_positive_int "${SESSION_CHAT_TTL_MS:-0}" 0)
  if [ "$ttl" -gt 0 ]; then
    printf '%s' "$(( $(now_ms) + ttl ))"
  else
    printf '0'
  fi
}

prune_recent_ids_unlocked() {
  local recipient="$1" now="$2"
  local messages_dir="${3:-$MESSAGES_DIR}"
  local rf tmp
  rf=$(recent_file_for "$recipient" "$messages_dir")
  _require_private_message_file_or_absent "$rf" || return 1
  [ -f "$rf" ] || return 0
  tmp=$(_message_temp_file "$rf") || return 1
  awk -F'\t' -v now="$now" '$1 != "" && $2 ~ /^[0-9]+$/ && $2 > now' "$rf" > "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$rf" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

recent_ids_unlocked() {
  local recipient="$1"
  local messages_dir="${2:-$MESSAGES_DIR}"
  local rf
  rf=$(recent_file_for "$recipient" "$messages_dir")
  _require_private_message_file_or_absent "$rf" || return 1
  [ -f "$rf" ] || return 0
  awk -F'\t' '$1 != "" { print $1 }' "$rf" 2>/dev/null || true
}

mark_recent_id_unlocked() {
  local recipient="$1" id="$2" now="$3"
  local messages_dir="${4:-$MESSAGES_DIR}"
  [ -n "$recipient" ] && [ -n "$id" ] || return 0
  local rf expires tmp
  rf=$(recent_file_for "$recipient" "$messages_dir")
  _require_private_message_dir "$(dirname "$rf")" || return 1
  _require_private_message_file_or_absent "$rf" || return 1
  expires=$((now + $(recent_id_ttl_ms)))
  tmp=$(_message_temp_file "$rf") || return 1
  awk -F'\t' -v id="$id" '$1 != id' "$rf" > "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$rf" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  printf '%s\t%s\n' "$id" "$expires" >> "$rf"
}

recent_id_seen() {
  local recipient="$1" id="$2"
  [ -n "$recipient" ] && [ -n "$id" ] || return 1
  ensure_messages_dir || return 1
  local lock now found=1
  lock=$(queue_lock_path "$recipient")
  acquire_send_lock "$lock" "queue:${recipient}" || return 1
  now=$(now_ms)
  prune_recent_ids_unlocked "$recipient" "$now"
  if recent_ids_unlocked "$recipient" | grep -Fx "$id" >/dev/null 2>&1; then
    found=0
  fi
  release_send_lock "$lock"
  return "$found"
}

mark_recent_id() {
  local recipient="$1" id="$2"
  [ -n "$recipient" ] && [ -n "$id" ] || return 0
  ensure_messages_dir || return 1
  local lock now
  lock=$(queue_lock_path "$recipient")
  acquire_send_lock "$lock" "queue:${recipient}" || return 1
  now=$(now_ms)
  prune_recent_ids_unlocked "$recipient" "$now"
  mark_recent_id_unlocked "$recipient" "$id" "$now"
  release_send_lock "$lock"
}

# Atomic check-and-mark: prune expired ids, test whether <id> was already
# surfaced, and (only if fresh) mark it — all under one queue lock, so two
# surfacing paths can never both claim the same id (the separate seen+mark
# pair leaves a gap between lock releases).
# Returns 0 if already seen (caller must NOT surface), 1 if fresh (now marked).
# Lock-acquisition failure returns 1: surfacing twice beats losing a message.
recent_id_seen_or_mark() {
  local recipient="$1" id="$2"
  [ -n "$recipient" ] && [ -n "$id" ] || return 1
  ensure_messages_dir || return 1
  local lock now seen=1
  lock=$(queue_lock_path "$recipient")
  acquire_send_lock "$lock" "queue:${recipient}" || return 1
  now=$(now_ms)
  prune_recent_ids_unlocked "$recipient" "$now"
  if recent_ids_unlocked "$recipient" | grep -Fx "$id" >/dev/null 2>&1; then
    seen=0
  else
    mark_recent_id_unlocked "$recipient" "$id" "$now"
  fi
  release_send_lock "$lock"
  return "$seen"
}

enqueue_message() {
  local recipient="$1" id="$2" type="$3" from="$4" payload="$5"
  local messages_dir="${6:-$MESSAGES_DIR}"
  ensure_messages_dir "$messages_dir" || return 1
  local qf lock ready_at
  qf=$(queue_file_for "$recipient" "$messages_dir")
  _require_private_message_dir "$(dirname "$qf")" || return 1
  _require_private_message_file_or_absent "$qf" || return 1
  ready_at=$(queue_ready_at_ms)
  lock=$(queue_lock_path "$recipient" "$messages_dir")
  acquire_send_lock "$lock" "queue:${recipient}" || return 1
  _require_private_message_file_or_absent "$qf" || { release_send_lock "$lock"; return 1; }
  emit_queue_record "$id" "$type" "$from" "$ready_at" "$(queue_priority_value)" "$(queue_expires_at_ms)" "$payload" >> "$qf"
  release_send_lock "$lock"
}

dequeue_message_id() {
  local recipient="$1" id="$2"
  local messages_dir="${3:-$MESSAGES_DIR}"
  local qf lock tmp
  qf=$(queue_file_for "$recipient" "$messages_dir")
  _require_private_message_file_or_absent "$qf" || return 1
  [ -f "$qf" ] || return 0
  lock=$(queue_lock_path "$recipient" "$messages_dir")
  acquire_send_lock "$lock" "queue:${recipient}" || return 1
  _require_private_message_file_or_absent "$qf" || { release_send_lock "$lock"; return 1; }
  tmp=$(_message_temp_file "$qf") || { release_send_lock "$lock"; return 1; }
  awk -F'\t' -v id="$id" '$1 != id' "$qf" > "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$qf" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  release_send_lock "$lock"
}

mark_message_ready() {
  local recipient="$1" id="$2"
  local messages_dir="${3:-$MESSAGES_DIR}"
  local qf lock tmp now line
  qf=$(queue_file_for "$recipient" "$messages_dir")
  _require_private_message_file_or_absent "$qf" || return 1
  [ -f "$qf" ] || return 0
  lock=$(queue_lock_path "$recipient" "$messages_dir")
  acquire_send_lock "$lock" "queue:${recipient}" || return 1
  _require_private_message_file_or_absent "$qf" || { release_send_lock "$lock"; return 1; }
  tmp=$(_message_temp_file "$qf") || { release_send_lock "$lock"; return 1; }
  now=$(now_ms)
  : > "$tmp"
  while IFS= read -r line; do
    parse_queue_record "$line" || continue
    if [ "$QR_ID" = "$id" ]; then
      emit_queue_record "$QR_ID" "$QR_TYPE" "$QR_FROM" "$now" "$QR_PRIO" "$QR_EXPIRES" "$QR_PAYLOAD" >> "$tmp"
    else
      emit_queue_record "$QR_ID" "$QR_TYPE" "$QR_FROM" "$QR_READY" "$QR_PRIO" "$QR_EXPIRES" "$QR_PAYLOAD" >> "$tmp"
    fi
  done < "$qf"
  mv -f "$tmp" "$qf" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  release_send_lock "$lock"
}

# claim_inbox_ids <recipient_name> <space-separated ids>: atomically remove
# exactly the rows whose ids were already emitted by the incoming hook, and
# mark every listed id recent even when its durable row was concurrently
# removed (or never existed, as with a live-only paste). Expired rows are also
# pruned under the same lock as normal TTL maintenance. Call this only AFTER a
# successful hook emit: a crash before the claim can then duplicate a message
# on the next hook, but can never lose one.
claim_inbox_ids() {
  local recipient="$1"
  local claim_ids="$2"
  [ -n "$recipient" ] || return 0
  [ -n "${claim_ids// /}" ] || return 0
  ensure_messages_dir || return 1

  local qf lock now tmp line claim_id
  qf=$(queue_file_for "$recipient")
  _require_private_message_file_or_absent "$qf" || return 1
  lock=$(queue_lock_path "$recipient")
  acquire_send_lock "$lock" "queue:${recipient}" || return 1
  _require_private_message_file_or_absent "$qf" || { release_send_lock "$lock"; return 1; }
  now=$(now_ms)
  prune_recent_ids_unlocked "$recipient" "$now"

  # Mark the full emitted set, including a LIVE_ID whose queue copy is absent.
  # IDs are generated as lowercase hex; ignore malformed legacy values rather
  # than letting whitespace or glob characters affect this loop.
  while IFS= read -r claim_id; do
    case "$claim_id" in
      ''|*[!a-f0-9]*) continue ;;
    esac
    mark_recent_id_unlocked "$recipient" "$claim_id" "$now"
  done < <(printf '%s\n' "$claim_ids" | tr ' ' '\n')

  if [ -f "$qf" ]; then
    tmp=$(_message_temp_file "$qf") || { release_send_lock "$lock"; return 1; }
    : > "$tmp"
    while IFS= read -r line; do
      parse_queue_record "$line" || continue
      case " $claim_ids " in *" $QR_ID "*) continue ;; esac
      if [ "$QR_EXPIRES" -gt 0 ] && [ "$QR_EXPIRES" -le "$now" ]; then
        mark_recent_id_unlocked "$recipient" "$QR_ID" "$now"
        continue
      fi
      emit_queue_record "$QR_ID" "$QR_TYPE" "$QR_FROM" "$QR_READY" "$QR_PRIO" "$QR_EXPIRES" "$QR_PAYLOAD" >> "$tmp"
    done < "$qf"
    mv -f "$tmp" "$qf" 2>/dev/null || {
      rm -f "$tmp" 2>/dev/null
      release_send_lock "$lock"
      return 1
    }
  fi
  release_send_lock "$lock"
}

# drain_inbox <skip_ids> <recipient_name>: print queued records whose id is not
# in the space-separated <skip_ids>, then remove every surfaced/skipped id.
# High-priority rows surface before normal ones; expired rows drop unsurfaced.
drain_inbox() {
  local skip_ids="$1"
  local recipient="$2"
  [ -n "$recipient" ] || return 0
  local qf lock now recent_ids
  qf=$(queue_file_for "$recipient")
  _require_private_message_file_or_absent "$qf" || return 1
  [ -f "$qf" ] || return 0
  lock=$(queue_lock_path "$recipient")
  acquire_send_lock "$lock" "queue:${recipient}" || return 0
  _require_private_message_file_or_absent "$qf" || { release_send_lock "$lock"; return 1; }
  now=$(now_ms)
  prune_recent_ids_unlocked "$recipient" "$now"
  recent_ids=$(recent_ids_unlocked "$recipient" | tr '\n' ' ')
  local remove_ids="" line pass_prio
  for pass_prio in 1 0; do
    while IFS= read -r line; do
      parse_queue_record "$line" || continue
      [ "$QR_PRIO" = "$pass_prio" ] || continue
      case " $skip_ids $remove_ids " in
        *" $QR_ID "*)
          mark_recent_id_unlocked "$recipient" "$QR_ID" "$now"
          remove_ids="$remove_ids $QR_ID"
          continue
          ;;
      esac
      case " $recent_ids " in
        *" $QR_ID "*)
          remove_ids="$remove_ids $QR_ID"
          continue
          ;;
      esac
      # Past its TTL: the sender's relevance window closed; drop unsurfaced.
      if [ "$QR_EXPIRES" -gt 0 ] && [ "$QR_EXPIRES" -le "$now" ]; then
        mark_recent_id_unlocked "$recipient" "$QR_ID" "$now"
        remove_ids="$remove_ids $QR_ID"
        continue
      fi
      if [ "$QR_READY" -gt "$now" ]; then
        continue
      fi
      printf '%s\t%s\t%s\t%s\n' "$QR_ID" "$QR_TYPE" "$QR_FROM" "$QR_PAYLOAD"
      mark_recent_id_unlocked "$recipient" "$QR_ID" "$now"
      remove_ids="$remove_ids $QR_ID"
    done < "$qf"
  done
  local tmp
  tmp=$(_message_temp_file "$qf") || { release_send_lock "$lock"; return 1; }
  : > "$tmp"
  while IFS= read -r line; do
    parse_queue_record "$line" || continue
    case " $skip_ids $remove_ids " in *" $QR_ID "*) continue ;; esac
    emit_queue_record "$QR_ID" "$QR_TYPE" "$QR_FROM" "$QR_READY" "$QR_PRIO" "$QR_EXPIRES" "$QR_PAYLOAD" >> "$tmp"
  done < "$qf"
  mv -f "$tmp" "$qf" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  release_send_lock "$lock"
}

# inbox_candidates <skip_ids> <recipient_name>: print a read-only, priority-
# ordered snapshot of rows that are currently eligible to surface. The caller
# may render these rows and choose a context-sized subset before claiming them
# with claim_inbox_ids after a successful emit. Keeping selection separate from
# mutation prevents a hook from deleting fan-in rows that would only be hidden
# by output truncation, or selected rows when output itself fails.
inbox_candidates() {
  local skip_ids="$1"
  local recipient="$2"
  [ -n "$recipient" ] || return 0
  local qf lock now recent_ids recent_file line pass_prio
  qf=$(queue_file_for "$recipient")
  _require_private_message_file_or_absent "$qf" || return 1
  [ -f "$qf" ] || return 0
  lock=$(queue_lock_path "$recipient")
  acquire_send_lock "$lock" "queue:${recipient}" || return 0
  _require_private_message_file_or_absent "$qf" || { release_send_lock "$lock"; return 1; }
  now=$(now_ms)
  recent_file=$(recent_file_for "$recipient")
  _require_private_message_file_or_absent "$recent_file" || { release_send_lock "$lock"; return 1; }
  recent_ids=""
  if [ -f "$recent_file" ]; then
    recent_ids=$(awk -F'\t' -v now="$now" '$1 != "" && $2 ~ /^[0-9]+$/ && $2 > now { print $1 }' "$recent_file" 2>/dev/null | tr '\n' ' ')
  fi
  for pass_prio in 1 0; do
    while IFS= read -r line; do
      parse_queue_record "$line" || continue
      [ "$QR_PRIO" = "$pass_prio" ] || continue
      case " $skip_ids " in *" $QR_ID "*) continue ;; esac
      case " $recent_ids " in *" $QR_ID "*) continue ;; esac
      if [ "$QR_EXPIRES" -gt 0 ] && [ "$QR_EXPIRES" -le "$now" ]; then
        continue
      fi
      [ "$QR_READY" -le "$now" ] || continue
      printf '%s\t%s\t%s\t%s\n' "$QR_ID" "$QR_TYPE" "$QR_FROM" "$QR_PAYLOAD"
    done < "$qf"
  done
  release_send_lock "$lock"
}

# drain_inbox_ids <claim_ids> <skip_ids> <recipient_name>: atomically claim
# only the eligible IDs selected from inbox_candidates. Rows claimed by a
# concurrent hook are not emitted twice; unclaimed ready rows remain queued.
# Skipped, recently surfaced, and expired rows retain drain_inbox semantics.
drain_inbox_ids() {
  local claim_ids="$1"
  local skip_ids="$2"
  local recipient="$3"
  [ -n "$recipient" ] || return 0
  local qf lock now recent_ids remove_ids line pass_prio tmp
  qf=$(queue_file_for "$recipient")
  _require_private_message_file_or_absent "$qf" || return 1
  [ -f "$qf" ] || return 0
  lock=$(queue_lock_path "$recipient")
  acquire_send_lock "$lock" "queue:${recipient}" || return 0
  _require_private_message_file_or_absent "$qf" || { release_send_lock "$lock"; return 1; }
  now=$(now_ms)
  prune_recent_ids_unlocked "$recipient" "$now"
  recent_ids=$(recent_ids_unlocked "$recipient" | tr '\n' ' ')
  remove_ids=""
  for pass_prio in 1 0; do
    while IFS= read -r line; do
      parse_queue_record "$line" || continue
      [ "$QR_PRIO" = "$pass_prio" ] || continue
      case " $skip_ids $remove_ids " in
        *" $QR_ID "*)
          mark_recent_id_unlocked "$recipient" "$QR_ID" "$now"
          remove_ids="$remove_ids $QR_ID"
          continue
          ;;
      esac
      case " $recent_ids " in
        *" $QR_ID "*)
          remove_ids="$remove_ids $QR_ID"
          continue
          ;;
      esac
      if [ "$QR_EXPIRES" -gt 0 ] && [ "$QR_EXPIRES" -le "$now" ]; then
        mark_recent_id_unlocked "$recipient" "$QR_ID" "$now"
        remove_ids="$remove_ids $QR_ID"
        continue
      fi
      [ "$QR_READY" -le "$now" ] || continue
      case " $claim_ids " in *" $QR_ID "*) ;; *) continue ;; esac
      printf '%s\t%s\t%s\t%s\n' "$QR_ID" "$QR_TYPE" "$QR_FROM" "$QR_PAYLOAD"
      mark_recent_id_unlocked "$recipient" "$QR_ID" "$now"
      remove_ids="$remove_ids $QR_ID"
    done < "$qf"
  done
  tmp=$(_message_temp_file "$qf") || { release_send_lock "$lock"; return 1; }
  : > "$tmp"
  while IFS= read -r line; do
    parse_queue_record "$line" || continue
    case " $skip_ids $remove_ids " in *" $QR_ID "*) continue ;; esac
    emit_queue_record "$QR_ID" "$QR_TYPE" "$QR_FROM" "$QR_READY" "$QR_PRIO" "$QR_EXPIRES" "$QR_PAYLOAD" >> "$tmp"
  done < "$qf"
  mv -f "$tmp" "$qf" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  release_send_lock "$lock"
}

# --- Outbound ledger (reply correlation) ---
# Append-only TSVs in *this* runtime's messages dir, written with single
# O_APPEND printf calls (atomic for short lines). Readers tolerate a partial
# view; the occasional lost row under a concurrent trim is acceptable — this
# ledger powers /check-replies reporting, not delivery.
#   sent-log.tsv:    <ts_ms>\t<id>\t<from>\t<to>\t<type>\t<delivery>\t<excerpt>
#   replies-log.tsv: <ts_ms>\t<reply_to_id>\t<from>

sent_log_file() { printf '%s/sent-log.tsv' "$MESSAGES_DIR"; }
replies_log_file() { printf '%s/replies-log.tsv' "$MESSAGES_DIR"; }

log_excerpt() {
  printf '%s' "$1" | tr '\t\n\r' '   ' | cut -c1-80
}

trim_log_file() {
  local f="$1"
  local max=5000 keep=2500
  [ -f "$f" ] || return 0
  local lines
  lines=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
  is_nonnegative_int "$lines" || return 0
  [ "$lines" -gt "$max" ] || return 0
  local tmp
  tmp=$(_message_temp_file "$f") || return 0
  tail -n "$keep" "$f" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

log_sent_message() {
  # log_sent_message <id> <from> <to> <type> <delivery> <excerpt-source>
  local id="$1" from="$2" to="$3" type="$4" delivery="$5"
  local excerpt
  excerpt=$(log_excerpt "$6")
  local sf
  sf=$(sent_log_file)
  ensure_messages_dir || return 0
  _require_private_message_file_or_absent "$sf" || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(now_ms)" "$id" "$from" "$to" "$type" "$delivery" "$excerpt" >> "$sf" 2>/dev/null || true
  trim_log_file "$sf"
  archive_message "out" "$to" "$type" "$id" "$6"
}

log_reply_ids() {
  # log_reply_ids <from> <text> — record every [re:<id>] token in <text> as a
  # reply from <from>. The bracketed form is required: a bare "re:" inside an
  # arbitrary word (e.g. "more:<hex>") must not register as a reply.
  local from="$1" text="$2"
  [ -n "$from" ] || return 0
  local rf id
  rf=$(replies_log_file)
  ensure_messages_dir || return 0
  _require_private_message_file_or_absent "$rf" || return 0
  printf '%s' "$text" | grep -oE '\[re:[a-f0-9]{8,16}\]' 2>/dev/null | sed 's/^\[re://; s/\]$//' | sort -u | \
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf '%s\t%s\t%s\n' "$(now_ms)" "$id" "$from" >> "$rf" 2>/dev/null || true
  done
  trim_log_file "$rf"
}

# --- Message archive (search) ---
# Daily TSVs under $MESSAGES_DIR/archive/<YYYY-MM-DD>.tsv:
#   <ts_ms>\t<direction in|out>\t<peer>\t<type>\t<id>\t<excerpt 200ch>
# Written best-effort on every send and on every surfaced incoming message;
# message-search greps these (plus dispatch file bodies). Files older than
# the retention window are pruned opportunistically on append.

archive_retention_days() {
  normalize_positive_int "${SESSION_CHAT_ARCHIVE_RETENTION_DAYS:-30}" 30
}

archive_message() {
  # archive_message <direction> <peer> <type> <id> <text>
  local direction="$1" peer="$2" type="$3" id="$4" text="$5"
  local dir day f
  ensure_messages_dir || return 0
  dir="$MESSAGES_DIR/archive"
  _require_private_message_dir "$dir" || return 0
  day=$(date +%Y-%m-%d 2>/dev/null) || return 0
  f="$dir/${day}.tsv"
  _require_private_message_file_or_absent "$f" || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(now_ms)" "$direction" "$peer" "$type" "$id" \
    "$(printf '%s' "$text" | tr '\t\n\r' '   ' | cut -c1-200)" >> "$f" 2>/dev/null || true
  find "$dir" -name '*.tsv' -type f -mtime +"$(archive_retention_days)" -delete 2>/dev/null || true
}

send_text_once() {
  local pane_id="$1"
  local text="$2"
  local marker_supplied="${3+x}"
  local marker="${3:-$text}"
  local settle_ms="${SESSION_CHAT_SETTLE_MS:-300}"
  local paste_placeholders_before=0
  if [ "${SESSION_CHAT_SKIP_VERIFY:-}" != "1" ]; then
    paste_placeholders_before=$(capture_paste_placeholder_count "$pane_id")
  fi
  # Literal mode + split text/Enter for TUI safety (smux pattern).
  # A failed paste is RETRYABLE (return 2): clear any partial staging first so
  # the retry starts from a clean composer rather than duplicating text.
  if ! tmux send-keys -t "$pane_id" -l -- "$text"; then
    clear_partial_input "$pane_id"
    return 2
  fi

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
      if [ "$(printf '%s\n' "$captured" | count_paste_placeholders)" -gt "$paste_placeholders_before" ]; then
        break
      fi
      sleep 0.05
      i=$((i + 1))
    done

    if [ "$i" -ge "$attempts" ]; then
      clear_partial_input "$pane_id"
      return 2
    fi
  fi

  # Enter is the SUBMIT. If it fails, the text is staged but was never sent;
  # this is NON-retryable (return 1) — retrying the whole paste would duplicate
  # text in the composer. The caller (send_text -> send_message) must treat this
  # as a failed live send and leave the durable copy queued, never dequeue it.
  # Best-effort clear the staged (unsubmitted) text so it doesn't linger.
  if ! tmux send-keys -t "$pane_id" Enter; then
    clear_partial_input "$pane_id"
    return 1
  fi

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
  lock_dir=$(send_lock_path "$pane_id") || return 1

  # Hold the send-lock across the ENTIRE retry sequence, not per-attempt: the
  # lock exists so concurrent senders don't interleave keystrokes, and that
  # guarantee must span the clear/backoff/retry gaps too — otherwise another
  # sender could paste a competing message into this pane between our attempts.
  acquire_send_lock "$lock_dir" "$pane_id" || return 1

  while [ "$attempt" -le "$max_attempts" ]; do
    if [ -n "$marker_supplied" ]; then
      send_text_once "$pane_id" "$text" "$marker"
    else
      send_text_once "$pane_id" "$text"
    fi
    status=$?

    if [ "$status" -eq 0 ]; then
      release_send_lock "$lock_dir"
      return 0
    fi
    # status 1 = non-retryable submit (Enter) failure — bail now, let the
    # caller keep the durable copy queued. Only status 2 (paste fail / verify
    # timeout) is retryable.
    if [ "$status" -ne 2 ]; then
      release_send_lock "$lock_dir"
      return "$status"
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      release_send_lock "$lock_dir"
      local timeout_ms
      timeout_ms=$(normalize_positive_int "${SESSION_CHAT_VERIFY_TIMEOUT_MS:-4000}" 4000)
      echo "ERROR: send to $pane_id did not land within ${timeout_ms}ms after ${max_attempts} attempts — recipient may be busy." >&2
      return 1
    fi

    sleep_ms $((backoff_ms * attempt))
    attempt=$((attempt + 1))
  done

  release_send_lock "$lock_dir"
  return 1
}

# Refuse to paste into a pane sitting at a shell prompt: the bracketed
# message line would be EXECUTED by the shell, not read by an agent. Found
# live when a recipient's agent had exited between resolve and paste.
ensure_agent_target() {
  local target_name="$1" target_pane="$2"
  [ "${SESSION_CHAT_ALLOW_SHELL_TARGET:-0}" = "1" ] && return 0
  local cmd
  cmd=$(tmux display-message -p -t "$target_pane" '#{pane_current_command}' 2>/dev/null || true)
  case "$cmd" in
    zsh|bash|fish|sh|dash|tcsh|ksh|-zsh|-bash)
      echo "ERROR: pane '$target_name' is at a shell prompt ($cmd), not an agent TUI — pasting would execute the message in the shell. Start the agent there first, or set SESSION_CHAT_ALLOW_SHELL_TARGET=1 to override." >&2
      return 1
      ;;
  esac
  return 0
}

send_message() {
  local target_name="$1"
  local message="$2"
  local my_name tmux_err
  my_name=$(get_my_name)
  tmux_err=$(pop_pane_name_err)
  if [ -z "$my_name" ]; then
    report_current_pane_name_failure "$tmux_err"
    return 1
  fi
  if ! validate_label "$my_name"; then
    echo "ERROR: This pane has an unsafe externally assigned name. Rename it with \$session-chat:whoami <name>." >&2
    return 1
  fi
  case "$SEND_MAX_LEN" in
    ''|*[!0-9]*) SEND_MAX_LEN=1024 ;;
  esac
  if [[ "$message" == *$'\n'* ]]; then
    echo "ERROR: \$session-chat:send only supports single-line messages. Use \$session-chat:dispatch <target> <task> for multi-line content." >&2
    return 1
  fi
  if [ "${#message}" -gt "$SEND_MAX_LEN" ]; then
    echo "ERROR: \$session-chat:send payload exceeds ${SEND_MAX_LEN} characters. Use \$session-chat:dispatch <target> <task> for long content." >&2
    return 1
  fi
  local target_pane
  target_pane=$(resolve_pane "$target_name") || return 1
  ensure_agent_target "$target_name" "$target_pane" || return 1
  local target_messages_dir
  target_messages_dir=$(target_messages_dir_for_pane "$target_pane")
  local uid
  uid=$(generate_id)
  # Durable copy first so a busy/failed paste is never a lost message.
  enqueue_message "$target_name" "$uid" "send" "$my_name" "$message" "$target_messages_dir" || return 1
  local formatted="[from:${my_name} pane:${TMUX_PANE:-} id:${uid}] ${message} [id:${uid}]"
  if send_text "$target_pane" "$formatted" "id:${uid}"; then
    dequeue_message_id "$target_name" "$uid" "$target_messages_dir"
    log_sent_message "$uid" "$my_name" "$target_name" "send" "live" "$message"
    return 0
  fi
  mark_message_ready "$target_name" "$uid" "$target_messages_dir" || true
  log_sent_message "$uid" "$my_name" "$target_name" "send" "queued" "$message"
  return 3
}

dispatch_message() {
  local target_name="$1"
  local message="$2"
  local my_name tmux_err
  my_name=$(get_my_name)
  tmux_err=$(pop_pane_name_err)
  if [ -z "$my_name" ]; then
    report_current_pane_name_failure "$tmux_err"
    return 1
  fi
  if ! validate_label "$my_name"; then
    echo "ERROR: This pane has an unsafe externally assigned name. Rename it with \$session-chat:whoami <name>." >&2
    return 1
  fi
  local target_pane
  target_pane=$(resolve_pane "$target_name") || return 1
  ensure_agent_target "$target_name" "$target_pane" || return 1
  local target_messages_dir
  target_messages_dir=$(target_messages_dir_for_pane "$target_pane")

  # Write full message to file (handles multi-line + special chars)
  ensure_messages_dir "$target_messages_dir" || return 1
  local uid
  uid=$(generate_id)
  local msg_id
  msg_id="$(date +%s)-$$-${uid}-${my_name}-to-${target_name}"
  local msg_file="$target_messages_dir/${msg_id}.md"
  _write_private_message_file "$msg_file" "$message" || return 1

  # Send single-line notification with file reference
  local line_count
  line_count=$(printf '%s\n' "$message" | wc -l | tr -d ' ')
  # Durable copy first (points at the task file), then the live nudge.
  enqueue_message "$target_name" "$uid" "dispatch" "$my_name" "$msg_file" "$target_messages_dir" || return 1
  if send_text "$target_pane" "[from:${my_name} pane:${TMUX_PANE:-} msg:${msg_file} id:${uid}] dispatch (${line_count} lines) — read msg file for full task id:${uid}" "id:${uid}"; then
    dequeue_message_id "$target_name" "$uid" "$target_messages_dir"
    log_sent_message "$uid" "$my_name" "$target_name" "dispatch" "live" "$message"
    return 0
  fi
  mark_message_ready "$target_name" "$uid" "$target_messages_dir" || true
  log_sent_message "$uid" "$my_name" "$target_name" "dispatch" "queued" "$message"
  return 3
}

read_pane() {
  local pane_id="$1"
  local lines="${2:-50}"
  tmux capture-pane -t "$pane_id" -p | tail -"$lines"
}

# --- Platform-compatible utilities ---

portable_date_iso() {
  TZ=Asia/Kolkata date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null
}
