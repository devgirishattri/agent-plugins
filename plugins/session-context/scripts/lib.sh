#!/usr/bin/env bash
# lib.sh — Shared functions for session-context plugin
# Source this file: source "$(dirname "$0")/lib.sh"
# Supported platforms: macOS, Linux

# Context snapshots and their archived history hold private handoff content, so
# keep everything owner-only. umask 077 makes new files 0600 / dirs 0700
# (process-local: the /context-* commands run these scripts as subprocesses, so
# it never tightens the user's interactive umask). Auto-context handoffs written
# by session-scheduler are 0400 and are preserved as-is by harden_contexts_dir.
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

# A real, owner-owned, non-symlink directory.
_ctx_dir_is_safe() {
  local d="$1"
  [ -L "$d" ] && return 1
  [ -d "$d" ] || return 1
  [ -O "$d" ] || return 1
  return 0
}

# Owner-only, symlink-safe context store — FAILS CLOSED. Re-checked on every
# call (a symlink can be planted after the first run):
#   - the store root and any nested dir (e.g. .history/) are real, owner-owned,
#     non-symlink directories
#   - NO nested symlink, unowned entry, or special file exists
#   - legacy tree is migrated in place: dirs -> 0700, group/other-accessible
#     regular files -> 0600, while EXISTING 0400 (immutable auto handoffs) and
#     0600 files are preserved untouched
harden_contexts_dir() {
  local store="$1" entry mode tmp_list find_rc
  if [ -L "$store" ]; then
    echo "ERROR: refusing to use context store '$store' — it is a symlink." >&2
    return 1
  fi
  if ! mkdir -p "$store" 2>/dev/null; then
    echo "ERROR: could not create context store '$store'." >&2
    return 1
  fi
  if ! _ctx_dir_is_safe "$store"; then
    echo "ERROR: context store '$store' is unsafe (symlink, not a directory, or not owned by you)." >&2
    return 1
  fi
  # NUL-safe traversal with an observed find status. A `< <(find)` process
  # substitution hides a traversal failure (we could vet a partial tree and still
  # succeed), and a pre-planted owner file MAY contain a newline in its name — so
  # capture `find -print0` into a temp file, check find's status, then read
  # NUL-delimited entries.
  tmp_list=$(mktemp 2>/dev/null) || { echo "ERROR: could not allocate a temp file for store traversal." >&2; return 1; }
  find "$store" -mindepth 1 -print0 > "$tmp_list" 2>/dev/null
  find_rc=$?
  if [ "$find_rc" -ne 0 ]; then
    rm -f "$tmp_list"
    echo "ERROR: could not fully traverse context store (find rc=$find_rc); refusing to operate on a partially-vetted tree." >&2
    return 1
  fi
  # PASS 1 — validate the complete dedicated-store shape (only <name>.md
  # snapshots, an optional .history/ directory, and .history/<name>.md archived
  # versions) before changing any permissions, so a wrongly-pointed
  # SESSION_CONTEXT_HOME (an actual project tree) is rejected WITHOUT us
  # chmod-ing someone's source directory.
  local rel
  while IFS= read -r -d '' entry; do
    [ -n "$entry" ] || continue
    if [ -L "$entry" ]; then
      rm -f "$tmp_list"; echo "ERROR: refusing to operate — nested symlink in context store: '$entry'." >&2; return 1
    fi
    if [ ! -O "$entry" ]; then
      rm -f "$tmp_list"; echo "ERROR: refusing to operate — entry not owned by you: '$entry'." >&2; return 1
    fi
    rel="${entry#"$store"/}"
    case "$rel" in
      .history)
        [ -d "$entry" ] && [ ! -L "$entry" ] || { rm -f "$tmp_list"; echo "ERROR: refusing to operate — '.history' is not a directory: '$entry'." >&2; return 1; }
        ;;
      .history/*/*)
        rm -f "$tmp_list"; echo "ERROR: refusing to operate — unexpected nested directory under .history: '$entry' (not a dedicated context store)." >&2; return 1
        ;;
      .history/*.md)
        [ -f "$entry" ] || { rm -f "$tmp_list"; echo "ERROR: refusing to operate — unexpected file in context store: '$entry'." >&2; return 1; }
        ;;
      .history/*)
        rm -f "$tmp_list"; echo "ERROR: refusing to operate — unexpected file in context store: '$entry' (only <name>.md history versions allowed)." >&2; return 1
        ;;
      *.md)
        [ -f "$entry" ] || { rm -f "$tmp_list"; echo "ERROR: refusing to operate — unexpected file in context store: '$entry'." >&2; return 1; }
        ;;
      *)
        if [ -d "$entry" ]; then
          rm -f "$tmp_list"; echo "ERROR: refusing to operate — unexpected nested directory in context store: '$entry' (not a dedicated context store)." >&2; return 1
        fi
        rm -f "$tmp_list"; echo "ERROR: refusing to operate — unexpected file in context store: '$entry' (not a dedicated context store)." >&2; return 1
        ;;
    esac
  done < "$tmp_list"
  # PASS 2 — shape validated; now migrate modes. Store root first, then entries.
  chmod 700 "$store" 2>/dev/null || { rm -f "$tmp_list"; echo "ERROR: could not lock '$store' to 0700." >&2; return 1; }
  while IFS= read -r -d '' entry; do
    [ -n "$entry" ] || continue
    if [ -d "$entry" ]; then
      chmod 700 "$entry" 2>/dev/null || { rm -f "$tmp_list"; echo "ERROR: could not lock dir '$entry' to 0700." >&2; return 1; }
    elif [ -f "$entry" ]; then
      mode=$(stat -c '%a' "$entry" 2>/dev/null || stat -f '%Lp' "$entry" 2>/dev/null)
      # Preserve EXACTLY 0400 (immutable auto handoff) or 0600 (private); chmod
      # every other mode down to 0600.
      case "$mode" in
        400|600) : ;;
        *) chmod 600 "$entry" 2>/dev/null || { rm -f "$tmp_list"; echo "ERROR: could not lock file '$entry' to 0600." >&2; return 1; } ;;
      esac
    fi
  done < "$tmp_list"
  rm -f "$tmp_list"
  return 0
}

get_contexts_dir() {
  # SESSION_CONTEXT_HOME must be provided by the caller. The /context-* commands
  # (and the SessionStart hook) export it automatically, resolving
  # <git-root|pwd>/tmp/contexts. Fail closed rather than guessing a location, and
  # harden/vet the store before any read or write (callers use `|| exit 1`).
  if [ -z "${SESSION_CONTEXT_HOME:-}" ]; then
    echo "ERROR: SESSION_CONTEXT_HOME is not set." >&2
    echo "Run session-context through its /context-* commands (they set it automatically)," >&2
    echo "or export SESSION_CONTEXT_HOME=<dir> before invoking the scripts directly." >&2
    return 1
  fi
  harden_contexts_dir "$SESSION_CONTEXT_HOME" || return 1
  echo "$SESSION_CONTEXT_HOME"
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
