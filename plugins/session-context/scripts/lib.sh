#!/usr/bin/env bash
# lib.sh — Shared functions for session-context plugin
# Source this file: source "$(dirname "$0")/lib.sh"
# Supported platforms: macOS, Linux

# Context snapshots and their archived history hold private handoff content, so
# keep everything owner-only. umask 077 makes new files 0600 / dirs 0700
# (process-local: the /context-* commands run these scripts as subprocesses, so
# it never tightens the user's interactive umask). Auto-context handoffs written
# by session-scheduler are 0400 and are preserved as-is by harden_existing_contexts_dir.
umask 077

# --- tmux checks ---

ensure_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "ERROR: tmux is required to share context with another session." >&2
    echo "Install with: brew install tmux (macOS) or apt install tmux (Ubuntu)" >&2
    exit 1
  fi
  if [ -z "${TMUX:-}" ]; then
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

_context_path_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

_context_path_uid() {
  # GNU stat accepts -f with different filesystem-report semantics and can
  # emit stdout before rejecting BSD-style operands. Try GNU formatting first;
  # BSD stat rejects -c cleanly and then uses the macOS fallback.
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null
}

_context_path_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

_context_path_identity() {
  stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null
}

_context_store_error() {
  echo "ERROR: Unsafe session context store: $*" >&2
  return 1
}

_context_require_owner() {
  local path="$1" owner="" inspected=0 attempt
  # A cooperative writer may replace the ephemeral lock between stat and the
  # following existence check. Retry that narrow race, but never accept a path
  # whose ownership cannot be observed while it exists.
  attempt=1
  while [ "$attempt" -le 3 ]; do
    if owner=$(_context_path_uid "$path"); then
      inspected=1
      break
    fi
    _context_path_exists "$path" || return 2
    sleep 0.005
    attempt=$((attempt + 1))
  done
  if [ "$inspected" -ne 1 ]; then
    _context_store_error "cannot inspect ownership for $path"
    return 1
  fi
  if [ "$owner" != "$(id -u)" ]; then
    _context_store_error "path is not owned by the current user: $path"
    return 1
  fi
}

_context_harden_directory() {
  local path="$1"
  if ! _context_path_exists "$path"; then
    return 2
  fi
  if [ -L "$path" ]; then
    _context_store_error "symbolic-link directories are not allowed: $path"
    return 1
  fi
  if [ ! -d "$path" ]; then
    _context_store_error "expected a directory: $path"
    return 1
  fi
  _context_require_owner "$path" || return 1
  chmod 700 "$path" 2>/dev/null || {
    _context_path_exists "$path" || return 2
    _context_store_error "cannot set owner-only permissions on directory: $path"
    return 1
  }
}

_context_validate_directory() {
  local path="$1"
  if ! _context_path_exists "$path"; then
    return 2
  fi
  if [ -L "$path" ]; then
    _context_store_error "symbolic-link directories are not allowed: $path"
    return 1
  fi
  if [ ! -d "$path" ]; then
    _context_store_error "expected a directory: $path"
    return 1
  fi
  _context_require_owner "$path"
}

context_safe_file_mode() {
  # Scheduler auto-contexts are intentionally immutable at 0400. Preserve only
  # that exact mode; normalize every other legacy regular file to 0600 so modes
  # such as 0000, 0100, 0500, and 0700 cannot survive merely by ending in 00.
  local path="$1" raw_mode
  raw_mode=$(_context_path_mode "$path") || {
    _context_path_exists "$path" || return 2
    _context_store_error "cannot inspect permissions for $path"
    return 1
  }
  case "$raw_mode" in
    ''|*[!0-7]*)
      _context_store_error "unrecognized permissions '$raw_mode' for $path"
      return 1
      ;;
  esac
  if [ "$raw_mode" = "400" ]; then
    printf '400\n'
  else
    printf '600\n'
  fi
}

ensure_context_regular_file() {
  local path="$1" safe_mode
  if ! _context_path_exists "$path"; then
    return 2
  fi
  if [ -L "$path" ]; then
    _context_store_error "symbolic-link files are not allowed: $path"
    return 1
  fi
  if [ ! -f "$path" ]; then
    _context_store_error "expected a regular file: $path"
    return 1
  fi
  _context_require_owner "$path" || return 1
  safe_mode=$(context_safe_file_mode "$path") || return 1
  chmod "$safe_mode" "$path" || {
    _context_path_exists "$path" || return 2
    _context_store_error "cannot set owner-only permissions on file: $path"
    return 1
  }
}

_context_lock_fingerprint() {
  local lock_dir="$1/.session-context.lock" lock_id pid_id entry_count
  _context_path_exists "$lock_dir" || return 2
  lock_id=$(_context_path_identity "$lock_dir") || return 2
  if _context_path_exists "$lock_dir/pid"; then
    pid_id=$(_context_path_identity "$lock_dir/pid") || return 2
  else
    pid_id="missing"
  fi
  entry_count=$(find -P "$lock_dir" -mindepth 1 -maxdepth 1 -print 2>/dev/null | wc -l | tr -d ' ')
  printf '%s|%s|%s\n' "$lock_id" "$pid_id" "$entry_count"
}

_context_check_lock_generation() {
  local root="$1" lock_dir="$1/.session-context.lock" path relative holder_pid mode
  local -a traversal_status
  _context_path_exists "$lock_dir" || return 2
  if [ -L "$lock_dir" ]; then
    _context_store_error "writer lock cannot be a symbolic link: $lock_dir"
    return 1
  fi
  if [ ! -d "$lock_dir" ]; then
    _context_store_error "writer lock is not a directory: $lock_dir"
    return 1
  fi
  _context_require_owner "$lock_dir" || return 1
  mode=$(_context_path_mode "$lock_dir") || return 2
  if [ "$mode" != "700" ]; then
    _context_store_error "writer lock directory must be mode 700: $lock_dir"
    return 1
  fi

  find -P "$lock_dir" -mindepth 1 -print0 2>/dev/null | while IFS= read -r -d '' path; do
    _context_path_exists "$path" || continue
    relative=${path#"$lock_dir"/}
    if [ "$relative" != "pid" ]; then
      _context_store_error "unexpected file in context store: $path"
      exit 1
    fi
    if [ -L "$path" ] || [ ! -f "$path" ]; then
      _context_path_exists "$path" || continue
      _context_store_error "writer-lock PID must be a regular non-symlink file: $path"
      exit 1
    fi
    _context_require_owner "$path" || exit 1
    mode=$(_context_path_mode "$path") || exit 2
    if [ "$mode" != "600" ]; then
      _context_store_error "writer-lock PID file must be mode 600: $path"
      exit 1
    fi
    holder_pid=$(sed -n '1p' "$path" 2>/dev/null) || holder_pid=""
    # Empty is valid only during the bounded mkdir-to-publish window.
    if [ -n "$holder_pid" ] && ! [[ "$holder_pid" =~ ^[0-9]+$ ]]; then
      _context_store_error "writer lock contains an invalid holder PID: $path"
      exit 1
    fi
  done
  traversal_status=("${PIPESTATUS[@]}")
  if [ "${traversal_status[0]}" -ne 0 ] || [ "${traversal_status[1]}" -ne 0 ]; then
    return 1
  fi
}

_context_validate_lock_artifact() {
  # Lock pathnames are intentionally reused by consecutive writers. Validate a
  # single inode generation twice and discard transient errors when turnover is
  # observed; never chmod a pathname that may already name the next writer.
  local root="$1" lock_dir="$1/.session-context.lock"
  local before after error_output check_status attempt=1
  while [ "$attempt" -le 50 ]; do
    _context_path_exists "$lock_dir" || return 0
    before=$(_context_lock_fingerprint "$root") || {
      sleep 0.002
      attempt=$((attempt + 1))
      continue
    }
    error_output=$(_context_check_lock_generation "$root" 2>&1)
    check_status=$?
    after=$(_context_lock_fingerprint "$root") || {
      _context_path_exists "$lock_dir" || return 0
      sleep 0.002
      attempt=$((attempt + 1))
      continue
    }
    if [ "$before" != "$after" ]; then
      sleep 0.002
      attempt=$((attempt + 1))
      continue
    fi
    if [ "$check_status" -eq 0 ]; then
      return 0
    fi
    [ -n "$error_output" ] && printf '%s\n' "$error_output" >&2
    return 1
  done
  _context_store_error "writer lock did not stabilize after bounded revalidation: $lock_dir"
}

_context_harden_lock_artifact() {
  # Active locks are born 0700 with a 0600 PID. Verification is deliberately
  # read-only so turnover cannot make this process chmod the next generation.
  _context_validate_lock_artifact "$1"
}

_context_validate_tree() {
  # Validate the complete tree before changing any permissions. The store has
  # only one supported nested directory plus an ephemeral writer lock; refusing
  # other directories prevents a misconfigured SESSION_CONTEXT_HOME (such as a
  # repository root) from being recursively chmodded.
  local root="$1" path relative
  local -a traversal_status
  _context_validate_directory "$root" || return 1

  find -P "$root" -mindepth 1 \
    \( -path "$root/.session-context.lock" -o -path "$root/.session-context.lock/*" \) -prune \
    -o -print0 2>/dev/null | while IFS= read -r -d '' path; do
    # A concurrent writer may remove its lock between find(1) and inspection.
    if ! _context_path_exists "$path"; then
      continue
    fi
    relative=${path#"$root"/}
    if [ -L "$path" ]; then
      _context_store_error "nested symbolic links are not allowed: $path"
      exit 1
    elif [ -d "$path" ]; then
      case "$relative" in
        .history) ;;
        *)
          _context_store_error "unexpected nested directory: $path"
          exit 1
          ;;
      esac
      if ! _context_require_owner "$path"; then
        _context_path_exists "$path" || continue
        exit 1
      fi
    elif [ -f "$path" ]; then
      if ! _context_require_owner "$path"; then
        _context_path_exists "$path" || continue
        exit 1
      fi
      if ! [[ "$relative" =~ ^[a-zA-Z0-9_-]+\.md$ ]] \
        && ! [[ "$relative" =~ ^\.history/[a-zA-Z0-9_-]+\.[0-9]{8}-[0-9]{6}Z\.md$ ]] \
        && ! [[ "$relative" =~ ^(\.history/)?\.session-context\.tmp\.[a-zA-Z0-9]+$ ]]; then
        _context_store_error "unexpected file in context store: $path"
        exit 1
      fi
    else
      _context_path_exists "$path" || continue
      _context_store_error "special files are not allowed: $path"
      exit 1
    fi
  done
  traversal_status=("${PIPESTATUS[@]}")
  if [ "${traversal_status[0]}" -ne 0 ] || [ "${traversal_status[1]}" -ne 0 ]; then
    _context_store_error "cannot safely traverse context store: $root"
    return 1
  fi
  _context_validate_lock_artifact "$root"
}

harden_existing_contexts_dir() {
  local root="$1" path
  local -a traversal_status
  if [ -L "$root" ]; then
    _context_store_error "SESSION_CONTEXT_HOME cannot be a symbolic link: $root"
    return 1
  fi
  if [ ! -d "$root" ]; then
    _context_store_error "context store is not a directory: $root"
    return 1
  fi

  # First pass rejects the whole tree without partially migrating it.
  _context_validate_tree "$root" || return 1

  # Second pass performs safe legacy migration. Re-check every entry just
  # before chmod so a concurrent replacement is rejected rather than followed.
  _context_harden_directory "$root" || return 1
  find -P "$root" -mindepth 1 \
    \( -path "$root/.session-context.lock" -o -path "$root/.session-context.lock/*" \) -prune \
    -o -print0 2>/dev/null | while IFS= read -r -d '' path; do
    if ! _context_path_exists "$path"; then
      continue
    fi
    if [ -d "$path" ] && [ ! -L "$path" ]; then
      if ! _context_harden_directory "$path"; then
        _context_path_exists "$path" || continue
        exit 1
      fi
    elif [ -f "$path" ] && [ ! -L "$path" ]; then
      if ! ensure_context_regular_file "$path"; then
        _context_path_exists "$path" || continue
        exit 1
      fi
    else
      _context_path_exists "$path" || continue
      _context_store_error "path changed while securing the store: $path"
      exit 1
    fi
  done
  traversal_status=("${PIPESTATUS[@]}")
  if [ "${traversal_status[0]}" -ne 0 ] || [ "${traversal_status[1]}" -ne 0 ]; then
    _context_store_error "cannot safely migrate context store: $root"
    return 1
  fi
  _context_harden_lock_artifact "$root" || return 1

  (cd "$root" 2>/dev/null && pwd -P) || {
    _context_store_error "cannot resolve context store: $root"
    return 1
  }
}

ensure_contexts_dir() {
  local requested="$1" parent
  while [ "$requested" != "/" ] && [ "${requested%/}" != "$requested" ]; do
    requested=${requested%/}
  done
  if [ -z "$requested" ] || [ "$requested" = "/" ]; then
    _context_store_error "SESSION_CONTEXT_HOME must name a dedicated non-root directory"
    return 1
  fi
  if [ -L "$requested" ]; then
    _context_store_error "SESSION_CONTEXT_HOME cannot be a symbolic link: $requested"
    return 1
  fi

  if ! _context_path_exists "$requested"; then
    parent=$(dirname "$requested")
    mkdir -p "$parent" || {
      _context_store_error "cannot create parent directory: $parent"
      return 1
    }
    # mkdir without -p makes concurrent initialization unambiguous: EEXIST is
    # accepted only after the winner's path is revalidated below.
    if ! mkdir -m 700 "$requested" 2>/dev/null; then
      if [ -L "$requested" ] || [ ! -d "$requested" ]; then
        _context_store_error "context store initialization raced with an unsafe path: $requested"
        return 1
      fi
    fi
  fi

  # Bootstrap only: revalidate the store ROOT as a real, owner-owned, non-symlink
  # directory and echo its canonical path. The whole-tree harden sweep is NOT run
  # here — it must execute while the writer lock is held, because an unlocked sweep
  # races a concurrent save's temp/rename and spuriously fails one of several
  # parallel first-time saves. Writers call bootstrap_contexts_dir then harden
  # under their own lock; get_contexts_dir does bootstrap+lock+harden+release for
  # read callers.
  if [ -L "$requested" ] || [ ! -d "$requested" ]; then
    _context_store_error "context store is not a directory: $requested"
    return 1
  fi
  _context_require_owner "$requested" || return 1
  (cd "$requested" 2>/dev/null && pwd -P) || {
    _context_store_error "cannot resolve context store: $requested"
    return 1
  }
}

_context_pid_alive() {
  local pid="$1"
  if kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  # kill -0 can return EPERM for a live process owned by someone else. ps keeps
  # that case distinct from ESRCH so a lock is reclaimed only for a dead PID.
  ps -p "$pid" -o pid= 2>/dev/null | tr -d '[:space:]' | grep -Fxq "$pid"
}

acquire_context_store_lock() {
  local root="$1" lock_dir="$1/.session-context.lock" pid_file holder_pid stale_dir
  local attempts=0
  while ! mkdir -m 700 "$lock_dir" 2>/dev/null; do
    if [ -L "$lock_dir" ] || { _context_path_exists "$lock_dir" && [ ! -d "$lock_dir" ]; }; then
      _context_store_error "writer lock is not a safe directory: $lock_dir"
      return 1
    fi
    if [ -d "$lock_dir" ]; then
      if ! _context_validate_lock_artifact "$root"; then
        _context_path_exists "$lock_dir" || continue
        return 1
      fi
      pid_file="$lock_dir/pid"
      if ! _context_path_exists "$pid_file"; then
        # The winner may be between mkdir and publishing its PID.
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 250 ]; then
          _context_store_error "writer lock has no inspectable holder PID: $lock_dir"
          return 1
        fi
        sleep 0.02
        continue
      fi
      holder_pid=$(sed -n '1p' "$pid_file" 2>/dev/null) || holder_pid=""
      if ! [[ "$holder_pid" =~ ^[0-9]+$ ]]; then
        if ! _context_path_exists "$lock_dir" || ! _context_path_exists "$pid_file"; then
          continue
        fi
        if [ -z "$holder_pid" ]; then
          attempts=$((attempts + 1))
          if [ "$attempts" -ge 250 ]; then
            _context_store_error "writer lock holder PID remained empty: $pid_file"
            return 1
          fi
          sleep 0.02
          continue
        fi
        _context_store_error "writer lock contains an invalid holder PID: $pid_file"
        return 1
      fi
      if _context_pid_alive "$holder_pid"; then
        : # A live owner keeps the lock; continue the bounded wait below.
      else
        # Move the dead holder's lock out of the store atomically. Competing
        # reclaimers simply lose the rename race and retry against new state.
        stale_dir="${root}.session-context-stale.$$.$attempts"
        if _context_path_exists "$stale_dir"; then
          _context_store_error "stale-lock quarantine path already exists: $stale_dir"
          return 1
        fi
        if mv "$lock_dir" "$stale_dir" 2>/dev/null; then
          if [ -L "$stale_dir" ] || [ ! -d "$stale_dir" ]; then
            _context_store_error "reclaimed writer lock changed type: $stale_dir"
            return 1
          fi
          _context_require_owner "$stale_dir" || return 1
          ensure_context_regular_file "$stale_dir/pid" || return 1
          rm -f "$stale_dir/pid" || return 1
          rmdir "$stale_dir" || return 1
          attempts=0
          continue
        fi
        _context_path_exists "$lock_dir" || continue
      fi
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 250 ]; then
      _context_store_error "timed out waiting for writer lock: $lock_dir"
      return 1
    fi
    sleep 0.02
  done
  CONTEXT_STORE_LOCK_DIR="$lock_dir"
  _context_harden_directory "$lock_dir" || {
    rmdir "$lock_dir" 2>/dev/null || true
    CONTEXT_STORE_LOCK_DIR=""
    return 1
  }
  pid_file="$lock_dir/pid"
  if ! (set -o noclobber; printf '%s\n' "$$" > "$pid_file") 2>/dev/null \
    || ! chmod 600 "$pid_file" \
    || ! ensure_context_regular_file "$pid_file"; then
    rm -f "$pid_file" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
    CONTEXT_STORE_LOCK_DIR=""
    _context_store_error "cannot publish writer-lock holder PID: $pid_file"
    return 1
  fi
}

release_context_store_lock() {
  local lock_dir="${CONTEXT_STORE_LOCK_DIR:-}" pid_file holder_pid
  [ -n "$lock_dir" ] || return 0
  if [ -L "$lock_dir" ] || [ ! -d "$lock_dir" ]; then
    _context_store_error "writer lock changed before release: $lock_dir"
    return 1
  fi
  _context_require_owner "$lock_dir" || return 1
  pid_file="$lock_dir/pid"
  if ! _context_path_exists "$pid_file"; then
    rmdir "$lock_dir" || {
      _context_store_error "cannot release initializing writer lock: $lock_dir"
      return 1
    }
    CONTEXT_STORE_LOCK_DIR=""
    return 0
  fi
  ensure_context_regular_file "$pid_file" || return 1
  holder_pid=$(sed -n '1p' "$pid_file" 2>/dev/null) || holder_pid=""
  if [ "$holder_pid" != "$$" ]; then
    _context_store_error "refusing to release a writer lock held by PID ${holder_pid:-unknown}: $lock_dir"
    return 1
  fi
  rm -f "$pid_file" || {
    _context_store_error "cannot remove writer-lock PID file: $pid_file"
    return 1
  }
  rmdir "$lock_dir" || {
    _context_store_error "cannot release writer lock: $lock_dir"
    return 1
  }
  CONTEXT_STORE_LOCK_DIR=""
}

atomic_copy_context_file() {
  local source="$1" destination="$2" requested_mode="$3"
  local destination_dir temp
  if [ -L "$source" ] || [ ! -f "$source" ]; then
    _context_store_error "copy source is not a regular non-symlink file: $source"
    return 1
  fi
  destination_dir=$(dirname "$destination")
  _context_harden_directory "$destination_dir" || return 1
  temp=$(mktemp "$destination_dir/.session-context.tmp.XXXXXX") || {
    _context_store_error "cannot create an atomic snapshot temporary file"
    return 1
  }
  if ! cp "$source" "$temp" || ! chmod "$requested_mode" "$temp" || ! mv -f "$temp" "$destination"; then
    rm -f "$temp" 2>/dev/null || true
    _context_store_error "cannot atomically save context file: $destination"
    return 1
  fi
}

# Writer entry point: resolve SESSION_CONTEXT_HOME and bootstrap the store ROOT
# only (no harden sweep, no lock). The caller MUST acquire_context_store_lock and
# then run harden_existing_contexts_dir while holding it before mutating the store.
bootstrap_contexts_dir() {
  # SESSION_CONTEXT_HOME must be provided by the caller. The /context-* commands
  # (and the SessionStart hook) export it automatically, resolving
  # <git-root|pwd>/tmp/contexts. Fail closed rather than guessing a location.
  if [ -z "${SESSION_CONTEXT_HOME:-}" ]; then
    echo "ERROR: SESSION_CONTEXT_HOME is not set." >&2
    echo "Run session-context through its /context-* commands (they set it automatically)," >&2
    echo "or export SESSION_CONTEXT_HOME=<dir> before invoking the scripts directly." >&2
    return 1
  fi
  ensure_contexts_dir "$SESSION_CONTEXT_HOME"
}

# Read entry point: bootstrap the root, then acquire the writer lock and run the
# whole-tree harden sweep UNDER the lock (so it never races a concurrent writer's
# temp/rename), release, and echo the canonical store path. The caller's per-file
# read checks run after release — a point-in-time snapshot is not required.
get_contexts_dir() {
  local root harden_rc
  root=$(bootstrap_contexts_dir) || return 1
  acquire_context_store_lock "$root" || return 1
  harden_existing_contexts_dir "$root" >/dev/null
  harden_rc=$?
  if ! release_context_store_lock; then
    return 1
  fi
  if [ "$harden_rc" -ne 0 ]; then
    return 1
  fi
  printf '%s\n' "$root"
}

list_snapshot_names() {
  local snapshots_dir="$1"
  local snapshot found=0
  for snapshot in "$snapshots_dir"/*.md; do
    _context_path_exists "$snapshot" || continue
    ensure_context_regular_file "$snapshot" || return 1
    basename "$snapshot" .md
    found=1
  done
  [ "$found" -eq 1 ] || echo "  (none)"
}


# --- Hardened transport (session-chat) ---
# Sharing prefers session-chat's send-message.sh (locking, paste-verify, retry,
# and a durable inbox so a busy/absent recipient still receives the notice on
# its next turn) over this plugin's own basic send_message (below), which is
# kept only as a fallback when session-chat isn't installed. Locator mirrors the
# session-scheduler resolver: test override, then versioned cache, then sibling.
session_chat_root() {
  if [ -n "${SESSION_CHAT_ROOT_OVERRIDE:-}" ]; then
    printf '%s\n' "$SESSION_CHAT_ROOT_OVERRIDE"
    return 0
  fi
  local versioned
  versioned=$(ls -1 "$HOME/.claude/plugins/cache/girishattri-plugins/session-chat" 2>/dev/null | sort -V | tail -1)
  if [ -n "$versioned" ]; then
    printf '%s/.claude/plugins/cache/girishattri-plugins/session-chat/%s\n' "$HOME" "$versioned"
    return 0
  fi
  local here
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
  if [ -d "$here/session-chat" ]; then
    printf '%s/session-chat\n' "$here"
    return 0
  fi
  return 1
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
  # Both names go into the notification line; reject an unsafe target label or an
  # externally/manually-set @name (slashes, .., whitespace) before sending, so a
  # hostile label can't enter the notification.
  if ! validate_label "$target_name" 2>/dev/null; then
    echo "ERROR: invalid target name '$target_name' (letters, digits, _, - only)." >&2
    return 1
  fi
  if ! validate_label "$my_name" 2>/dev/null; then
    echo "ERROR: this pane's name ('$my_name') has unsafe characters; rename it with /whoami <name> before sharing." >&2
    return 1
  fi
  local target_pane
  target_pane=$(resolve_pane "$target_name") || return 1
  local formatted="[from:${my_name} pane:${TMUX_PANE:-}] ${message}"
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
