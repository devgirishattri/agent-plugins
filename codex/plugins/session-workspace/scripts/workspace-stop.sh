#!/usr/bin/env bash
# workspace-stop.sh — session-workspace 'stop' verb (Phase D).
#
# Safety-critical: kills ONLY tmux sessions carrying THIS project's managed
# session marker (@session_workspace_project == project.id). A session with
# the same configured name that is not marked as ours is left completely
# alone — `tmux has-session -t NAME` prefix-matching is never used; every
# existence/kill check targets `=NAME` exactly, gated by the marker check.
#
# behavior.stop_scope defaults to "selected" (only the TARGET session(s));
# --all widens to every managed session for this project. Either way,
# --confirmed is required or the command refuses outright.
#
# `--pane NAME` (repeatable) stops only the named service panes, or
# executor/reviewer panes marked launch "on_demand", of ONE session (a NAME is
# the full pane name or the part after "<project.id>-"). An on-demand worker
# is refused, and left running, while it is busy: a scheduler task assigned to
# it is still `assigned`, a task it reviews is in `review`, its session-chat
# inbox holds unread messages, or its screen shows a running turn. `--force`
# stops it anyway (the user's override; the harness never admits it).
# each pane carrying this project's markers for that name is asked to stop
# (C-c), given up to the grace period to exit, then its pane is killed. The
# rest of the session keeps running; killing a session's last pane ends the
# session, as tmux always does. A stopped browser pane releases its DevTools
# port claim. The stop is recorded (when, why) in the pane's run record that
# `workspace status` reads; SESSION_WORKSPACE_STOP_REASON overrides the
# recorded reason (the idle watcher sets it). `--expect-pane-id ID` is the
# idle watcher's guard: a pane that was restarted since it was judged idle
# (a different tmux pane id) is left running.
#
# Peer orchestrators (schema v6 with `peers`, 0.17.0): the whole verb runs under
# one hold of the project lock, after the instances.sh preamble (stale records
# removed, caller resolved).
#   `stop --worker NAME --confirmed [--force]` stops one worker, named by its
#   full pane name or the part after "<project.id>-", through the --pane path
#   of its owner's session. A worker pane may sit in a window of its own
#   (hidden), so its lookup covers the whole session. After the pane is gone its
#   record is removed and the orchestrator's window gets its standard layout.
#   Only the owner or the user stops a worker; another orchestrator gets
#   `[held] ... owner X` and exit 3, and --force is the user's alone.
#   `stop <orchestrator session> --confirmed` (the user only) ends that
#   session and removes the copy's record and the records of the workers it
#   owned; behavior.stop_scope is `selected`, so the other orchestrators and
#   their workers keep running. An orchestrator may not stop any orchestrator
#   session, `all`, or use --all.
#
# Usage: workspace-stop.sh [TARGET|all] [--config PATH] [--no-save] --confirmed [--all]
#        workspace-stop.sh SESSION --pane NAME [--pane NAME...] [--config PATH] --confirmed [--force]
#        workspace-stop.sh --worker NAME [--config PATH] --confirmed [--force]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/config.sh"
source "$HERE/validate-config.sh"
source "$HERE/tmux-lib.sh"
source "$HERE/instances.sh"

usage() {
  echo "Usage: workspace-stop.sh [TARGET|all] [--config PATH] [--no-save] --confirmed [--all]" >&2
  echo "       workspace-stop.sh SESSION --pane NAME [--pane NAME...] [--config PATH] --confirmed [--force]" >&2
  echo "       workspace-stop.sh --worker NAME [--config PATH] --confirmed [--force]" >&2
}

TARGET="all"
TARGET_GIVEN=0
CONFIG_OVERRIDE=""
NO_SAVE=0
CONFIRMED_FLAG=0
WIDEN_ALL=0
FORCE_BUSY=0
EXPECT_PANE_ID=""
WORKER_ARG=""
GRACE_SECONDS="${SESSION_WORKSPACE_STOP_GRACE_SECONDS:-5}"
declare -a PANE_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_OVERRIDE="${2:-}"; shift 2 ;;
    --pane)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#-}" != "$2" ]; then
        echo "ERROR: --pane requires a pane name" >&2; usage; exit 1
      fi
      PANE_ARGS+=("$2"); shift 2 ;;
    --worker)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#-}" != "$2" ]; then
        echo "ERROR: --worker requires a worker name" >&2; usage; exit 1
      fi
      WORKER_ARG="$2"; shift 2 ;;
    --expect-pane-id)
      case "${2:-}" in
        %[0-9]*) EXPECT_PANE_ID="$2"; shift 2 ;;
        *) echo "ERROR: --expect-pane-id requires a tmux pane id such as %12" >&2; exit 1 ;;
      esac ;;
    --no-save) NO_SAVE=1; shift ;;
    --confirmed) CONFIRMED_FLAG=1; shift ;;
    --all) WIDEN_ALL=1; shift ;;
    --force) FORCE_BUSY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    all) TARGET="all"; TARGET_GIVEN=1; shift ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage; exit 1 ;;
    *) TARGET="$1"; TARGET_GIVEN=1; shift ;;
  esac
done

ensure_jq
ensure_tmux
sw_tmux_bind

if [ "$CONFIRMED_FLAG" -ne 1 ]; then
  echo "ERROR: workspace-stop refuses to run without --confirmed (this kills live tmux sessions)." >&2
  exit 1
fi

if [ -n "$WORKER_ARG" ]; then
  if [ "$TARGET_GIVEN" -eq 1 ] || [ "${#PANE_ARGS[@]}" -gt 0 ] || [ "$WIDEN_ALL" -eq 1 ] || [ "$NO_SAVE" -eq 1 ] || [ -n "$EXPECT_PANE_ID" ]; then
    echo "ERROR: --worker cannot be combined with a session, --pane, --all, --no-save, or --expect-pane-id" >&2
    exit 1
  fi
elif [ "${#PANE_ARGS[@]}" -gt 0 ]; then
  if [ "$TARGET_GIVEN" -eq 0 ] || [ "$TARGET" = "all" ]; then
    echo "ERROR: --pane needs one explicit session: workspace stop SESSION --pane NAME --confirmed" >&2
    exit 1
  fi
  if [ "$WIDEN_ALL" -eq 1 ] || [ "$NO_SAVE" -eq 1 ]; then
    echo "ERROR: --pane cannot be combined with --all or --no-save" >&2
    exit 1
  fi
  if [ -n "$EXPECT_PANE_ID" ] && [ "${#PANE_ARGS[@]}" -ne 1 ]; then
    echo "ERROR: --expect-pane-id guards exactly one --pane" >&2
    exit 1
  fi
elif [ -n "$EXPECT_PANE_ID" ]; then
  echo "ERROR: --expect-pane-id requires --pane" >&2
  exit 1
elif [ "$FORCE_BUSY" -eq 1 ]; then
  echo "ERROR: --force applies only to --pane (it stops a busy on-demand worker)" >&2
  exit 1
fi

CONFIG_PATH="$(resolve_project_config_path "$CONFIG_OVERRIDE")" || exit 1
CONFIG_JSON="$(load_workspace_config_raw "$CONFIG_PATH")" || exit 1
if ! validate_workspace_config "$CONFIG_JSON" "$CONFIG_PATH"; then
  echo "ERROR: config failed validation: $CONFIG_PATH" >&2
  print_validation_errors
  exit 1
fi
PROJECT_ID="$(printf '%s' "$CONFIG_JSON" | jq -r '.project.id')"

STOP_SCOPE="$(printf '%s' "$CONFIG_JSON" | jq -r '.behavior.stop_scope // "selected"')"
[ "$WIDEN_ALL" -eq 1 ] && STOP_SCOPE="all"

SAVE_BEFORE_STOP="$(printf '%s' "$CONFIG_JSON" | jq -r '.behavior.save_before_stop // false')"
[ "$NO_SAVE" -eq 1 ] && SAVE_BEFORE_STOP="false"

# A peers config takes the lock first, because who may stop what depends on the
# records, and they change only under the lock.
PEERS=0
LOCK_HELD=0
sw_inst_peers "$CONFIG_JSON" && PEERS=1
# One state home for the lock and the registry (instances.sh).
[ "$PEERS" -eq 1 ] && sw_inst_normalize_state_home
if [ -n "$WORKER_ARG" ] && [ "$PEERS" -eq 0 ]; then
  echo "ERROR: --worker needs a schema-6 config with peers" >&2
  exit 1
fi
if [ "$PEERS" -eq 1 ]; then
  sw_lock_acquire "$PROJECT_ID" || exit 1
  LOCK_HELD=1
  sw_inst_begin
  STOP_SCOPE="$(printf '%s' "$CONFIG_JSON" | jq -r '.behavior.stop_scope // "selected"')"
  [ "$WIDEN_ALL" -eq 1 ] && STOP_SCOPE="all"
  if [ -n "$WORKER_ARG" ]; then
    sw_caller_check_worker_verb "stop a worker" "$FORCE_BUSY" ""
    WORKER_ROW="$(sw_worker_resolve "$CONFIG_JSON" "$WORKER_ARG")"
    if [ -z "$WORKER_ROW" ]; then
      echo "ERROR: no worker \"$WORKER_ARG\" (workers: $(printf '%s' "$CONFIG_JSON" | jq -r '[(.sessions // [])[] | (.panes // [])[] | select(.worker != null) | .name] | if length == 0 then "none" else join(", ") end'))" >&2
      exit 1
    fi
    TARGET="$(printf '%s' "$WORKER_ROW" | jq -r '.session_id')"
    TARGET_GIVEN=1
    PANE_ARGS=("$(printf '%s' "$WORKER_ROW" | jq -r '.name')")
  elif [ "${#PANE_ARGS[@]}" -gt 0 ]; then
    sw_caller_check_worker_verb "stop panes" "$FORCE_BUSY" ""
  else
    sw_caller_check_session_verb stop "$TARGET_GIVEN" "$TARGET" "$WIDEN_ALL" "$FORCE_BUSY" ""
  fi
fi

if [ "$TARGET" != "all" ]; then
  if ! printf '%s' "$CONFIG_JSON" | jq -e --arg t "$TARGET" '[(.sessions // [])[].id] | index($t) != null' >/dev/null; then
    echo "ERROR: unknown session target \"$TARGET\"" >&2
    exit 1
  fi
fi

# _sw_wait_pane_idle PANE_ID — after C-c, wait up to GRACE_SECONDS for the
# pane's foreground command to exit (the pane closes, dies, or drops back to a
# shell), so a dev server or Chrome can flush before its pane is killed.
_sw_wait_pane_idle() {
  local pane_id="$1" deadline_ticks=0 ticks=0 cmd
  case "$GRACE_SECONDS" in
    ''|*[!0-9]*) ;;
    *) deadline_ticks=$((GRACE_SECONDS * 5)) ;;
  esac
  while [ "$ticks" -lt "$deadline_ticks" ]; do
    tmux display-message -p -t "$pane_id" '#{pane_id}' >/dev/null 2>&1 || return 0
    sw_pane_dead "$pane_id" && return 0
    cmd="$(sw_pane_current_command "$pane_id")"
    case "$cmd" in bash|sh|zsh|fish|ksh|dash|"") return 0 ;; esac
    sleep 0.2
    ticks=$((ticks + 1))
  done
  return 0
}

# _sw_worker_busy PANE_ID PANE_NAME — print why an on-demand worker is busy
# and return 1, or return 0. Reads the plan's scheduler task store and every
# inbox queue a session-chat send to this pane can land in: the plan's
# messages store and both providers' default messages directories.
_sw_worker_busy() {
  local pane_id="$1" pane_name="$2"
  # The same store arguments start's leftover check reads (instances.sh).
  sw_worker_store_args "$PLAN_JSON" "$pane_name"
  python3 "$HERE/agent-pane.py" busy --pane-id "$pane_id" --pane "$pane_name" "${SW_STORE_ARGS[@]}"
}

if [ "${#PANE_ARGS[@]}" -gt 0 ]; then
  PLAN_JSON="$(bash "$HERE/workspace-plan.sh" --config "$CONFIG_PATH" --json)" || exit 1
  SELECTED_LIST="$(sw_select_panes "$PLAN_JSON" "$TARGET" "${PANE_ARGS[@]}")" || exit 1
  SESSION_NAME="$(printf '%s' "$PLAN_JSON" | jq -r --arg t "$TARGET" '.sessions[] | select(.id == $t) | .name')"
  WINDOW_INDEX="$(printf '%s' "$PLAN_JSON" | jq -r --arg t "$TARGET" '.sessions[] | select(.id == $t) | .window_index // 0')"
  STOP_REASON="${SESSION_WORKSPACE_STOP_REASON:-workspace stop --pane}"

  if [ "$PEERS" -eq 1 ]; then
    # An orchestrator stops only its own workers; nothing has changed yet.
    while IFS= read -r pane_name; do
      [ -n "$pane_name" ] || continue
      held_row="$(printf '%s' "$PLAN_JSON" | jq -r --arg n "$pane_name" '[.sessions[].panes[] | select(.name == $n and .worker != null) | .worker.owner][0] // empty')"
      [ -n "$held_row" ] && sw_caller_require_owner "$SESSION_NAME" "$pane_name" "$held_row"
    done <<<"$SELECTED_LIST"
  fi
  [ "$LOCK_HELD" -eq 1 ] || sw_lock_acquire "$PROJECT_ID" || exit 1
  echo "session-workspace stop — $CONFIG_PATH (project: $PROJECT_ID, session: $TARGET, panes: $(printf '%s' "$SELECTED_LIST" | tr '\n' ' '))"

  STOPPED=0
  NOT_RUNNING=0
  SKIPPED=0
  BUSY=0
  if ! tmux has-session -t "=$SESSION_NAME" 2>/dev/null; then
    while IFS= read -r pane_name; do
      [ -n "$pane_name" ] || continue
      echo "  [absent] $SESSION_NAME / $pane_name — session is not running"
      NOT_RUNNING=$((NOT_RUNNING + 1))
    done <<<"$SELECTED_LIST"
  elif ! sw_session_is_managed "$SESSION_NAME" "$PROJECT_ID"; then
    echo "  [skip]   $SESSION_NAME — exists but is NOT managed by this project; left untouched"
    SKIPPED=1
  else
    while IFS= read -r pane_name; do
      [ -n "$pane_name" ] || continue
      found=""
      # A worker of a peers config may sit in a window of its own (hidden): its
      # lookup covers the whole session. Every other pane keeps the window scope.
      pane_scope=(-t "=$SESSION_NAME:$WINDOW_INDEX")
      is_worker_pane=0
      if [ "$PEERS" -eq 1 ] && [ -n "$(printf '%s' "$PLAN_JSON" | jq -r --arg n "$pane_name" '[.sessions[].panes[] | select(.name == $n and .worker != null) | .name][0] // empty')" ]; then
        pane_scope=(-s -t "=$SESSION_NAME")
        is_worker_pane=1
      fi
      while IFS=$'\t' read -r pid pmark; do
        [ -n "$pid" ] || continue
        if [ "$pmark" = "$pane_name" ] && sw_pane_is_managed "$pid" "$PROJECT_ID" "$pane_name"; then
          found="$pid"
          break
        fi
      done < <(tmux list-panes "${pane_scope[@]}" -F "$(printf '#{pane_id}\t#{%s}' "$MARKER_PANE")" 2>/dev/null)
      if [ -z "$found" ]; then
        echo "  [absent] $SESSION_NAME / $pane_name — not running"
        NOT_RUNNING=$((NOT_RUNNING + 1))
        continue
      fi
      if [ -n "$EXPECT_PANE_ID" ] && [ "$found" != "$EXPECT_PANE_ID" ]; then
        echo "  [skip]   $SESSION_NAME / $pane_name — now pane $found, not $EXPECT_PANE_ID (restarted since it was judged idle); left running"
        SKIPPED=$((SKIPPED + 1))
        continue
      fi
      # An on-demand worker (an agent pane) is closed only when it is idle.
      if [ "$FORCE_BUSY" -eq 0 ] &&
         [ "$(printf '%s' "$PLAN_JSON" | jq -r --arg n "$pane_name" '[.sessions[].panes[] | select(.name == $n) | .runtime.name][0] // "shell"')" != "shell" ]; then
        if ! command -v python3 >/dev/null 2>&1; then
          echo "  [busy]   $SESSION_NAME / $pane_name — python3 is needed to check that the worker is idle; left running (--force stops it anyway)"
          BUSY=$((BUSY + 1))
          continue
        fi
        if ! busy_out="$(_sw_worker_busy "$found" "$pane_name")"; then
          echo "  [busy]   $SESSION_NAME / $pane_name — left running: $(printf '%s' "$busy_out" | paste -sd ';' - | sed 's/;/; /g') (--force stops it anyway)"
          BUSY=$((BUSY + 1))
          continue
        fi
      fi
      # Record before C-c, not just before the kill: a pane whose command is
      # the service itself closes the moment C-c ends it, and anything that
      # sees the pane gone (status, its idle watcher) must already find this
      # stop recorded. The pane id is the record's identity.
      sw_pane_record_stop "$PROJECT_ID" "$pane_name" "$found" "$STOP_REASON" ||
        echo "WARNING: could not record the stop of $pane_name" >&2
      case "$(sw_pane_current_command "$found")" in
        bash|sh|zsh|fish|ksh|dash|"") ;;
        *) tmux send-keys -t "$found" C-c 2>/dev/null || true
           _sw_wait_pane_idle "$found" ;;
      esac
      tmux kill-pane -t "$found" 2>/dev/null || true
      echo "  [stopped] $SESSION_NAME / $pane_name — $STOP_REASON"
      STOPPED=$((STOPPED + 1))
      # The record goes once the pane is gone for sure. A pane that is somehow
      # still there keeps its record; the next cleanup settles it.
      if [ "$is_worker_pane" -eq 1 ] && ! tmux display-message -p -t "$found" '#{pane_id}' >/dev/null 2>&1; then
        worker_triple="$(printf '%s' "$PLAN_JSON" | jq -r --arg n "$pane_name" '[.sessions[].panes[] | select(.name == $n and .worker != null) | .worker | [.checkout, .role, .["label"]] | join("\u0001")][0] // empty')"
        IFS=$'\001' read -r dw_checkout dw_role dw_label <<<"$worker_triple"
        sw_inst_commit "$(sw_inst_drop_worker "$dw_checkout" "$dw_role" "${dw_label:-}")" 0 || echo "WARNING: could not remove the record of $pane_name" >&2
      fi
      while IFS= read -r browser_port; do
        [ -n "$browser_port" ] && sw_browser_release_port "$PROJECT_ID" "$browser_port"
      done < <(printf '%s' "$PLAN_JSON" | jq -r --arg sid "$TARGET" --arg pane "$pane_name" \
        '(.browsers // (if .browser != null then [.browser] else [] end))[] | select(.session_id == $sid and .pane_name == $pane) | .port')
    done <<<"$SELECTED_LIST"
  fi

  # Re-apply a standard layout so the panes left share the window again.
  if [ "$STOPPED" -gt 0 ] && tmux has-session -t "=$SESSION_NAME" 2>/dev/null &&
     [ "$(printf '%s' "$PLAN_JSON" | jq -r --arg t "$TARGET" '.sessions[] | select(.id == $t) | .layout.kind // "standard"')" != "split_tree" ]; then
    STOP_OWNER="$(printf '%s' "$PLAN_JSON" | jq -r --arg t "$TARGET" '[.sessions[] | select(.id == $t) | .panes[] | select(.worker != null) | .worker.owner][0] // empty')"
    [ -n "$STOP_OWNER" ] && WINDOW_INDEX="$(sw_owner_window_index "$SESSION_NAME" "$STOP_OWNER" "$WINDOW_INDEX")"
    tmux select-layout -t "=$SESSION_NAME:$WINDOW_INDEX" \
      "$(printf '%s' "$PLAN_JSON" | jq -r --arg t "$TARGET" '.sessions[] | select(.id == $t) | .layout.name // "tiled"')" 2>/dev/null || true
  fi
  if [ "$PEERS" -eq 1 ]; then sw_inst_cleanup; fi
  echo
  echo "stopped: $STOPPED  not running: $NOT_RUNNING  skipped: $SKIPPED  busy: $BUSY"
  sw_lock_release
  [ "$BUSY" -eq 0 ] || exit 1
  exit 0
fi

[ "$LOCK_HELD" -eq 1 ] || sw_lock_acquire "$PROJECT_ID" || exit 1

echo "session-workspace stop — $CONFIG_PATH (project: $PROJECT_ID, scope: $STOP_SCOPE)"

# Build the list of (session_id, session_name) pairs to consider: the
# "selected" scope is exactly the configured sessions matching TARGET;
# "all" widens to every session on the server carrying our project marker
# (which may include sessions the current config no longer even lists).
declare -a CANDIDATE_IDS=()
declare -a CANDIDATE_NAMES=()

while IFS= read -r s; do
  sid="$(printf '%s' "$s" | jq -r '.id')"
  sname="$(printf '%s' "$s" | jq -r '.name')"
  [ "$TARGET" != "all" ] && [ "$sid" != "$TARGET" ] && continue
  CANDIDATE_IDS+=("$sid")
  CANDIDATE_NAMES+=("$sname")
done < <(printf '%s' "$CONFIG_JSON" | jq -c '.sessions[]')

if [ "$STOP_SCOPE" = "all" ]; then
  while IFS=$'\t' read -r sname pval; do
    [ -z "$sname" ] && continue
    [ "$pval" = "$PROJECT_ID" ] || continue
    already=0
    for existing in "${CANDIDATE_NAMES[@]:-}"; do
      [ "$existing" = "$sname" ] && already=1
    done
    [ "$already" -eq 1 ] && continue
    CANDIDATE_IDS+=("(unlisted)")
    CANDIDATE_NAMES+=("$sname")
  done < <(tmux list-sessions -F "$(printf '#{session_name}\t#{%s}' "$MARKER_PROJECT")" 2>/dev/null)
fi

KILLED=0
SKIPPED_UNMANAGED=0
MISSING=0

n="${#CANDIDATE_NAMES[@]}"
i=0
while [ "$i" -lt "$n" ]; do
  sid="${CANDIDATE_IDS[$i]}"
  sname="${CANDIDATE_NAMES[$i]}"
  i=$((i + 1))

  if ! tmux has-session -t "=$sname" 2>/dev/null; then
    echo "  [absent] $sname — nothing to stop"
    MISSING=$((MISSING + 1))
    continue
  fi

  if ! sw_session_is_managed "$sname" "$PROJECT_ID"; then
    echo "  [skip]   $sname — exists but is NOT managed by this project; left untouched"
    echo "           (to bring it under management first: workspace-reconcile ${sid} --adopt --confirmed, then --apply --adopt --confirmed)"
    SKIPPED_UNMANAGED=$((SKIPPED_UNMANAGED + 1))
    continue
  fi

  window_target="=$sname:0"
  if [ "$SAVE_BEFORE_STOP" = "true" ] && [ "$sid" != "(unlisted)" ]; then
    retain="$(printf '%s' "$CONFIG_JSON" | jq -r --arg id "$sid" '(.sessions[] | select(.id == $id) | .retain_layout) // false')"
    if [ "$retain" = "true" ]; then
      sw_save_layout "$PROJECT_ID" "$sid" "$window_target" 2>/dev/null || true
    fi
  fi
  if [ "$SAVE_BEFORE_STOP" = "true" ] && [ -x "$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh" ]; then
    # The save script calls tmux by name: give it the bound server through
    # $TMUX (the socket field is all a tmux client reads from it).
    env -u SESSION_WORKSPACE_TMUX_SOCKET TMUX="$SESSION_WORKSPACE_TMUX_SOCKET,0,0" \
      "$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh" >/dev/null 2>&1 || true
  fi

  # Graceful service shutdown: ask every managed, non-idle pane in this
  # session to stop (C-c), then allow the configured grace period before
  # the whole session is force-killed underneath them. A peers session also
  # holds hidden workers in windows of their own, so it asks every window.
  sess_scope=(-t "=$sname")
  [ "$PEERS" -eq 1 ] && sess_scope=(-s -t "=$sname")
  while IFS=$'\t' read -r pane_id pmark ppmark; do
    [ -z "$pane_id" ] && continue
    [ "$pmark" = "$PROJECT_ID" ] || continue
    [ -n "$ppmark" ] || continue
    case "$(sw_pane_current_command "$pane_id")" in
      bash|sh|zsh|fish|ksh|dash|"") ;;
      *) tmux send-keys -t "$pane_id" C-c 2>/dev/null || true ;;
    esac
  done < <(tmux list-panes "${sess_scope[@]}" -F "$(printf '#{pane_id}\t#{%s}\t#{%s}' "$MARKER_PROJECT" "$MARKER_PANE")" 2>/dev/null)

  if [ "$GRACE_SECONDS" -gt 0 ] 2>/dev/null; then
    sleep "$GRACE_SECONDS"
  fi

  tmux kill-session -t "=$sname" 2>/dev/null || true
  echo "  [killed] $sname"
  # A copy's record and the records of the workers its orchestrator owned go
  # with the session (the workers lived in it). Only this session's own records:
  # the other orchestrators and their workers keep running.
  if [ "$PEERS" -eq 1 ] && [ "$sid" != "(unlisted)" ] && ! tmux has-session -t "=$sname" 2>/dev/null; then
    sw_inst_commit "$(sw_inst_drop_session "$sid")" 0 || echo "WARNING: could not remove the records of $sname" >&2
  fi
  while IFS= read -r browser_port; do
    sw_browser_release_port "$PROJECT_ID" "$browser_port"
  done < <(printf '%s' "$CONFIG_JSON" | jq -r --arg sid "$sid" '[.browser?, .browsers[]?][] | select(. != null and .session_id == $sid) | .port')
  KILLED=$((KILLED + 1))
done

if [ "$PEERS" -eq 1 ]; then sw_inst_cleanup; fi
echo
echo "killed: $KILLED  skipped (unmanaged): $SKIPPED_UNMANAGED  absent: $MISSING"

sw_lock_release
exit 0
