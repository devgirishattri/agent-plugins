#!/usr/bin/env bash
# lib.sh — Shared functions for session-chat plugin
# Source this file: source "$(dirname "$0")/lib.sh"
# Supported platforms: macOS, Linux

# Inter-session messages, durable queues, dispatch task files and reply/archive
# ledgers all hold peer-supplied content that must stay private to this user —
# a co-tenant on a shared host must not be able to read another user's dispatched
# task bodies or plant files the trust gate would honor. Force owner-only perms
# on everything this library creates. This is process-local (each session-chat
# script runs in its own subprocess and callers invoke our scripts as
# subprocesses, not by sourcing lib.sh into their own shell), so it never
# tightens the user's interactive umask.
umask 077

# --- tmux checks ---

ensure_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "ERROR: tmux is not installed." >&2
    echo "Install with: brew install tmux (macOS) or apt install tmux (Ubuntu)" >&2
    exit 1
  fi
  if [ -z "${TMUX:-}" ]; then
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

MESSAGES_DIR="${CLAUDE_HOME:-$HOME/.claude}/messages"

# Lock the private messages tree to owner-only, and FAIL CLOSED on any unsafe
# root. umask 077 already keeps *new* files/dirs private (0600/0700); this
# additionally (a) re-asserts 0700 on the top dir every call in case it predates
# the hardening or was created loosely, and (b) migrates an existing tree's
# contents to 0600/0700 exactly once, guarded by a marker so the recursive chmod
# never runs on the hot path. Returns NON-ZERO (so the caller refuses to write)
# whenever the path is a symlink, not a real directory, or not owned by us — we
# must never operate through an attacker-planted symlink or into a dir owned by
# another local user.
harden_messages_dir() {
  local dir="${1:-$MESSAGES_DIR}"
  # -L before -d: a symlink-to-dir passes -d, so reject the symlink first.
  [ -L "$dir" ] && return 1
  [ -d "$dir" ] || return 1
  [ -O "$dir" ] || return 1
  # Fail closed if tightening itself fails: a dir we couldn't lock to 0700, a
  # migration chmod that didn't take, or a marker we couldn't write all mean we
  # cannot vouch for the tree's privacy — the caller must then refuse to write.
  chmod 700 "$dir" 2>/dev/null || return 1
  local marker="$dir/.perms-hardened-v1"
  [ -e "$marker" ] && return 0
  find "$dir" -type d ! -type l -exec chmod 700 {} + 2>/dev/null || return 1
  find "$dir" -type f ! -type l -exec chmod 600 {} + 2>/dev/null || return 1
  : > "$marker" 2>/dev/null || return 1
  return 0
}

# Ensure the messages dir exists AND is safe (owner-only, real, non-symlink).
# Fails closed (returns non-zero) rather than creating or writing through an
# unsafe path — callers that write MUST check this return. Silent: user-facing
# callers (send/dispatch) print their own actionable error on failure.
ensure_messages_dir() {
  local messages_dir="${1:-$MESSAGES_DIR}"
  # Never let `mkdir -p` materialize an attacker-planted symlink's target.
  [ -L "$messages_dir" ] && return 1
  mkdir -p "$messages_dir" 2>/dev/null || true
  harden_messages_dir "$messages_dir"
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
  # Invalid names (spaces etc.) would be unreachable via resolve_pane forever.
  validate_label "$name" || return 1
  tmux set-option -p -t "$pane_id" @name "$name"
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
  local dir
  dir="${TMPDIR:-/tmp}/session-chat-priv-$(id -u 2>/dev/null || printf '0')"
  [ -e "$dir" ] || mkdir -m 700 "$dir" 2>/dev/null
  # Refuse anything that isn't a real, non-symlink directory we own: a
  # pre-planted symlink or attacker-owned directory at this path must never
  # be trusted, even if that means falling back to losing the diagnostic.
  if [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ]; then
    printf '%s' "$dir"
  fi
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

# Run a user-facing tmux command with its stderr preserved and its result
# fail-checked, so a sandbox denial can never masquerade as a valid empty
# result. No user-facing tmux call may drop its stderr with 2>/dev/null.
#
#   tmux_capture_checked <tag> <stdout_var> <err_var> <tmux-args...>
#
# On success (exit 0 AND clean stderr): <stdout_var>=stdout, <err_var>="", rc 0.
# On failure (nonzero exit OR anything on stderr): <stdout_var>="" (the data
# output is CLEARED so callers cannot accidentally treat a denial as empty
# data), <err_var>=the captured stderr, rc 1. Callers classify <err_var> with
# tmux_err_detail / pane_name_err_detail and surface it.
#
# Primary path routes stderr to a private per-tag file. If that private scratch
# dir is unavailable, the fallback still captures stderr via 2>&1 (folded into
# the stream, then split back out on failure) rather than discarding it.
tmux_capture_checked() {
  local tag="$1" stdout_var="$2" err_var="$3"
  shift 3
  local out err_file rc err=""
  if err_file="$(_tmux_err_file "$tag")"; then
    out=$(tmux "$@" 2>"$err_file")
    rc=$?
    err=$(_pop_tmux_err "$tag")
  else
    out=$(tmux "$@" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      err="$out"
      out=""
    fi
  fi
  if [ "$rc" -ne 0 ] || [ -n "$err" ]; then
    printf -v "$stdout_var" '%s' ""
    printf -v "$err_var" '%s' "$err"
    return 1
  fi
  printf -v "$stdout_var" '%s' "$out"
  printf -v "$err_var" '%s' ""
  return 0
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

# Format the "(tmux: ...)" suffix for a tmux-command error, given the stderr
# _pop_tmux_err returned. "Operation not permitted" is the signature of a
# sandboxed exec (e.g. a Codex sandbox profile) denying the tmux socket
# connect() outright — confirmed live 2026-07-09 (REPRO-0162, self-name query;
# and again via fresh-session data hitting resolve_pane instead): the exact
# same command succeeds on a later, differently-
# classified invocation, so this is not a fixable state within the current
# process — the caller needs to re-run the whole command escalated/approved,
# not just retry the tmux call.
pane_name_err_detail() {
  local tmux_err="$1"
  [ -n "$tmux_err" ] || return 0
  local hint=""
  case "$tmux_err" in
    *"Operation not permitted"*|*"Permission denied"*)
      hint=" — looks like a sandboxed exec denied the tmux socket; re-run this command escalated/approved, or set SESSION_CHAT_PANE_NAME to skip self-name resolution"
      ;;
  esac
  printf ' (tmux: %s)%s' "$tmux_err" "$hint"
}

# General-purpose sibling of pane_name_err_detail for callers that ENUMERATE
# panes (list-panes, pane-health, broadcast) or resolve the current session,
# rather than resolve one pane by name. Same socket-denial classification
# ("Operation not permitted" or "Permission denied"), minus the self-name
# SESSION_CHAT_PANE_NAME escape hatch — that hint is meaningless when you are
# listing every pane rather than resolving your own. Callers use this to turn a
# silently-empty tmux result under sandbox denial into a loud, actionable error
# instead of falsely reporting "no named panes".
tmux_err_detail() {
  local tmux_err="$1"
  [ -n "$tmux_err" ] || return 0
  local hint=""
  case "$tmux_err" in
    *"Operation not permitted"*|*"Permission denied"*)
      hint=" — looks like a sandboxed exec denied the tmux socket; re-run this command escalated/approved"
      ;;
  esac
  printf ' (tmux: %s)%s' "$tmux_err" "$hint"
}

# --- Pane resolution (searches ALL tmux sessions) ---

resolve_pane() {
  local label="$1"
  # A pane name flows raw into dispatch filenames/records downstream, so reject
  # any label carrying path metacharacters (slashes, dots) up front — nothing
  # unsafe must ever reach a filesystem path. Use the shared validate_label
  # contract (same charset gate set_pane_name enforces); surface a pane-specific
  # message instead of the generic one.
  if ! validate_label "$label" 2>/dev/null; then
    echo "ERROR: invalid pane name '$label' (letters, digits, _, - only)." >&2
    return 1
  fi
  local matches err_file
  # Tab delimiter: a legacy/manually-set name containing whitespace must not
  # shift awk fields and silently become unreachable.
  if err_file="$(_tmux_err_file resolve-pane)"; then
    matches=$(tmux list-panes -a -F $'#{pane_id}\t#{@name}' 2>"$err_file" \
      | awk -F'\t' -v want="$label" '$2 == want { print $1 }' | sed '/^$/d')
  else
    matches=$(tmux list-panes -a -F $'#{pane_id}\t#{@name}' 2>/dev/null \
      | awk -F'\t' -v want="$label" '$2 == want { print $1 }' | sed '/^$/d')
  fi
  local tmux_err
  tmux_err=$(_pop_tmux_err resolve-pane)
  local count
  count=$(printf '%s' "$matches" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    # An empty result here is ambiguous by itself: either no pane is named
    # $label, or `tmux list-panes` itself failed (e.g. a sandboxed exec
    # denying the socket) and silently returned nothing. Surface the real
    # cause when we have one instead of always implying the target is
    # unregistered — confirmed live 2026-07-09 in fresh Codex sessions: this
    # was the actual, and only, failure point in 4/4 attempts.
    echo "ERROR: No pane named '$label'. Run /panes all to see all available named panes.$(pane_name_err_detail "$tmux_err")" >&2
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    local listed
    listed=$(printf '%s\n' "$matches" | awk 'BEGIN { out="" } { out = out (out ? ", " : "") $0 } END { print out }')
    echo "ERROR: Multiple panes named '$label' ($listed). Rename one with /whoami in that pane." >&2
    return 1
  fi
  printf '%s\n' "$matches" | head -1
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

# Private per-user root for send-lock dirs. Must be a real, owner-owned,
# non-symlink 0700 directory: a predictable path directly under a world-writable
# $TMPDIR would let another local user pre-plant a symlink (redirecting our lock
# mkdir) or an attacker-owned dir and interfere with delivery serialization.
# Fails closed (empty output, non-zero) if it cannot be secured.
_session_chat_lock_root() {
  local dir
  dir="${TMPDIR:-/tmp}/session-chat-locks-$(id -u 2>/dev/null || printf '0')"
  [ -e "$dir" ] || mkdir -m 700 "$dir" 2>/dev/null
  if [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ]; then
    chmod 700 "$dir" 2>/dev/null || return 1
    printf '%s' "$dir"
    return 0
  fi
  return 1
}

session_chat_lock_path() {
  local safe root
  safe=$(printf '%s' "$1" | tr -c 'a-zA-Z0-9._-' '_')
  root=$(_session_chat_lock_root) || return 1
  printf '%s/%s.lock' "$root" "$safe"
}

acquire_lock() {
  local pane="$1"
  local lock
  lock="${2:-}"
  [ -n "$lock" ] || lock=$(session_chat_lock_path "$pane")
  # Fail closed: no safe lock path means we cannot serialize sends safely.
  if [ -z "$lock" ]; then
    echo "ERROR: could not secure a private send-lock directory for ${pane} (unsafe or unavailable ${TMPDIR:-/tmp})." >&2
    return 1
  fi
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

# parse_queue_record <line> — fills QR_ID QR_TYPE QR_FROM QR_READY QR_PRIO
# QR_EXPIRES QR_PAYLOAD from any record vintage. Returns 1 on blank lines.
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
  ensure_messages_dir || return 1
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
  ensure_messages_dir || return 1
  local now
  local lock
  lock=$(queue_lock_path "$recipient")
  acquire_lock "queue:${recipient}" "$lock" || return 1
  now=$(now_ms)
  prune_recent_ids_unlocked "$recipient" "$now"
  mark_recent_id_unlocked "$recipient" "$id" "$now"
  release_lock "queue:${recipient}" "$lock"
}

# --- Peek / atomic-claim (crash-safe fan-in surfacing) ---
# drain_inbox removes every ready row up front, which is unsafe when the caller
# can only surface a budget-limited prefix: rows past the cut would be removed
# but never shown. Instead the hook PEEKs (read-only), renders/selects a prefix
# that fits, then atomically CLAIMs exactly those ids. Overflow rows are never
# touched, so a mid-turn crash can never drop an unsurfaced message.

# peek_inbox <skip_ids> <recipient> — READ-ONLY. Print ready, non-skipped,
# non-recent, non-expired rows (id\ttype\tfrom\tpayload) in priority then FIFO
# order. Mutates nothing (no removal, no recent-mark).
peek_inbox() {
  local skip_ids="$1" recipient="$2"
  [ -n "$recipient" ] || return 0
  local qf lock
  qf=$(queue_file_for "$recipient")
  [ -f "$qf" ] || return 0
  lock=$(queue_lock_path "$recipient")
  acquire_lock "queue:${recipient}" "$lock" || return 0
  local now recent_ids line pass_prio
  now=$(now_ms)
  recent_ids=$(recent_ids_unlocked "$recipient" | tr '\n' ' ')
  for pass_prio in 1 0; do
    while IFS= read -r line; do
      parse_queue_record "$line" || continue
      [ "$QR_PRIO" = "$pass_prio" ] || continue
      case " $skip_ids " in *" $QR_ID "*) continue ;; esac
      case " $recent_ids " in *" $QR_ID "*) continue ;; esac
      if [ "$QR_EXPIRES" -gt 0 ] && [ "$QR_EXPIRES" -le "$now" ]; then continue; fi
      if [ "$QR_READY" -gt "$now" ]; then continue; fi
      printf '%s\t%s\t%s\t%s\n' "$QR_ID" "$QR_TYPE" "$QR_FROM" "$QR_PAYLOAD"
    done < "$qf"
  done
  release_lock "queue:${recipient}" "$lock"
}

# claim_inbox_ids <recipient> <space-separated ids> — atomically remove exactly
# these ids (plus any now-expired rows) from the queue and mark them recent,
# under one lock. Rows not listed are re-emitted untouched, so overflow rows
# never leave the queue. Call AFTER the surfaced rows have been emitted, so a
# crash before the claim re-surfaces (dup) rather than loses.
claim_inbox_ids() {
  local recipient="$1" ids="$2"
  [ -n "$recipient" ] || return 0
  local qf lock
  qf=$(queue_file_for "$recipient")
  [ -f "$qf" ] || return 0
  lock=$(queue_lock_path "$recipient")
  acquire_lock "queue:${recipient}" "$lock" || return 1
  local now tmp line
  now=$(now_ms)
  prune_recent_ids_unlocked "$recipient" "$now"
  tmp="${qf}.tmp.$$"
  : > "$tmp"
  while IFS= read -r line; do
    parse_queue_record "$line" || continue
    case " $ids " in
      *" $QR_ID "*) mark_recent_id_unlocked "$recipient" "$QR_ID" "$now"; continue ;;
    esac
    if [ "$QR_EXPIRES" -gt 0 ] && [ "$QR_EXPIRES" -le "$now" ]; then
      mark_recent_id_unlocked "$recipient" "$QR_ID" "$now"; continue
    fi
    emit_queue_record "$QR_ID" "$QR_TYPE" "$QR_FROM" "$QR_READY" "$QR_PRIO" "$QR_EXPIRES" "$QR_PAYLOAD" >> "$tmp"
  done < "$qf"
  mv -f "$tmp" "$qf" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  release_lock "queue:${recipient}" "$lock"
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
  local now seen=1
  local lock
  lock=$(queue_lock_path "$recipient")
  acquire_lock "queue:${recipient}" "$lock" || return 1
  now=$(now_ms)
  prune_recent_ids_unlocked "$recipient" "$now"
  if recent_ids_unlocked "$recipient" | grep -Fx "$id" >/dev/null 2>&1; then
    seen=0
  else
    mark_recent_id_unlocked "$recipient" "$id" "$now"
  fi
  release_lock "queue:${recipient}" "$lock"
  return "$seen"
}

enqueue_message() {
  # enqueue_message <recipient_name> <id> <type> <from> <payload> [messages_dir]
  local recipient="$1" id="$2" type="$3" from="$4" payload="$5"
  local messages_dir="${6:-$MESSAGES_DIR}"
  ensure_messages_dir "$messages_dir" || return 1
  local qf ready_at lock
  qf=$(queue_file_for "$recipient" "$messages_dir")
  mkdir -p "$(dirname "$qf")" 2>/dev/null || true
  ready_at=$(queue_ready_at_ms)
  lock=$(queue_lock_path "$recipient" "$messages_dir")
  acquire_lock "queue:${recipient}" "$lock" || return 1
  emit_queue_record "$id" "$type" "$from" "$ready_at" "$(queue_priority_value)" "$(queue_expires_at_ms)" "$payload" >> "$qf"
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
  local qf tmp now line lock
  qf=$(queue_file_for "$recipient" "$messages_dir")
  [ -f "$qf" ] || return 0
  lock=$(queue_lock_path "$recipient" "$messages_dir")
  acquire_lock "queue:${recipient}" "$lock" || return 1
  tmp="${qf}.tmp.$$"
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
  local remove_ids="" line pass_prio
  # High-priority rows surface before normal ones; FIFO within each class.
  for pass_prio in 1 0; do
    while IFS= read -r line; do
      parse_queue_record "$line" || continue
      [ "$QR_PRIO" = "$pass_prio" ] || continue
      # Caller already showed this id live this turn: mark recent, drop, no surface.
      case " $skip_ids $remove_ids " in
        *" $QR_ID "*)
          mark_recent_id_unlocked "$recipient" "$QR_ID" "$now"
          remove_ids="$remove_ids $QR_ID"
          continue
          ;;
      esac
      # Already surfaced on a prior turn (live or recovery): drop, no re-surface.
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
      # Still within its grace window: leave it for a later turn.
      if [ "$QR_READY" -gt "$now" ]; then
        continue
      fi
      printf '%s\t%s\t%s\t%s\n' "$QR_ID" "$QR_TYPE" "$QR_FROM" "$QR_PAYLOAD"
      mark_recent_id_unlocked "$recipient" "$QR_ID" "$now"
      remove_ids="$remove_ids $QR_ID"
    done < "$qf"
  done
  # Rewrite the queue, keeping only rows we neither surfaced, skipped, nor
  # deferred. Deferred (not-ready) rows are re-emitted in canonical form.
  local tmp="${qf}.tmp.$$"
  : > "$tmp"
  while IFS= read -r line; do
    parse_queue_record "$line" || continue
    case " $skip_ids $remove_ids " in *" $QR_ID "*) continue ;; esac
    emit_queue_record "$QR_ID" "$QR_TYPE" "$QR_FROM" "$QR_READY" "$QR_PRIO" "$QR_EXPIRES" "$QR_PAYLOAD" >> "$tmp"
  done < "$qf"
  mv -f "$tmp" "$qf" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  release_lock "queue:${recipient}" "$lock"
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
  local tmp="${f}.tmp.$$"
  tail -n "$keep" "$f" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
}

log_sent_message() {
  # log_sent_message <id> <from> <to> <type> <delivery> <excerpt-source>
  local id="$1" from="$2" to="$3" type="$4" delivery="$5"
  local excerpt
  excerpt=$(log_excerpt "$6")
  ensure_messages_dir || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(now_ms)" "$id" "$from" "$to" "$type" "$delivery" "$excerpt" >> "$(sent_log_file)" 2>/dev/null || true
  trim_log_file "$(sent_log_file)"
  archive_message "out" "$to" "$type" "$id" "$6"
}

# Validate a reply-to message id and return the message carrying a single
# leading [re:ID] correlation token. The id charset (8-16 lowercase hex) is
# exactly what log_reply_ids correlates, so a token this produces is always
# matchable. Idempotent: if the message already contains the exact [re:ID]
# token, it is returned unchanged — the token must appear exactly once (a doubled
# literal token is noise even though log_reply_ids dedupes by id). Prints the
# (possibly-prefixed) message on stdout; on a malformed id prints an error to
# stderr and returns 1 WITHOUT printing a message, so callers can fail closed.
apply_reply_to() {
  local id="$1" message="$2"
  if ! printf '%s' "$id" | grep -qE '^[a-f0-9]{8,16}$'; then
    echo "ERROR: --reply-to expects an 8-16 char lowercase hex message id (got '$id')." >&2
    return 1
  fi
  # Inspect correlation tokens already present. A token for a DIFFERENT id is a
  # conflict — a single reply cannot correlate to two different messages, so
  # refuse rather than silently pick one. Tokens for the SAME id (however many,
  # wherever placed) are collapsed to exactly one leading token below.
  local existing other
  existing=$(printf '%s' "$message" | grep -oE '\[re:[a-f0-9]{8,16}\]' 2>/dev/null | sort -u)
  other=$(printf '%s\n' "$existing" | grep -vxF "[re:$id]" | sed '/^$/d')
  if [ -n "$other" ]; then
    echo "ERROR: message already carries a conflicting correlation token ($(printf '%s' "$other" | tr '\n' ' ')); refusing to add [re:$id]." >&2
    return 1
  fi
  # Strip every existing [re:$id] token (and any spaces trailing it), then
  # prepend exactly one leading token. ($id is validated hex, so the sed pattern
  # carries no metacharacters, and the message is sed INPUT, never the pattern.)
  local stripped
  stripped=$(printf '%s' "$message" | sed "s/\[re:$id\] *//g")
  printf '[re:%s] %s' "$id" "$stripped"
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
  printf '%s' "$text" | grep -oE '\[re:[a-f0-9]{8,16}\]' 2>/dev/null | sed 's/^\[re://; s/\]$//' | sort -u | \
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf '%s\t%s\t%s\n' "$(now_ms)" "$id" "$from" >> "$rf" 2>/dev/null || true
  done
  trim_log_file "$rf"
}

log_reply_ids_from_file() {
  # log_reply_ids_from_file <from> <file> — correlate [re:<id>] tokens carried in
  # a dispatched task body. Dispatch queue rows store only the file path (not the
  # body), so live AND queued dispatch replies are correlated by scanning a
  # bounded prefix of the file here. The caller MUST have already validated the
  # file as trusted (trusted_message_file) before calling this — we read its
  # contents, so an untrusted/symlinked path must never reach it.
  #
  # Only a bounded prefix is scanned: --reply-to prepends [re:<id>] at the very
  # top, so a small prefix always suffices, and bounding the read caps cost and
  # blast radius for a large or hostile body. Override with the byte budget
  # SESSION_CHAT_REPLY_SCAN_BYTES (default 4096).
  local from="$1" file="$2"
  [ -n "$from" ] || return 0
  [ -f "$file" ] || return 0
  local bytes prefix
  bytes=$(normalize_positive_int "${SESSION_CHAT_REPLY_SCAN_BYTES:-4096}" 4096)
  prefix=$(head -c "$bytes" "$file" 2>/dev/null) || return 0
  [ -n "$prefix" ] || return 0
  log_reply_ids "$from" "$prefix"
}

# --- Message archive (search) ---
# Daily TSVs under $MESSAGES_DIR/archive/<YYYY-MM-DD>.tsv:
#   <ts_ms>\t<direction in|out>\t<peer>\t<type>\t<id>\t<excerpt 200ch>
# Written best-effort on every send and on every surfaced incoming message;
# /message-search greps these (plus dispatch file bodies). Files older than
# the retention window are pruned opportunistically on append.

archive_retention_days() {
  normalize_positive_int "${SESSION_CHAT_ARCHIVE_RETENTION_DAYS:-30}" 30
}

archive_message() {
  # archive_message <direction> <peer> <type> <id> <text>
  local direction="$1" peer="$2" type="$3" id="$4" text="$5"
  local dir day f
  # Fail closed: never create the archive under an unsafe (symlink/unowned)
  # messages root. Archiving is best-effort, so just skip on refusal.
  ensure_messages_dir || return 0
  dir="$MESSAGES_DIR/archive"
  mkdir -p "$dir" 2>/dev/null || return 0
  day=$(date +%Y-%m-%d 2>/dev/null) || return 0
  f="$dir/${day}.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(now_ms)" "$direction" "$peer" "$type" "$id" \
    "$(printf '%s' "$text" | tr '\t\n\r' '   ' | cut -c1-200)" >> "$f" 2>/dev/null || true
  find "$dir" -name '*.tsv' -type f -mtime +"$(archive_retention_days)" -delete 2>/dev/null || true
}

# --- Communication ---

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

# Single paste→verify→Enter attempt. On verify failure, clear any partial
# paste and return 1 (no error message — caller decides whether to retry).
_send_text_attempt() {
  local pane_id="$1"
  local text="$2"
  local marker="$3"
  local paste_placeholders_before=0
  if [ "${SESSION_CHAT_SKIP_VERIFY:-0}" != "1" ]; then
    paste_placeholders_before=$(capture_paste_placeholder_count "$pane_id")
  fi
  # A failed paste is RETRYABLE (return 2): clear any partial staging first so
  # the retry starts from a clean composer rather than duplicating text.
  if ! tmux send-keys -t "$pane_id" -l -- "$text"; then
    clear_partial_input "$pane_id"
    return 2
  fi
  if [ "${SESSION_CHAT_SKIP_VERIFY:-0}" != "1" ]; then
    local timeout_ms="${SESSION_CHAT_VERIFY_TIMEOUT_MS:-4000}"
    if [ -z "$marker" ]; then
      marker="${text: -40}"
    fi
    local elapsed=0
    local landed=0
    while [ "$elapsed" -lt "$timeout_ms" ]; do
      local captured
      captured=$(tmux capture-pane -t "$pane_id" -p -S -200 2>/dev/null || true)
      if printf '%s\n' "$captured" | grep -qF -- "$marker"; then
        landed=1
        break
      fi
      if [ "$(printf '%s\n' "$captured" | count_paste_placeholders)" -gt "$paste_placeholders_before" ]; then
        landed=1
        break
      fi
      sleep 0.05
      elapsed=$((elapsed + 50))
    done
    if [ "$landed" -ne 1 ]; then
      # Verify timeout — RETRYABLE (return 2). Clear the partial paste so a
      # retry (or the caller's give-up) doesn't leave staged text behind.
      clear_partial_input "$pane_id"
      return 2
    fi
  fi
  # Enter is the SUBMIT. If it fails, the text is staged but never sent — this
  # is NON-retryable (return 1): retrying the whole paste would duplicate text
  # in the composer. The caller must treat this as a failed live send and leave
  # the durable copy queued, never dequeue it. Best-effort clear the staged text.
  if ! tmux send-keys -t "$pane_id" Enter; then
    clear_partial_input "$pane_id"
    return 1
  fi
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

  local retries backoff_ms
  retries=$(normalize_positive_int "${SESSION_CHAT_SEND_RETRIES:-2}" 2)
  backoff_ms=$(normalize_positive_int "${SESSION_CHAT_RETRY_BACKOFF_MS:-200}" 200)
  local attempt=0
  local status=0
  while :; do
    _send_text_attempt "$pane_id" "$text" "$marker"
    status=$?
    if [ "$status" -eq 0 ]; then
      release_lock "$pane_id"
      return 0
    fi
    # status 1 = non-retryable submit (Enter) failure — bail now so the caller
    # keeps the durable copy queued. Only status 2 (paste fail / verify timeout)
    # is retryable.
    if [ "$status" -ne 2 ]; then
      release_lock "$pane_id"
      return "$status"
    fi
    if [ "$attempt" -ge "$retries" ]; then
      release_lock "$pane_id"
      local timeout_ms="${SESSION_CHAT_VERIFY_TIMEOUT_MS:-4000}"
      echo "ERROR: send to ${pane_id} did not land within ${timeout_ms}ms after $((retries + 1)) attempts; recipient input cleared. Recipient may be busy or in an approval gate." >&2
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
  local my_name tmux_err
  my_name=$(get_my_name)
  tmux_err=$(pop_pane_name_err)
  if [ -z "$my_name" ]; then
    echo "ERROR: This pane has no name. Run /whoami <name> first.$(pane_name_err_detail "$tmux_err")" >&2
    return 1
  fi
  # The sender name is written raw into the dispatch file name and durable
  # records; refuse an externally/manually-set @name with path metacharacters
  # before any write, so a hostile @name (slashes, ..) can't steer a file path.
  if ! validate_label "$my_name" 2>/dev/null; then
    echo "ERROR: this pane's name ('$my_name') has unsafe characters; rename it with /whoami <name> (letters, digits, _, - only) before sending." >&2
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
  ensure_agent_target "$target_name" "$target_pane" || return 1
  # Durable rows land in the recipient runtime's dir so a Codex target drains
  # them on its next turn (Codex hooks read ~/.codex/messages, not ~/.claude).
  local target_messages_dir
  target_messages_dir=$(target_messages_dir_for_pane "$target_pane")
  local uid
  uid=$(generate_id)
  # Durable copy first so a busy/failed paste is never a lost message.
  if ! enqueue_message "$target_name" "$uid" "send" "$my_name" "$message" "$target_messages_dir"; then
    echo "ERROR: cannot queue message — recipient messages dir is unsafe (symlink/unowned) or unavailable: $target_messages_dir" >&2
    return 1
  fi
  local formatted="[from:${my_name} pane:${TMUX_PANE} id:${uid}] ${message} [id:${uid}]"
  if send_text "$target_pane" "$formatted" "id:${uid}"; then
    dequeue_message_id "$target_name" "$uid" "$target_messages_dir"
    log_sent_message "$uid" "$my_name" "$target_name" "send" "live" "$message"
    return 0
  fi
  # Live paste failed; surface from the inbox on the recipient's next turn now.
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
    echo "ERROR: This pane has no name. Run /whoami <name> first.$(pane_name_err_detail "$tmux_err")" >&2
    return 1
  fi
  # The sender name is written raw into the dispatch file name and durable
  # records; refuse an externally/manually-set @name with path metacharacters
  # before any write, so a hostile @name (slashes, ..) can't steer a file path.
  if ! validate_label "$my_name" 2>/dev/null; then
    echo "ERROR: this pane's name ('$my_name') has unsafe characters; rename it with /whoami <name> (letters, digits, _, - only) before sending." >&2
    return 1
  fi
  local target_pane
  target_pane=$(resolve_pane "$target_name") || return 1
  ensure_agent_target "$target_name" "$target_pane" || return 1
  # Resolve the recipient runtime's trusted dir: the task file must live where
  # that pane's hook will trust + read it (each runtime trusts only its own).
  local target_messages_dir
  target_messages_dir=$(target_messages_dir_for_pane "$target_pane")

  # Write full message to file (handles multi-line + special chars)
  # Fail closed: refuse to write the task file into an unsafe recipient dir.
  if ! ensure_messages_dir "$target_messages_dir"; then
    echo "ERROR: recipient messages dir is unsafe (symlink/unowned) or unavailable: $target_messages_dir" >&2
    return 1
  fi
  local uid
  uid=$(generate_id)
  # PID + uid prevents same-second / same-target collisions overwriting files.
  local msg_id
  msg_id="$(date +%s)-$$-${uid}-${my_name}-to-${target_name}"
  local msg_file="$target_messages_dir/${msg_id}.md"
  cat > "$msg_file" <<EOF
$message
EOF
  # umask 077 already yields 0600, but assert it explicitly: this file holds the
  # full task body and the recipient's trust gate rejects anything not owner-only.
  chmod 600 "$msg_file" 2>/dev/null || true
  local line_count
  line_count=$(printf '%s\n' "$message" | wc -l | tr -d ' ')
  # Durable copy first (points at the task file), then the live nudge.
  enqueue_message "$target_name" "$uid" "dispatch" "$my_name" "$msg_file" "$target_messages_dir" || return 1
  # Notification line: no truncated preview. Recipient hook + receiver agent
  # are responsible for reading $msg_file. The 'id:' field is the verify marker.
  # A reply's [re:<id>] token lives at the top of the task file, not here — the
  # recipient correlates it by scanning a bounded prefix of the trusted file
  # (see log_reply_ids_from_file / detect-incoming-message.sh), which covers both
  # live and queued dispatches uniformly.
  if send_text "$target_pane" \
    "[from:${my_name} pane:${TMUX_PANE} msg:${msg_file} id:${uid}] dispatch (${line_count} lines) — read msg file for full task id:${uid}" \
    "id:${uid}"; then
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
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}
