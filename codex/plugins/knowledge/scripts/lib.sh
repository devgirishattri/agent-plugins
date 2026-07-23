#!/usr/bin/env bash
# lib.sh — Shared functions for the knowledge plugin's context-store surface
# Knowledge context-store helpers (Codex).
# Source this file: source "$(dirname "$0")/lib.sh"
# Supported platforms: macOS, Linux
set -uo pipefail

# Context snapshots can contain private handoff material. Keep every file this
# plugin creates owner-only even when the invoking shell has a permissive umask.
umask 077

# --- tmux checks ---

ensure_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux is required to share context with another session." >&2
    echo "Install it with: brew install tmux (macOS) or apt install tmux (Ubuntu)." >&2
    exit 1
  fi
  if [ -z "${TMUX:-}" ]; then
    echo "Sharing context with another session needs to run inside tmux." >&2
    echo "Start one with: tmux new -s <name>" >&2
    exit 1
  fi
}

# --- Input validation ---

KNOWLEDGE_CANONICAL_NAME_REGEX='^[a-z0-9]+(_[a-z0-9]+)*$'

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

validate_knowledge_name() {
  local name="$1" label="${2:-Knowledge item name}"
  if [ -z "$name" ]; then
    echo "ERROR: $label cannot be empty." >&2
    return 1
  fi
  if ! [[ "$name" =~ $KNOWLEDGE_CANONICAL_NAME_REGEX ]]; then
    echo "ERROR: $label must be canonical snake_case: lowercase letters/digits separated by single underscores (regex: $KNOWLEDGE_CANONICAL_NAME_REGEX)." >&2
    return 1
  fi
}

validate_context_name() {
  validate_knowledge_name "$1" "Context snapshot name"
}

# --- Message directory ---

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
MESSAGES_DIR="$CODEX_DIR/messages"
SESSION_CONTEXT_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ensure_messages_dir() {
  mkdir -p "$MESSAGES_DIR"
}

# Locate session-chat without pinning a cache version. Prefer explicit test or
# workspace overrides, then a sibling source checkout, then the newest cached
# install from any configured marketplace.
session_chat_root() {
  local candidate cache_base latest_version version_core major minor patch version_key
  local best_candidate="" best_key=""

  for candidate in "${SESSION_CHAT_ROOT_OVERRIDE:-}" "${SESSION_CHAT_PLUGIN_ROOT:-}"; do
    if [ -n "$candidate" ] && [ -f "$candidate/scripts/send-message.sh" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  candidate="$SESSION_CONTEXT_PLUGIN_ROOT/../session-chat"
  if [ -f "$candidate/scripts/send-message.sh" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  for cache_base in "$CODEX_DIR"/plugins/cache/*/session-chat; do
    [ -d "$cache_base" ] || continue
    latest_version=$(find "$cache_base" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null \
      | sort -t. -k1,1n -k2,2n -k3,3n \
      | tail -1)
    candidate="$cache_base/$latest_version"
    [ -n "$latest_version" ] && [ -f "$candidate/scripts/send-message.sh" ] || continue

    version_core="${latest_version%%[-+]*}"
    IFS=. read -r major minor patch <<< "$version_core"
    if [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]]; then
      version_key=$(printf '%010d.%010d.%010d' "$major" "$minor" "$patch")
    else
      version_key="$latest_version"
    fi
    if [ -z "$best_key" ] || [[ "$version_key" > "$best_key" ]]; then
      best_key="$version_key"
      best_candidate="$candidate"
    fi
  done

  if [ -n "$best_candidate" ]; then
    printf '%s\n' "$best_candidate"
    return 0
  fi

  return 1
}

send_context_notification() {
  local target="$1"
  local message="$2"
  local chat_root

  if chat_root=$(session_chat_root); then
    if bash "$chat_root/scripts/send-message.sh" "$target" "$message" >/dev/null; then
      printf 'session-chat\n'
      return 0
    fi
    echo "ERROR: session-chat delivery failed; refusing to bypass its delivery safeguards." >&2
    return 1
  fi

  send_message "$target" "$message" || return 1
  printf 'tmux-fallback\n'
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
  local lock_dir="$1/.knowledge-context.lock" lock_id pid_id reclaim_id entry_count
  _context_path_exists "$lock_dir" || return 2
  lock_id=$(_context_path_identity "$lock_dir") || return 2
  if _context_path_exists "$lock_dir/pid"; then
    pid_id=$(_context_path_identity "$lock_dir/pid") || return 2
  else
    pid_id="missing"
  fi
  if _context_path_exists "$lock_dir/.reclaim"; then
    reclaim_id=$(_context_path_identity "$lock_dir/.reclaim") || return 2
  else
    reclaim_id="missing"
  fi
  entry_count=$(find -P "$lock_dir" -mindepth 1 -maxdepth 1 -print 2>/dev/null | wc -l | tr -d ' ')
  printf '%s|%s|%s|%s\n' "$lock_id" "$pid_id" "$reclaim_id" "$entry_count"
}

_context_check_lock_generation() {
  local root="$1" lock_dir="$1/.knowledge-context.lock" path relative holder_pid mode
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
    case "$relative" in
      pid)
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
        ;;
      .reclaim)
        if [ -L "$path" ] || [ ! -d "$path" ]; then
          _context_path_exists "$path" || continue
          _context_store_error "writer-lock reclaim claim must be a real directory: $path"
          exit 1
        fi
        _context_require_owner "$path" || exit 1
        mode=$(_context_path_mode "$path") || exit 2
        if [ "$mode" != "700" ]; then
          _context_store_error "writer-lock reclaim claim must be mode 700: $path"
          exit 1
        fi
        if [ -n "$(find -P "$path" -mindepth 1 -print -quit 2>/dev/null)" ]; then
          _context_store_error "writer-lock reclaim claim must be empty: $path"
          exit 1
        fi
        ;;
      *)
        _context_store_error "unexpected file in context store: $path"
        exit 1
        ;;
    esac
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
  local root="$1" lock_dir="$1/.knowledge-context.lock"
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
    \( -path "$root/.knowledge-context.lock" -o -path "$root/.knowledge-context.lock/*" \
       -o -path "$root/.knowledge-context-stale.*" \) -prune \
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
      if ! [[ "$relative" =~ ^[a-z0-9]+(_[a-z0-9]+)*\.md$ ]] \
        && ! [[ "$relative" =~ ^\.history/[a-z0-9]+(_[a-z0-9]+)*\.[0-9]{8}-[0-9]{6}(Z|[+-][0-9]{4})\.md$ ]] \
        && ! [[ "$relative" =~ ^(\.history/)?\.knowledge-context\.tmp\.[a-zA-Z0-9]+$ ]]; then
        _context_store_error "unexpected file in context store (snapshot names must be canonical snake_case): $path"
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
  _context_validate_quarantine_artifact "$root" || return 1
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

  # Second pass performs safe legacy mode migration. Re-check every entry just
  # before chmod so a concurrent replacement is rejected rather than followed.
  _context_harden_directory "$root" || return 1
  find -P "$root" -mindepth 1 \
    \( -path "$root/.knowledge-context.lock" -o -path "$root/.knowledge-context.lock/*" \
       -o -path "$root/.knowledge-context-stale.*" \) -prune \
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
  # Under the writer lock, finish dismantling any quarantine abandoned by a
  # process killed mid-teardown (live teardowns keep their own).
  _context_sweep_stale_quarantines "$root" || return 1

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

_context_lock_generation_token() {
  local root="$1" lock_dir="$1/.knowledge-context.lock" pid_file
  local lock_id pid_id holder_pid
  _context_path_exists "$lock_dir" || return 2
  lock_id=$(_context_path_identity "$lock_dir") || return 2
  pid_file="$lock_dir/pid"
  _context_path_exists "$pid_file" || return 2
  pid_id=$(_context_path_identity "$pid_file") || return 2
  holder_pid=$(sed -n '1p' "$pid_file" 2>/dev/null) || return 2
  [[ "$holder_pid" =~ ^[0-9]+$ ]] || return 2
  printf '%s|%s|%s\n' "$lock_id" "$pid_id" "$holder_pid"
}

_context_drop_reclaim_claim() {
  local lock_dir="$1" expected_claim_id="$2" claim_dir="$1/.reclaim"
  local actual_claim_id mode
  _context_path_exists "$claim_dir" || return 0
  if [ -L "$claim_dir" ] || [ ! -d "$claim_dir" ]; then
    _context_store_error "writer-lock reclaim claim changed type: $claim_dir"
    return 1
  fi
  _context_require_owner "$claim_dir" || return 1
  actual_claim_id=$(_context_path_identity "$claim_dir") || return 1
  if [ "$actual_claim_id" != "$expected_claim_id" ]; then
    _context_store_error "writer-lock reclaim claim changed generation: $claim_dir"
    return 1
  fi
  mode=$(_context_path_mode "$claim_dir") || return 1
  if [ "$mode" != "700" ]; then
    _context_store_error "writer-lock reclaim claim must be mode 700: $claim_dir"
    return 1
  fi
  if [ -n "$(find -P "$claim_dir" -mindepth 1 -print -quit 2>/dev/null)" ]; then
    _context_store_error "writer-lock reclaim claim must be empty: $claim_dir"
    return 1
  fi
  rmdir "$claim_dir" || {
    _context_store_error "cannot release writer-lock reclaim claim: $claim_dir"
    return 1
  }
}

_context_quarantine_dir_pid() {
  # In-store quarantine names embed the PID of the process performing the
  # teardown: <root>/.knowledge-context-stale.<pid>. Echo that PID or fail.
  local name
  name=$(basename "$1")
  name=${name#.knowledge-context-stale.}
  [[ "$name" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$name"
}

_context_remove_quarantine_dir() {
  # Bounded teardown of one in-store quarantine: a compliant teardown stage
  # holds at most a stale `pid` file and an empty `.reclaim` claim before the
  # final rmdir, so anything else fails closed. Never recursive, and tolerant
  # of entries vanishing when a concurrent teardown finishes first.
  local stale_dir="$1" entry relative
  _context_path_exists "$stale_dir" || return 0
  if [ -L "$stale_dir" ] || [ ! -d "$stale_dir" ]; then
    _context_store_error "writer-lock quarantine must be a real directory: $stale_dir"
    return 1
  fi
  _context_require_owner "$stale_dir" || return 1
  while IFS= read -r -d '' entry; do
    _context_path_exists "$entry" || continue
    relative=${entry#"$stale_dir"/}
    case "$relative" in
      pid)
        if [ -L "$entry" ] || [ ! -f "$entry" ]; then
          _context_path_exists "$entry" || continue
          _context_store_error "quarantined writer-lock PID must be a regular non-symlink file: $entry"
          return 1
        fi
        _context_require_owner "$entry" || return 1
        rm -f "$entry" || {
          _context_path_exists "$entry" || continue
          _context_store_error "cannot remove quarantined writer-lock PID: $entry"
          return 1
        }
        ;;
      .reclaim)
        if [ -L "$entry" ] || [ ! -d "$entry" ]; then
          _context_path_exists "$entry" || continue
          _context_store_error "quarantined reclaim claim must be a real directory: $entry"
          return 1
        fi
        _context_require_owner "$entry" || return 1
        if [ -n "$(find -P "$entry" -mindepth 1 -print -quit 2>/dev/null)" ]; then
          _context_store_error "quarantined reclaim claim must be empty: $entry"
          return 1
        fi
        rmdir "$entry" 2>/dev/null || {
          _context_path_exists "$entry" || continue
          _context_store_error "cannot remove quarantined reclaim claim: $entry"
          return 1
        }
        ;;
      *)
        _context_store_error "unexpected file in writer-lock quarantine: $entry"
        return 1
        ;;
    esac
  done < <(find -P "$stale_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  rmdir "$stale_dir" 2>/dev/null || {
    _context_path_exists "$stale_dir" || return 0
    _context_store_error "cannot remove writer-lock quarantine: $stale_dir"
    return 1
  }
}

_context_validate_quarantine_artifact() {
  # In-store quarantines are transient: an owner release or dead-lock reclaim
  # renames the validated lock generation to <root>/.knowledge-context-stale.<pid>
  # (a same-directory rename, so an exact-root sandbox with no parent write
  # access can still release) and dismantles it immediately. Validation accepts
  # only the shapes a compliant teardown can produce, tolerates entries
  # vanishing when that teardown completes mid-check, and never mutates a
  # quarantine — a live teardown owner must not have its stage rejected or
  # removed out from under it.
  local root="$1" stale_dir mode entry relative holder_pid
  while IFS= read -r -d '' stale_dir; do
    _context_path_exists "$stale_dir" || continue
    if [ -L "$stale_dir" ]; then
      _context_store_error "writer-lock quarantine cannot be a symbolic link: $stale_dir"
      return 1
    fi
    if [ ! -d "$stale_dir" ]; then
      _context_store_error "writer-lock quarantine must be a directory: $stale_dir"
      return 1
    fi
    if ! _context_quarantine_dir_pid "$stale_dir" >/dev/null; then
      _context_store_error "writer-lock quarantine must embed a numeric reclaimer PID: $stale_dir"
      return 1
    fi
    if ! _context_require_owner "$stale_dir"; then
      _context_path_exists "$stale_dir" || continue
      return 1
    fi
    mode=$(_context_path_mode "$stale_dir") || continue
    if [ "$mode" != "700" ]; then
      _context_store_error "writer-lock quarantine must be mode 700: $stale_dir"
      return 1
    fi
    while IFS= read -r -d '' entry; do
      _context_path_exists "$entry" || continue
      relative=${entry#"$stale_dir"/}
      case "$relative" in
        pid)
          if [ -L "$entry" ] || [ ! -f "$entry" ]; then
            _context_path_exists "$entry" || continue
            _context_store_error "quarantined writer-lock PID must be a regular non-symlink file: $entry"
            return 1
          fi
          if ! _context_require_owner "$entry"; then
            _context_path_exists "$entry" || continue
            return 1
          fi
          mode=$(_context_path_mode "$entry") || continue
          if [ "$mode" != "600" ]; then
            _context_store_error "quarantined writer-lock PID file must be mode 600: $entry"
            return 1
          fi
          holder_pid=$(sed -n '1p' "$entry" 2>/dev/null) || holder_pid=""
          if [ -n "$holder_pid" ] && ! [[ "$holder_pid" =~ ^[0-9]+$ ]]; then
            _context_store_error "quarantined writer lock contains an invalid holder PID: $entry"
            return 1
          fi
          ;;
        .reclaim)
          if [ -L "$entry" ] || [ ! -d "$entry" ]; then
            _context_path_exists "$entry" || continue
            _context_store_error "quarantined reclaim claim must be a real directory: $entry"
            return 1
          fi
          if ! _context_require_owner "$entry"; then
            _context_path_exists "$entry" || continue
            return 1
          fi
          if [ -n "$(find -P "$entry" -mindepth 1 -print -quit 2>/dev/null)" ]; then
            _context_store_error "quarantined reclaim claim must be empty: $entry"
            return 1
          fi
          ;;
        *)
          _context_path_exists "$entry" || continue
          _context_store_error "unexpected file in writer-lock quarantine: $entry"
          return 1
          ;;
      esac
    done < <(find -P "$stale_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  done < <(find -P "$root" -mindepth 1 -maxdepth 1 -name '.knowledge-context-stale.*' -print0 2>/dev/null)
}

_context_sweep_stale_quarantines() {
  # Callers hold the writer lock, so among compliant processes this is the only
  # sweeper. A quarantine whose name-embedded PID is dead was abandoned by a
  # process killed mid-teardown; finish its bounded dismantling. A live
  # embedded PID marks an in-flight teardown that owns its own cleanup.
  local root="$1" stale_dir holder_pid
  while IFS= read -r -d '' stale_dir; do
    _context_path_exists "$stale_dir" || continue
    if ! holder_pid=$(_context_quarantine_dir_pid "$stale_dir"); then
      _context_store_error "writer-lock quarantine must embed a numeric reclaimer PID: $stale_dir"
      return 1
    fi
    if _context_pid_alive "$holder_pid"; then
      continue
    fi
    _context_remove_quarantine_dir "$stale_dir" || return 1
  done < <(find -P "$root" -mindepth 1 -maxdepth 1 -name '.knowledge-context-stale.*' -print0 2>/dev/null)
}

_context_quarantine_lock_generation() {
  local root="$1" expected_token="$2" reclaim_mode="$3"
  local lock_dir="$1/.knowledge-context.lock" claim_dir claim_id current_token
  local expected_lock_id expected_pid_id expected_holder_pid stale_dir actual_id mode
  IFS='|' read -r expected_lock_id expected_pid_id expected_holder_pid <<< "$expected_token"
  if [ -z "$expected_lock_id" ] || [ -z "$expected_pid_id" ] \
    || ! [[ "$expected_holder_pid" =~ ^[0-9]+$ ]]; then
    _context_store_error "invalid writer-lock generation token"
    return 1
  fi

  claim_dir="$lock_dir/.reclaim"
  if ! mkdir -m 700 "$claim_dir" 2>/dev/null; then
    return 2
  fi
  claim_id=$(_context_path_identity "$claim_dir") || {
    _context_store_error "cannot identify writer-lock reclaim claim: $claim_dir"
    return 1
  }
  if ! _context_validate_lock_artifact "$root"; then
    _context_drop_reclaim_claim "$lock_dir" "$claim_id" || return 1
    return 1
  fi
  if ! current_token=$(_context_lock_generation_token "$root"); then
    _context_drop_reclaim_claim "$lock_dir" "$claim_id" || return 1
    return 2
  fi
  if [ "$current_token" != "$expected_token" ]; then
    _context_drop_reclaim_claim "$lock_dir" "$claim_id" || return 1
    return 2
  fi

  case "$reclaim_mode" in
    dead)
      if _context_pid_alive "$expected_holder_pid"; then
        _context_drop_reclaim_claim "$lock_dir" "$claim_id" || return 1
        return 2
      fi
      ;;
    owner)
      if [ "$expected_holder_pid" != "$$" ]; then
        _context_drop_reclaim_claim "$lock_dir" "$claim_id" || return 1
        _context_store_error "refusing to release a writer lock held by PID $expected_holder_pid: $lock_dir"
        return 1
      fi
      ;;
    *)
      _context_drop_reclaim_claim "$lock_dir" "$claim_id" || return 1
      _context_store_error "unknown writer-lock reclaim mode: $reclaim_mode"
      return 1
      ;;
  esac

  # The quarantine lives INSIDE the store: a same-directory rename needs write
  # access only to SESSION_CONTEXT_HOME itself, never to its parent, so an
  # exact-root sandbox (writable contexts/ under an unwritable tmp/) can
  # release and reclaim.
  stale_dir="$root/.knowledge-context-stale.$$"
  if _context_path_exists "$stale_dir"; then
    # $$ names the live teardown owner, and this process fully dismantles each
    # quarantine before minting another, so a survivor at our own name is an
    # orphan from a recycled PID. Dismantle it bounded before reusing the name.
    if ! _context_remove_quarantine_dir "$stale_dir"; then
      _context_drop_reclaim_claim "$lock_dir" "$claim_id" || return 1
      _context_store_error "stale-lock quarantine path already exists: $stale_dir"
      return 1
    fi
  fi
  if ! mv "$lock_dir" "$stale_dir" 2>/dev/null; then
    _context_drop_reclaim_claim "$lock_dir" "$claim_id" || return 1
    _context_path_exists "$lock_dir" || return 2
    _context_store_error "cannot quarantine writer lock: $lock_dir"
    return 1
  fi

  if [ -L "$stale_dir" ] || [ ! -d "$stale_dir" ]; then
    _context_store_error "reclaimed writer lock changed type: $stale_dir"
    return 1
  fi
  _context_require_owner "$stale_dir" || return 1
  actual_id=$(_context_path_identity "$stale_dir") || return 1
  if [ "$actual_id" != "$expected_lock_id" ]; then
    _context_store_error "reclaimed writer lock changed generation: $stale_dir"
    return 1
  fi
  mode=$(_context_path_mode "$stale_dir") || return 1
  [ "$mode" = "700" ] || {
    _context_store_error "reclaimed writer lock must be mode 700: $stale_dir"
    return 1
  }
  actual_id=$(_context_path_identity "$stale_dir/pid") || return 1
  if [ "$actual_id" != "$expected_pid_id" ] \
    || [ "$(sed -n '1p' "$stale_dir/pid" 2>/dev/null)" != "$expected_holder_pid" ]; then
    _context_store_error "reclaimed writer-lock PID changed generation: $stale_dir/pid"
    return 1
  fi
  ensure_context_regular_file "$stale_dir/pid" || return 1
  rm -f "$stale_dir/pid" || return 1
  _context_drop_reclaim_claim "$stale_dir" "$claim_id" || return 1
  rmdir "$stale_dir" || {
    _context_store_error "cannot remove stale writer-lock quarantine: $stale_dir"
    return 1
  }
}

acquire_context_store_lock() {
  local root="$1" lock_dir="$1/.knowledge-context.lock" pid_file holder_pid generation_token
  local attempts=0 reclaim_rc
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
      if ! generation_token=$(_context_lock_generation_token "$root"); then
        _context_path_exists "$lock_dir" || continue
        sleep 0.002
        continue
      fi
      holder_pid=${generation_token##*|}
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
        if _context_quarantine_lock_generation "$root" "$generation_token" dead; then
          attempts=0
          continue
        else
          reclaim_rc=$?
          if [ "$reclaim_rc" -eq 2 ]; then
            attempts=$((attempts + 1))
            if [ "$attempts" -ge 250 ]; then
              _context_store_error "timed out claiming stale writer lock: $lock_dir"
              return 1
            fi
            sleep 0.02
            continue
          fi
          return 1
        fi
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
  if ! CONTEXT_STORE_LOCK_TOKEN=$(_context_lock_generation_token "$root"); then
    rm -f "$pid_file" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
    CONTEXT_STORE_LOCK_DIR=""
    CONTEXT_STORE_LOCK_TOKEN=""
    _context_store_error "cannot record writer-lock generation: $lock_dir"
    return 1
  fi
}

release_context_store_lock() {
  local lock_dir="${CONTEXT_STORE_LOCK_DIR:-}" root expected_token release_rc current_token
  local attempts=0
  [ -n "$lock_dir" ] || return 0
  expected_token="${CONTEXT_STORE_LOCK_TOKEN:-}"
  if [ -z "$expected_token" ]; then
    _context_store_error "writer lock has no recorded generation: $lock_dir"
    return 1
  fi
  root=${lock_dir%/.knowledge-context.lock}
  while :; do
    if _context_quarantine_lock_generation "$root" "$expected_token" owner; then
      break
    else
      release_rc=$?
    fi
    [ "$release_rc" -eq 2 ] || return 1
    if ! current_token=$(_context_lock_generation_token "$root") \
      || [ "$current_token" != "$expected_token" ]; then
      _context_store_error "writer lock changed before release: $lock_dir"
      return 1
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 250 ]; then
      _context_store_error "timed out claiming writer lock for release: $lock_dir"
      return 1
    fi
    sleep 0.02
  done
  CONTEXT_STORE_LOCK_DIR=""
  CONTEXT_STORE_LOCK_TOKEN=""
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
  temp=$(mktemp "$destination_dir/.knowledge-context.tmp.XXXXXX") || {
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
  # SESSION_CONTEXT_HOME must be inherited from the environment this agent
  # process started with (set by the pane/session launcher before the agent
  # starts). The context-* skills and commands never export or derive it. Fail
  # closed rather than guessing a context store.
  if [ -z "${SESSION_CONTEXT_HOME:-}" ]; then
    echo "ERROR: SESSION_CONTEXT_HOME is not set." >&2
    echo "It must be inherited from the environment this agent process started with" >&2
    echo "(set by the pane/session launcher). An already-running agent must not export" >&2
    echo "or derive it — relaunch the pane/session with the correct environment instead." >&2
    echo "(A human invoking the script directly may export the variable in their own" >&2
    echo "parent shell first.)" >&2
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
  validate_label "$label" || return 1
  result=$(tmux list-panes -a -F '#{pane_id} #{@name}' 2>/dev/null | while read -r pid pname; do
    if [ "$pname" = "$label" ]; then
      echo "$pid"
      break
    fi
  done)
  if [ -z "$result" ]; then
    echo "ERROR: No pane named '$label'. Run \$session-chat:panes to see available." >&2
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
  validate_label "$target_name" || return 1
  my_name=$(get_my_name)
  if [ -z "$my_name" ]; then
    echo "ERROR: This pane has no name. Run \$session-chat:whoami <name> first." >&2
    return 1
  fi
  validate_label "$my_name" || return 1
  local target_pane
  target_pane=$(resolve_pane "$target_name") || return 1
  local formatted="[from:${my_name} pane:${TMUX_PANE:-}] ${message}"
  send_text "$target_pane" "$formatted"
}

dispatch_message() {
  local target_name="$1"
  local message="$2"
  local my_name
  validate_label "$target_name" || return 1
  my_name=$(get_my_name)
  if [ -z "$my_name" ]; then
    echo "ERROR: This pane has no name. Run \$session-chat:whoami <name> first." >&2
    return 1
  fi
  validate_label "$my_name" || return 1
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
  send_text "$target_pane" "[from:${my_name} pane:${TMUX_PANE:-} msg:${msg_file}] ${preview}"
}

read_pane() {
  local pane_id="$1"
  local lines="${2:-50}"
  tmux capture-pane -t "$pane_id" -p | tail -"$lines"
}

# Resolve the configured IANA timezone and fail closed on typos instead of
# letting libc silently fall back to UTC.
agent_plugins_timezone() {
  local timezone="${AGENT_PLUGINS_TIME_ZONE:-Asia/Kolkata}" root
  case "$timezone" in
    ""|/*|*..*|*[!A-Za-z0-9_+./-]*)
      _context_store_error "AGENT_PLUGINS_TIME_ZONE must be a valid IANA timezone, got '$timezone'"
      return 1
      ;;
  esac
  for root in /usr/share/zoneinfo /usr/share/lib/zoneinfo /usr/lib/zoneinfo; do
    [ -f "$root/$timezone" ] && { printf '%s\n' "$timezone"; return 0; }
  done
  _context_store_error "unknown IANA timezone in AGENT_PLUGINS_TIME_ZONE: '$timezone'"
  return 1
}

# Convert a history filename stamp to epoch seconds. New stamps carry a numeric
# offset; legacy stamps end in Z. This makes history ordering correct across
# negative offsets, DST changes, and configuration changes.
context_archive_timestamp_to_epoch() {
  local stamp="$1" zone iso epoch=""
  case "$stamp" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]Z)
      epoch=$(date -j -u -f "%Y%m%d-%H%M%SZ" "$stamp" +%s 2>/dev/null) ||
        epoch=$(date -u -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2} UTC" +%s 2>/dev/null) ||
        return 1
      ;;
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9][+-][0-9][0-9][0-9][0-9])
      epoch=$(date -j -f "%Y%m%d-%H%M%S%z" "$stamp" +%s 2>/dev/null) || {
        zone="${stamp:15:5}"
        iso="${stamp:0:4}-${stamp:4:2}-${stamp:6:2}T${stamp:9:2}:${stamp:11:2}:${stamp:13:2}${zone:0:3}:${zone:3:2}"
        epoch=$(date -d "$iso" +%s 2>/dev/null) || return 1
      }
      ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$epoch"
}

context_history_versions() {
  local project_name="$1" history_dir="$2" file base stamp epoch
  for file in "$history_dir/${project_name}."*.md; do
    [ -f "$file" ] || continue
    base=$(basename "$file" .md)
    stamp=${base#"${project_name}".}
    epoch=$(context_archive_timestamp_to_epoch "$stamp") || epoch=0
    printf '%s\t%s\n' "$epoch" "$file"
  done | sort -t $'\t' -k1,1nr -k2,2r | cut -f2-
}

# ============================================================================
# Memory-store kernel (Phase B1, single-writer contract).
# Shared by memory-lint.sh, memory-index.sh,
# memory-write.sh, and init.sh. Provider-neutral: identical on the Codex
# mirror's copy of this file. Deliberately independent of the context-store
# helpers above (`.agents/memory/` is its own store class, never one of the
# context/session-chat coordination roots).
# ============================================================================

# --- generic stat/pid helpers (filesystem-generic; reused from the
# context-store section above, which despite its naming is not context-
# specific in implementation) ---
km_path_exists() { _context_path_exists "$1"; }
km_path_uid() { _context_path_uid "$1"; }
km_path_mode() { _context_path_mode "$1"; }
km_path_identity() { _context_path_identity "$1"; }
km_pid_alive() { _context_pid_alive "$1"; }

km_link_count() {
  stat -c '%h' "$1" 2>/dev/null || stat -f '%l' "$1" 2>/dev/null
}

km_error() {
  echo "ERROR: $*" >&2
  return 1
}

# --- canonical UTC timestamp profile: YYYY-MM-DDTHH:MM:SSZ ---
km_now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# --- sha256 (macOS: shasum -a 256; portable fallback: sha256sum) ---
km_sha256_file() {
  local f="$1"
  if [ ! -f "$f" ] || [ -L "$f" ]; then
    return 1
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

km_sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# 32 lowercase hex chars from OS entropy (used for lock nonces and generation
# scoping). od is available on every supported platform; openssl is a backup.
km_random_hex32() {
  if command -v od >/dev/null 2>&1; then
    od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
  elif command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16 2>/dev/null
  else
    return 1
  fi
}

# --- repo-root / containment ---

# km_git_ancestor [dir]
# Prints the nearest ancestor of dir (default: CWD) containing .git (dir or
# file); returns 1 if none exists all the way to /.
km_git_ancestor() {
  local dir="${1:-$(pwd -P)}"
  case "$dir" in
    /*) : ;;
    *) dir="$(pwd -P)/$dir" ;;
  esac
  while :; do
    if [ -e "$dir/.git" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    [ "$dir" = "/" ] && return 1
    dir=$(dirname "$dir")
  done
}

km_repo_root() {
  km_git_ancestor "$(pwd -P)"
}

# --- canonical MEMORY-store discovery: the ONLY probed location is
# <repo-root>/.agents/memory/. ---
km_canonical_discovery() {
  local repo_root base d name
  local -a candidates=()
  repo_root=$(km_repo_root) || {
    km_error "no .git ancestor found from $(pwd -P); not inside a git repository"
    return 3
  }
  base="$repo_root/.agents/memory"
  if [ -f "$base/MEMORY.md" ] && [ ! -L "$base/MEMORY.md" ]; then
    printf '%s\n' "$base"
    return 0
  fi
  if [ -d "$base" ] && [ ! -L "$base" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      name=$(basename "$d")
      case "$name" in .*) continue ;; esac
      if [ -f "$d/MEMORY.md" ] && [ ! -L "$d/MEMORY.md" ]; then
        candidates+=("$d")
      fi
    done < <(find "$base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort)
  fi
  case "${#candidates[@]}" in
    1)
      printf '%s\n' "${candidates[0]}"
      return 0
      ;;
    0)
      km_error "no memory store found under $base; run /knowledge:init (Claude) or \$knowledge:init (Codex)"
      return 3
      ;;
    *)
      km_error "ambiguous memory store — multiple candidates under $base:"
      printf '  %s\n' "${candidates[@]}" >&2
      return 3
      ;;
  esac
}

# km_validate_store_dir <store>
# Store-hardening checks common to every resolution source (explicit target,
# KNOWLEDGE_MEMORY_HOME, canonical discovery): the store must be an owned,
# real (non-symlink) directory, and its MEMORY.md an owned, regular,
# non-symlink file. Returns 3 for "not found / not initialized" (resolution
# failure — no fallback), 4 for a genuine safety violation (integrity).
km_validate_store_dir() {
  local store="$1" owner mfile
  if [ -z "$store" ]; then
    km_error "empty memory store path"
    return 2
  fi
  if [ ! -e "$store" ] && [ ! -L "$store" ]; then
    km_error "memory store does not exist: $store"
    return 3
  fi
  if [ -L "$store" ]; then
    km_error "memory store path is a symlink (unsafe): $store"
    return 4
  fi
  if [ ! -d "$store" ]; then
    km_error "memory store path is not a directory: $store"
    return 4
  fi
  owner=$(km_path_uid "$store") || { km_error "cannot inspect memory store ownership: $store"; return 4; }
  if [ "$owner" != "$(id -u)" ]; then
    km_error "memory store is not owned by the current user: $store"
    return 4
  fi
  mfile="$store/MEMORY.md"
  if [ ! -e "$mfile" ] && [ ! -L "$mfile" ]; then
    km_error "memory store has no MEMORY.md (not initialized?): $store"
    return 3
  fi
  if [ -L "$mfile" ]; then
    km_error "MEMORY.md is a symlink (unsafe): $mfile"
    return 4
  fi
  if [ ! -f "$mfile" ]; then
    km_error "MEMORY.md is not a regular file: $mfile"
    return 4
  fi
  owner=$(km_path_uid "$mfile") || { km_error "cannot inspect MEMORY.md ownership: $mfile"; return 4; }
  if [ "$owner" != "$(id -u)" ]; then
    km_error "MEMORY.md is not owned by the current user: $mfile"
    return 4
  fi
  return 0
}

# km_resolve_store [explicit_target]
# THE one memory-store resolver, used by every memory-store command.
# Precedence: explicit target > KNOWLEDGE_MEMORY_HOME > canonical discovery.
# Prints the resolved, canonicalized (symlink-free, absolute) store path on
# stdout. Exit domain: 0 ok; 3 resolution failure (not found / ambiguous /
# out-of-repo); 4 store-integrity failure (symlink/foreign-owner/etc).
km_resolve_store() {
  local explicit="${1:-}" store="" resolved
  if [ -n "$explicit" ]; then
    store="$explicit"
  elif [ -n "${KNOWLEDGE_MEMORY_HOME:-}" ]; then
    store="$KNOWLEDGE_MEMORY_HOME"
  else
    store=$(km_canonical_discovery) || return $?
  fi
  km_validate_store_dir "$store" || return $?
  resolved=$(cd "$store" 2>/dev/null && pwd -P) || {
    km_error "cannot resolve memory store path: $store"
    return 3
  }
  if ! km_git_ancestor "$resolved" >/dev/null; then
    km_error "memory store is not inside a git repository (unsupported in v1): $resolved"
    return 3
  fi
  printf '%s\n' "$resolved"
}

# --- authoritative-file scanner boundary (normative for every read path) ---
# km_authoritative_files <store>
# Prints one bare basename per line (C-locale sorted): regular, non-symlink
# *.md files directly in the store root, excluding MEMORY.md. No recursion —
# excludes .inbox/**, lock/journal/temp paths, and any nested child store by
# construction.
km_authoritative_files() {
  local store="$1" f name
  find "$store" -mindepth 1 -maxdepth 1 -name '*.md' 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    name=$(basename "$f")
    [ "$name" = "MEMORY.md" ] && continue
    [ -L "$f" ] && continue
    [ -f "$f" ] || continue
    printf '%s\n' "$name"
  done
}

# km_symlinked_md_files <store>
# Companion to the scanner boundary: symlinked *.md files directly in the
# store root (excluded from the authoritative set, reported by callers as a
# store-integrity finding).
km_symlinked_md_files() {
  local store="$1" f name
  find "$store" -mindepth 1 -maxdepth 1 -name '*.md' 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    name=$(basename "$f")
    [ "$name" = "MEMORY.md" ] && continue
    [ -L "$f" ] && printf '%s\n' "$name"
  done
}

# --- slug normalization (one shared resolver; mandatory semantics) ---
KM_SLUG_REGEX="$KNOWLEDGE_CANONICAL_NAME_REGEX"

km_is_valid_slug() {
  [[ "$1" =~ $KM_SLUG_REGEX ]]
}

km_stem_of() {
  local base
  base=$(basename "$1")
  printf '%s\n' "${base%.md}"
}

km_normalize_slug() {
  printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]' | tr '-' '_'
}

# km_slug_collision_pairs <store>
# Collision preflight core: prints one "stemA.md<TAB>stemB.md" line per
# colliding pair to stdout (C-locale pair order by scan order); returns 4 if
# any collision was found, 0 otherwise. Read-tool callers (lint, index)
# consume this directly; km_slug_collision_check (below) wraps it for
# writer-style stderr diagnostics.
km_slug_collision_pairs() {
  local store="$1" stem
  local -a stems=() norms=()
  local i j found=0
  while IFS= read -r stem; do
    [ -n "$stem" ] || continue
    stems+=("${stem%.md}")
  done < <(km_authoritative_files "$store")
  for ((i = 0; i < ${#stems[@]}; i++)); do
    norms[i]=$(km_normalize_slug "${stems[i]}")
  done
  for ((i = 0; i < ${#stems[@]}; i++)); do
    for ((j = i + 1; j < ${#stems[@]}; j++)); do
      if [ "${norms[i]}" = "${norms[j]}" ] && [ "${stems[i]}" != "${stems[j]}" ]; then
        printf '%s.md\t%s.md\n' "${stems[i]}" "${stems[j]}"
        found=1
      fi
    done
  done
  [ "$found" -eq 0 ] || return 4
  return 0
}

# km_slug_collision_check <store>
# Collision preflight: every tool must run this before any slug lookup. Any
# two distinct authoritative stems that normalize to the same key is a
# store-integrity ERROR (exit 4) for the whole invocation. Prints one
# "slug collision: stemA.md <-> stemB.md" line per pair to stderr (writer
# convention; read tools use km_slug_collision_pairs directly instead).
km_slug_collision_check() {
  local store="$1" a b found=0
  while IFS=$'\t' read -r a b; do
    [ -n "$a" ] || continue
    echo "slug collision: $a <-> $b" >&2
    found=1
  done < <(km_slug_collision_pairs "$store")
  [ "$found" -eq 0 ] || return 4
  return 0
}

# km_resolve_slug <store> <link>
# Resolution order: (1) exact filename-stem match; (2) only if that fails,
# normalized lookup succeeding ONLY when exactly one real stem maps to the
# normalized key. Prints the resolved stem and sets KM_RESOLVE_KIND to
# exact|drift; on failure sets KM_RESOLVE_KIND=dangling and returns 1. Callers
# MUST run km_slug_collision_check first (this function does not re-check).
km_resolve_slug() {
  local store="$1" link="$2" stem norm_link
  local -a stems=() matches=()
  local si
  while IFS= read -r stem; do
    stems+=("${stem%.md}")
  done < <(km_authoritative_files "$store")
  for ((si = 0; si < ${#stems[@]}; si++)); do
    if [ "${stems[si]}" = "$link" ]; then
      printf '%s\n' "${stems[si]}"
      # shellcheck disable=SC2034  # documented out-param for callers
      KM_RESOLVE_KIND=exact
      return 0
    fi
  done
  norm_link=$(km_normalize_slug "$link")
  for ((si = 0; si < ${#stems[@]}; si++)); do
    if [ "$(km_normalize_slug "${stems[si]}")" = "$norm_link" ]; then
      matches+=("${stems[si]}")
    fi
  done
  if [ "${#matches[@]}" -eq 1 ]; then
    printf '%s\n' "${matches[0]}"
    # shellcheck disable=SC2034  # documented out-param for callers
    KM_RESOLVE_KIND=drift
    return 0
  fi
  # shellcheck disable=SC2034  # documented out-param for callers
  KM_RESOLVE_KIND=dangling
  return 1
}

# --- role detection (plugin-neutral contract; shared with docs-write.sh,
# which implements the identical algorithm inline for its own single-command
# surface). First non-empty source wins. ---
km_resolve_pane_name() {
  if [ -n "${KNOWLEDGE_PANE_NAME:-}" ]; then
    printf '%s\n' "$KNOWLEDGE_PANE_NAME"
    return 0
  fi
  if [ -n "${SESSION_CHAT_PANE_NAME:-}" ]; then
    printf '%s\n' "$SESSION_CHAT_PANE_NAME"
    return 0
  fi
  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    local tmux_name
    tmux_name=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@name}' 2>/dev/null) || tmux_name=""
    if [ -n "$tmux_name" ]; then
      printf '%s\n' "$tmux_name"
      return 0
    fi
  fi
  return 1
}

# km_require_non_reviewer [surface-label]
# Returns 0 if writes are authorized for this pane/role; returns 6 and prints
# the single stderr reason line otherwise. surface-label defaults to "memory".
km_require_non_reviewer() {
  local surface="${1:-memory}" pane_name=""
  if pane_name=$(km_resolve_pane_name); then
    case "$pane_name" in
      *-reviewer)
        echo "reviewer role: ${surface} writes refused" >&2
        return 6
        ;;
      *)
        return 0
        ;;
    esac
  fi
  if [ -n "${TMUX:-}" ]; then
    echo "unresolved pane identity: set KNOWLEDGE_PANE_NAME" >&2
    return 6
  fi
  return 0
}

# --- recovery mutex (OS-held, kernel-released on process death) ---
# km_prepare_recovery_flock_path <path>
# The .recovery.flock file is created 0600 inside the store; a pre-existing
# symlink or foreign-owner file refuses (exit 4), and so does an owned
# regular file at any mode other than 0600 (fail closed; never mutates modes
# itself — prints the exact chmod to run).
km_prepare_recovery_flock_path() {
  local path="$1" owner mode
  if [ -L "$path" ]; then
    km_error "recovery mutex path is a symlink (unsafe): $path"
    return 4
  fi
  if [ -e "$path" ]; then
    if [ ! -f "$path" ]; then
      km_error "recovery mutex path is not a regular file: $path"
      return 4
    fi
    owner=$(km_path_uid "$path") || { km_error "cannot inspect recovery mutex ownership: $path"; return 4; }
    if [ "$owner" != "$(id -u)" ]; then
      km_error "recovery mutex path has a foreign owner: $path"
      return 4
    fi
    mode=$(km_path_mode "$path") || { km_error "cannot inspect recovery mutex mode: $path"; return 4; }
    if [ "$mode" != "600" ]; then
      km_error "recovery mutex has unsafe mode $mode: $path (run: chmod 600 $path)"
      return 4
    fi
    return 0
  fi
  ( umask 077; : > "$path" ) || { km_error "cannot create recovery mutex: $path"; return 4; }
  chmod 600 "$path" 2>/dev/null || true
  return 0
}

# recovery_mutex <store> <timeout-s> <cmd...>
# Exclusive flock(2) on <store>/.recovery.flock held for the duration of
# <cmd...>. Portable primitive: flock(1) where present (Linux), otherwise the
# base-system interpreter bridge (perl -MFcntl=:flock, macOS base install).
# Both operate on an already-open fd 9 so the lock is held by THIS process
# and kernel-released on death regardless of which branch ran. Returns 5 with
# the single stderr line "recovery busy: <path>" on timeout; otherwise the
# wrapped command's own exit status.
recovery_mutex() {
  local store="$1" timeout="$2" flock_path got=0 rc
  shift 2
  flock_path="$store/.recovery.flock"
  km_prepare_recovery_flock_path "$flock_path" || return 4

  exec 9>"$flock_path" || { km_error "cannot open recovery mutex: $flock_path"; return 4; }
  if command -v flock >/dev/null 2>&1; then
    if flock -w "$timeout" 9; then got=1; fi
  else
    if perl -MFcntl=:flock -e '
        my ($fd, $timeout) = @ARGV;
        open(my $fh, "+<&=" . $fd) or exit 2;
        my $end = time() + $timeout;
        while (1) {
          exit 0 if flock($fh, LOCK_EX | LOCK_NB);
          exit 1 if time() >= $end;
          select(undef, undef, undef, 0.1);
        }
      ' 9 "$timeout"; then
      got=1
    fi
  fi
  if [ "$got" -ne 1 ]; then
    exec 9>&- 2>/dev/null || true
    echo "recovery busy: $flock_path" >&2
    return 5
  fi
  "$@"
  rc=$?
  exec 9>&- 2>/dev/null || true
  return $rc
}

# km_verify_gitignored <path>
# Checks directory-target gitignore coverage (a memory store dir, or
# bootstrap's/init's intended store dir before it exists). Shared by
# memory-write.sh bootstrap and init.sh's --apply re-check. A trailing slash
# is appended so a directory-only gitignore pattern (".agents/memory/")
# matches a target that does not exist on disk yet (git can otherwise only
# infer "this is a directory" by statting it, which fails pre-creation).
km_verify_gitignored() {
  local path="$1" repo query
  if ! command -v git >/dev/null 2>&1; then
    km_error "git is required to verify gitignore coverage"
    return 1
  fi
  repo=$(km_git_ancestor "$(dirname "$path")") || {
    km_error "cannot find a git repository to check gitignore coverage for: $path"
    return 1
  }
  query="$path"
  case "$query" in
    */) : ;;
    *) query="${query}/" ;;
  esac
  git -C "$repo" check-ignore -q "$query" 2>/dev/null
}
