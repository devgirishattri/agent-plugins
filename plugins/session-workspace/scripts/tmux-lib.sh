#!/usr/bin/env bash
# tmux-lib.sh — Phase D tmux lifecycle primitives shared by workspace-start /
# workspace-status / workspace-reconcile / workspace-stop / workspace-restart:
# project-scoped locking, managed-resource markers, `=NAME` exact targeting,
# pane naming (`@name` + `select-pane -T`, with the server-wide duplicate-name
# sweep), the split-tree layout builder, and window-layout persistence.
#
# Source this after lib.sh. Every tmux mutation in this file uses `=NAME`
# exact-match targeting (never a bare prefix-matchable name) and builds argv
# arrays, never `eval`.
set -uo pipefail

# Resolve this library's own directory from ${BASH_SOURCE[0]}, never $0:
# this file is SOURCED, so $0 belongs to the caller — and for a `bash -c`
# or `bash -s` caller $0 is literally "bash", which resolved the sibling
# library against $PWD and broke depending on the working directory.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

# ============================================================================
# Managed markers — the ONLY authority for "did this engine create it".
# ============================================================================
MARKER_PROJECT="@session_workspace_project"
MARKER_SESSION="@session_workspace_session"
MARKER_PANE="@session_workspace_pane"
MARKER_ROLE="@session_workspace_role"
MARKER_RUNTIME="@session_workspace_runtime"
# MARKER_LAUNCHED records that this pane's configured runtime was ACTUALLY
# launched (never merely claimed). It is written only after a successful
# launch, and deliberately NOT written when the launch was suppressed by
# --no-agents / --no-services. Health is judged on it, not on the pane's
# foreground process, so:
#   * a pane whose launch failed carries no markers at all and is retried;
#   * a pane claimed under --no-agents is a REPAIRABLE state that a later
#     plain `start`/`reconcile --apply` finishes (it is not a one-way door);
#   * and judging health this way is deterministic — inspecting
#     #{pane_current_command} instead would race the launched process's own
#     exec chain (bash -> runtime), so a `start` run moments after another
#     could see "bash" and needlessly respawn a perfectly healthy pane.
MARKER_LAUNCHED="@session_workspace_launched"

# NOTE on session-scoped option targeting: `set-option`/`show-options` take a
# target-PANE (tmux infers the option's scope from its name), NOT a
# target-session. A bare `-t "=NAME"` therefore fails with "no such session"
# — it is only a valid target for the verbs that genuinely take a session
# (has-session, kill-session, list-panes -t, new-window -t). The correct
# exact-match, prefix-safe pane target for "session scope of NAME" is
# `=NAME:` (trailing colon). Verified on tmux 3.6b: `=NAME:` sets/reads the
# session-scope value, is visible from every window in that session, and a
# truncated `=PREFI:` fails instead of prefix-matching.
sw_session_option_target() {
  printf '=%s:' "$1"
}

sw_get_session_option() {
  local session="$1" opt="$2"
  tmux show-options -t "$(sw_session_option_target "$session")" -v "$opt" 2>/dev/null
}

sw_get_pane_option() {
  local pane_id="$1" opt="$2"
  tmux show-options -p -t "$pane_id" -v "$opt" 2>/dev/null
}

sw_set_session_markers() {
  local session="$1" project_id="$2" session_id="$3" target
  target="$(sw_session_option_target "$session")"
  tmux set-option -t "$target" "$MARKER_PROJECT" "$project_id" || return 1
  tmux set-option -t "$target" "$MARKER_SESSION" "$session_id" || return 1
}

sw_session_is_managed() {
  local session="$1" project_id="$2"
  [ "$(sw_get_session_option "$session" "$MARKER_PROJECT")" = "$project_id" ]
}

sw_set_pane_markers() {
  local pane_id="$1" project_id="$2" pane_name="$3" role="$4" runtime="$5"
  tmux set-option -p -t "$pane_id" "$MARKER_PROJECT" "$project_id" || return 1
  tmux set-option -p -t "$pane_id" "$MARKER_PANE" "$pane_name" || return 1
  tmux set-option -p -t "$pane_id" "$MARKER_ROLE" "$role" || return 1
  tmux set-option -p -t "$pane_id" "$MARKER_RUNTIME" "$runtime" || return 1
}

sw_pane_is_managed() {
  local pane_id="$1" project_id="$2" pane_name="$3"
  [ "$(sw_get_pane_option "$pane_id" "$MARKER_PROJECT")" = "$project_id" ] &&
    [ "$(sw_get_pane_option "$pane_id" "$MARKER_PANE")" = "$pane_name" ]
}

# sw_set_pane_launched PANE_ID RUNTIME — record a successful launch.
sw_set_pane_launched() {
  tmux set-option -p -t "$1" "$MARKER_LAUNCHED" "$2" || return 1
}

# sw_pane_launched PANE_ID — true if this pane's runtime was really launched
# by a previous (or this) run. A managed pane that is NOT launched is
# repairable, never healthy.
sw_pane_launched() {
  [ -n "$(sw_get_pane_option "$1" "$MARKER_LAUNCHED")" ]
}

sw_pane_dead() {
  local pane_id="$1"
  [ "$(tmux display-message -p -t "$pane_id" '#{pane_dead}' 2>/dev/null)" = "1" ]
}

sw_pane_current_command() {
  tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

# sw_pane_is_blank PANE_ID — true if the pane carries no session-workspace
# markers at all AND its foreground process is an idle interactive shell
# (freshly split / never repurposed by anything). Used to tell "our own
# brand-new split" apart from "an unmanaged pane someone is using".
sw_pane_is_blank() {
  local pane_id="$1"
  [ -z "$(sw_get_pane_option "$pane_id" "$MARKER_PROJECT")" ] || return 1
  case "$(sw_pane_current_command "$pane_id")" in
    bash|sh|zsh|fish|ksh|dash|"") return 0 ;;
    *) return 1 ;;
  esac
}

# ============================================================================
# Project-scoped locking — mkdir-based (flock is unavailable on macOS), with
# a pid file and stale-lock detection. Serializes start/reconcile/stop.
# ============================================================================
SW_LOCK_DIR=""
SW_LOCK_ACQUIRED=0

sw_state_root() {
  printf '%s/session-workspace\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

sw_project_state_dir() {
  printf '%s/%s\n' "$(sw_state_root)" "$1"
}

sw_ensure_state_dir() {
  local dir
  dir="$(sw_project_state_dir "$1")"
  mkdir -p "$dir/layouts" 2>/dev/null
  printf '%s\n' "$dir"
}

# Project lock. `start`, `reconcile --apply`, `stop` and the idle watcher's
# stops serialize on one lock directory per project, with the protocol the
# session-chat, scheduler and knowledge locks use. None of it trusts mkdir as
# a test-and-set (uutils mkdir can report success to two racing callers):
#   claim   — after mkdir, the holder pid file is created exclusively
#             (noclobber, O_EXCL); that create, not mkdir, is ownership.
#   reclaim — a lock whose holder pid is dead is taken over IN PLACE under an
#             exclusively created `reclaim` marker, from a subshell anchored to
#             the directory with `cd -P`; it is never deleted, because the dead
#             holder's lock may already have been released and claimed again.
#   release — only by the holder, with one rename of the whole directory into
#             a private retirement directory beside it.

# _sw_claim_lock LOCK_DIR: 0 claimed; 1 another acquirer claimed it first or
# it vanished (keep waiting); 2 the pid file cannot be written.
_sw_claim_lock() {
  local path="$1" _
  for _ in 1 2; do
    ( set -o noclobber; printf '%s\n' "$$" > "$path/pid" ) 2>/dev/null && return 0
    if [ -e "$path/pid" ] || [ -L "$path/pid" ] || [ ! -d "$path" ]; then
      return 1
    fi
  done
  rmdir "$path" 2>/dev/null || true
  return 2
}

# _sw_reclaim_lock LOCK_DIR EXPECTED_DEAD_PID: 0 only on a takeover. Of
# several waiters that saw the same dead pid, one succeeds; none touches a
# newer holder's lock.
_sw_reclaim_lock() (
  path="$1" expected="$2" result=1
  [ ! -L "$path" ] && cd -P "$path" 2>/dev/null || exit 1
  set -o noclobber
  { : > reclaim; } 2>/dev/null || exit 1
  if [ "$(cat pid 2>/dev/null)" = "$expected" ]; then
    printf '%s\n' "$$" >| pid 2>/dev/null && result=0
  fi
  rm -f reclaim 2>/dev/null || true
  exit "$result"
)

# _sw_release_lock LOCK_DIR: release a lock this process holds (pid == $$).
_sw_release_lock() {
  local path="$1" retired
  [ ! -L "$path" ] && [ ! -L "$path/pid" ] || return 1
  [ "$(cat "$path/pid" 2>/dev/null)" = "$$" ] || return 1
  retired=$(mktemp -d "$(dirname "$path")/.release.XXXXXXXX") || return 1
  if ! mv "$path" "$retired/lock" 2>/dev/null; then
    rmdir "$retired" 2>/dev/null || true
    return 1
  fi
  rm -rf "$retired"
}

# sw_lock_acquire PROJECT_ID [TIMEOUT_SECONDS]
# On success, sets SW_LOCK_DIR/SW_LOCK_ACQUIRED and installs an EXIT/INT/TERM
# trap that releases the lock. A lock whose recorded holder is no longer
# alive is taken over at once (no wait).
sw_lock_acquire() {
  local project_id="$1"
  local timeout="${2:-${SESSION_WORKSPACE_LOCK_TIMEOUT:-30}}"
  local state_dir lock_dir waited=0 holder_pid claim
  state_dir="$(sw_ensure_state_dir "$project_id")"
  lock_dir="$state_dir/lock"
  # Wait in 0.1 s steps; the timeout stays in seconds.
  local ticks=$((timeout * 10))

  while :; do
    if mkdir "$lock_dir" 2>/dev/null; then
      claim=0; _sw_claim_lock "$lock_dir" || claim=$?
      if [ "$claim" -eq 0 ]; then
        SW_LOCK_DIR="$lock_dir"
        SW_LOCK_ACQUIRED=1
        trap 'sw_lock_release' EXIT INT TERM
        return 0
      elif [ "$claim" -eq 2 ]; then
        echo "ERROR: could not record the workspace lock holder in $lock_dir" >&2
        return 1
      fi
    fi

    holder_pid="$( { tr -d '[:space:]' < "$lock_dir/pid"; } 2>/dev/null )"
    if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
      if _sw_reclaim_lock "$lock_dir" "$holder_pid"; then
        echo "WARNING: reclaiming stale workspace lock for \"$project_id\" (held by dead pid $holder_pid); taken over in place" >&2
        SW_LOCK_DIR="$lock_dir"
        SW_LOCK_ACQUIRED=1
        trap 'sw_lock_release' EXIT INT TERM
        return 0
      fi
    fi

    if [ "$waited" -ge "$ticks" ]; then
      echo "ERROR: could not acquire workspace lock for project \"$project_id\" within ${timeout}s (held by pid ${holder_pid:-unknown})" >&2
      return 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
}

sw_lock_release() {
  [ "$SW_LOCK_ACQUIRED" -eq 1 ] || return 0
  [ -n "$SW_LOCK_DIR" ] && _sw_release_lock "$SW_LOCK_DIR"
  SW_LOCK_ACQUIRED=0
}

# ============================================================================
# Pane naming — `@name` is the session-chat addressing identity (shared
# convention, see plugins/session-chat/scripts/lib.sh:234); `select-pane -T`
# mirrors it into the visible pane title. A server-wide sweep clears `@name`
# from any OTHER pane already carrying this value first, so the identity
# stays unique across the whole tmux server (defect: unswept duplicate names
# make session-chat addressing ambiguous).
# ============================================================================
sw_set_pane_name() {
  local pane_id="$1" name="$2" pid pname
  while IFS=$'\t' read -r pid pname; do
    [ -z "$pid" ] && continue
    [ "$pid" = "$pane_id" ] && continue
    if [ "$pname" = "$name" ]; then
      tmux set-option -p -t "$pid" -u @name 2>/dev/null || true
    fi
  done < <(tmux list-panes -a -F $'#{pane_id}\t#{@name}' 2>/dev/null)
  tmux set-option -p -t "$pane_id" @name "$name" || return 1
  tmux select-pane -t "$pane_id" -T "$name" 2>/dev/null || true
}

# ============================================================================
# Split-tree layout builder — ordered splits per layout.kind == "split_tree".
# Emits `-l <pct>%` (never the deprecated `-p`). Masks the window's
# after-split-window hook during construction so a user's own tmux hooks
# cannot interfere with a multi-split build, and restores it unconditionally
# afterward (even on failure, via the caller's trap/cleanup).
# ============================================================================
#
# Masking SAVES the window's pre-existing after-split-window hook and
# unmasking RESTORES it byte-for-byte, rather than just unsetting it — a bare
# `set-hook -u` would silently DELETE a hook the user had configured on that
# window. The hook is an array option, so every index is captured in order and
# re-appended in order. Note that in tmux 3.6b `show-hooks`/`show-options -w`
# do not list hooks, but `show-options -w -t WIN -v <hook>[N]` reads them.
SW_SAVED_SPLIT_HOOK=""
SW_SAVED_SPLIT_HOOK_COUNT=0

sw_mask_after_split_hook() {
  local win="$1" i=0 val
  SW_SAVED_SPLIT_HOOK=""
  SW_SAVED_SPLIT_HOOK_COUNT=0
  while [ "$i" -lt 32 ]; do
    val="$(tmux show-options -w -t "$win" -v "after-split-window[$i]" 2>/dev/null)" || break
    [ -n "$val" ] || break
    SW_SAVED_SPLIT_HOOK="${SW_SAVED_SPLIT_HOOK}${val}"$'\n'
    SW_SAVED_SPLIT_HOOK_COUNT=$((SW_SAVED_SPLIT_HOOK_COUNT + 1))
    i=$((i + 1))
  done
  tmux set-hook -w -t "$win" after-split-window 'run-shell -b true'
}

sw_unmask_after_split_hook() {
  local win="$1" line
  tmux set-hook -w -t "$win" -u after-split-window 2>/dev/null || true
  [ "$SW_SAVED_SPLIT_HOOK_COUNT" -gt 0 ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    tmux set-hook -w -t "$win" -a after-split-window "$line" 2>/dev/null || true
  done <<SW_HOOK_EOF
$SW_SAVED_SPLIT_HOOK
SW_HOOK_EOF
  SW_SAVED_SPLIT_HOOK=""
  SW_SAVED_SPLIT_HOOK_COUNT=0
}

# sw_build_split_tree WINDOW_TARGET NODES_JSON
# WINDOW_TARGET must currently have exactly one pane (only_when_fresh is the
# caller's job to check). Populates NODE_IDS[] / NODE_PANES[] (parallel
# arrays, node id -> resulting pane id, in construction/pane_order-independent
# order) on success.
NODE_IDS=()
NODE_PANES=()
sw_build_split_tree() {
  local window_target="$1" nodes_json="$2"
  NODE_IDS=()
  NODE_PANES=()

  local first_pane first_id
  first_pane="$(tmux list-panes -t "$window_target" -F '#{pane_id}' 2>/dev/null | head -n1)"
  [ -n "$first_pane" ] || { echo "ERROR: split_tree: window \"$window_target\" has no panes" >&2; return 1; }
  first_id="$(printf '%s' "$nodes_json" | jq -r '.[0].id')"
  NODE_IDS+=("$first_id")
  NODE_PANES+=("$first_pane")

  local count i=1 node id from dir percent from_pane new_pane flag
  count="$(printf '%s' "$nodes_json" | jq 'length')"
  while [ "$i" -lt "$count" ]; do
    node="$(printf '%s' "$nodes_json" | jq -c ".[$i]")"
    id="$(printf '%s' "$node" | jq -r '.id')"
    from="$(printf '%s' "$node" | jq -r '.from')"
    dir="$(printf '%s' "$node" | jq -r '.dir')"
    percent="$(printf '%s' "$node" | jq -r '.percent')"

    from_pane="$(_sw_node_pane "$from")" || {
      echo "ERROR: split_tree: node \"$id\" references unknown from=\"$from\"" >&2
      return 1
    }
    case "$dir" in
      v) flag="-v" ;;
      h) flag="-h" ;;
      *) echo "ERROR: split_tree: node \"$id\" has invalid dir \"$dir\"" >&2; return 1 ;;
    esac

    new_pane="$(tmux split-window -t "$from_pane" "$flag" -l "${percent}%" -P -F '#{pane_id}')"
    if [ -z "$new_pane" ]; then
      echo "ERROR: split_tree: split-window failed for node \"$id\"" >&2
      return 1
    fi
    NODE_IDS+=("$id")
    NODE_PANES+=("$new_pane")
    i=$((i + 1))
  done
}

_sw_node_pane() {
  local id="$1" j=0 n="${#NODE_IDS[@]}"
  while [ "$j" -lt "$n" ]; do
    if [ "${NODE_IDS[$j]}" = "$id" ]; then
      printf '%s' "${NODE_PANES[$j]}"
      return 0
    fi
    j=$((j + 1))
  done
  return 1
}

# ============================================================================
# Interactive attach — behavior.attach, honoured by workspace-start.sh.
#
# Every decision is REPORTED on stdout (one line, always), so an automated
# caller can prove which branch was taken without needing a terminal. The
# policy order is deliberate: the config gate and the CLI override are checked
# BEFORE the terminal probe, so `behavior.attach: never` and `--no-attach` are
# observable everywhere, not only on a tty.
#
# Inside tmux the correct verb is `switch-client` (attach-session from within a
# client nests a server inside itself); outside it is `attach-session`. Both
# are gated on stdout being a terminal: switch-client would otherwise yank
# whatever client happens to own $TMUX — including a developer's real session
# during an automated run.
# ============================================================================
sw_attach_session() {
  local mode="$1" name="$2"

  if [ "$mode" = "never" ]; then
    echo "attach: disabled by behavior.attach=never"
    return 0
  fi
  if [ -z "$name" ]; then
    echo "attach: skipped (no session resolved to attach to)"
    return 0
  fi
  if ! tmux has-session -t "=$name" 2>/dev/null; then
    echo "attach: skipped (session \"$name\" does not exist)"
    return 0
  fi

  # Test/automation hook: resolve and report the attach that WOULD happen,
  # without needing (or hijacking) a real terminal. Mirrors the
  # SESSION_WORKSPACE_* env knobs used elsewhere in this engine.
  if [ "${SESSION_WORKSPACE_ATTACH_DRY_RUN:-0}" = "1" ]; then
    if [ -n "${TMUX:-}" ]; then
      echo "attach: would switch the current client to \"$name\""
    else
      echo "attach: would attach to \"$name\""
    fi
    return 0
  fi

  if [ ! -t 1 ]; then
    echo "attach: skipped (not a terminal)"
    return 0
  fi

  if [ -n "${TMUX:-}" ]; then
    if tmux switch-client -t "=$name" 2>/dev/null; then
      echo "attach: switched the current client to \"$name\""
    else
      echo "attach: could not switch the current client to \"$name\""
    fi
    return 0
  fi
  echo "attach: attaching to \"$name\""
  tmux attach-session -t "=$name" || echo "attach: attach-session failed for \"$name\""
}

# ============================================================================
# Layout persistence — save/restore #{window_layout} per retain_layout, under
# the state dir, umask 077 (inherited from lib.sh's process-wide umask).
# ============================================================================
sw_layout_file() {
  printf '%s/layouts/%s.layout\n' "$(sw_project_state_dir "$1")" "$2"
}

sw_save_layout() {
  local project_id="$1" session_id="$2" window_target="$3" dir file val
  dir="$(sw_ensure_state_dir "$project_id")"
  file="$(sw_layout_file "$project_id" "$session_id")"
  val="$(tmux display-message -p -t "$window_target" '#{window_layout}' 2>/dev/null)" || return 1
  [ -n "$val" ] || return 1
  printf '%s\n' "$val" >"$file"
}

sw_restore_layout() {
  local project_id="$1" session_id="$2" window_target="$3" file val
  file="$(sw_layout_file "$project_id" "$session_id")"
  [ -f "$file" ] || return 1
  val="$(cat "$file" 2>/dev/null)"
  [ -n "$val" ] || return 1
  tmux select-layout -t "$window_target" "$val" 2>/dev/null
}
