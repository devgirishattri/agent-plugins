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
# `--pane NAME` (repeatable) stops only the named service panes of ONE
# session (a NAME is the full pane name or the part after "<project.id>-"):
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
# Usage: workspace-stop.sh [TARGET|all] [--config PATH] [--no-save] --confirmed [--all]
#        workspace-stop.sh SESSION --pane NAME [--pane NAME...] [--config PATH] --confirmed
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/config.sh"
source "$HERE/validate-config.sh"
source "$HERE/tmux-lib.sh"

usage() {
  echo "Usage: workspace-stop.sh [TARGET|all] [--config PATH] [--no-save] --confirmed [--all]" >&2
  echo "       workspace-stop.sh SESSION --pane NAME [--pane NAME...] [--config PATH] --confirmed" >&2
}

TARGET="all"
TARGET_GIVEN=0
CONFIG_OVERRIDE=""
NO_SAVE=0
CONFIRMED_FLAG=0
WIDEN_ALL=0
EXPECT_PANE_ID=""
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
    --expect-pane-id)
      case "${2:-}" in
        %[0-9]*) EXPECT_PANE_ID="$2"; shift 2 ;;
        *) echo "ERROR: --expect-pane-id requires a tmux pane id such as %12" >&2; exit 1 ;;
      esac ;;
    --no-save) NO_SAVE=1; shift ;;
    --confirmed) CONFIRMED_FLAG=1; shift ;;
    --all) WIDEN_ALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    all) TARGET="all"; TARGET_GIVEN=1; shift ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage; exit 1 ;;
    *) TARGET="$1"; TARGET_GIVEN=1; shift ;;
  esac
done

ensure_jq
ensure_tmux

if [ "$CONFIRMED_FLAG" -ne 1 ]; then
  echo "ERROR: workspace-stop refuses to run without --confirmed (this kills live tmux sessions)." >&2
  exit 1
fi

if [ "${#PANE_ARGS[@]}" -gt 0 ]; then
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

if [ "${#PANE_ARGS[@]}" -gt 0 ]; then
  PLAN_JSON="$(bash "$HERE/workspace-plan.sh" --config "$CONFIG_PATH" --json)" || exit 1
  SELECTED_LIST="$(sw_select_panes "$PLAN_JSON" "$TARGET" "${PANE_ARGS[@]}")" || exit 1
  SESSION_NAME="$(printf '%s' "$PLAN_JSON" | jq -r --arg t "$TARGET" '.sessions[] | select(.id == $t) | .name')"
  WINDOW_INDEX="$(printf '%s' "$PLAN_JSON" | jq -r --arg t "$TARGET" '.sessions[] | select(.id == $t) | .window_index // 0')"
  STOP_REASON="${SESSION_WORKSPACE_STOP_REASON:-workspace stop --pane}"

  sw_lock_acquire "$PROJECT_ID" || exit 1
  echo "session-workspace stop — $CONFIG_PATH (project: $PROJECT_ID, session: $TARGET, panes: $(printf '%s' "$SELECTED_LIST" | tr '\n' ' '))"

  STOPPED=0
  NOT_RUNNING=0
  SKIPPED=0
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
      while IFS=$'\t' read -r pid pmark; do
        [ -n "$pid" ] || continue
        if [ "$pmark" = "$pane_name" ] && sw_pane_is_managed "$pid" "$PROJECT_ID" "$pane_name"; then
          found="$pid"
          break
        fi
      done < <(tmux list-panes -t "=$SESSION_NAME:$WINDOW_INDEX" -F "$(printf '#{pane_id}\t#{%s}' "$MARKER_PANE")" 2>/dev/null)
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
      while IFS= read -r browser_port; do
        [ -n "$browser_port" ] && sw_browser_release_port "$PROJECT_ID" "$browser_port"
      done < <(printf '%s' "$PLAN_JSON" | jq -r --arg sid "$TARGET" --arg pane "$pane_name" \
        '(.browsers // (if .browser != null then [.browser] else [] end))[] | select(.session_id == $sid and .pane_name == $pane) | .port')
    done <<<"$SELECTED_LIST"
  fi

  echo
  echo "stopped: $STOPPED  not running: $NOT_RUNNING  skipped: $SKIPPED"
  sw_lock_release
  exit 0
fi

sw_lock_acquire "$PROJECT_ID" || exit 1

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
    "$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh" >/dev/null 2>&1 || true
  fi

  # Graceful service shutdown: ask every managed, non-idle pane in this
  # session to stop (C-c), then allow the configured grace period before
  # the whole session is force-killed underneath them.
  while IFS=$'\t' read -r pane_id pmark ppmark; do
    [ -z "$pane_id" ] && continue
    [ "$pmark" = "$PROJECT_ID" ] || continue
    [ -n "$ppmark" ] || continue
    case "$(sw_pane_current_command "$pane_id")" in
      bash|sh|zsh|fish|ksh|dash|"") ;;
      *) tmux send-keys -t "$pane_id" C-c 2>/dev/null || true ;;
    esac
  done < <(tmux list-panes -t "=$sname" -F "$(printf '#{pane_id}\t#{%s}\t#{%s}' "$MARKER_PROJECT" "$MARKER_PANE")" 2>/dev/null)

  if [ "$GRACE_SECONDS" -gt 0 ] 2>/dev/null; then
    sleep "$GRACE_SECONDS"
  fi

  tmux kill-session -t "=$sname" 2>/dev/null || true
  echo "  [killed] $sname"
  while IFS= read -r browser_port; do
    sw_browser_release_port "$PROJECT_ID" "$browser_port"
  done < <(printf '%s' "$CONFIG_JSON" | jq -r --arg sid "$sid" '[.browser?, .browsers[]?][] | select(. != null and .session_id == $sid) | .port')
  KILLED=$((KILLED + 1))
done

echo
echo "killed: $KILLED  skipped (unmanaged): $SKIPPED_UNMANAGED  absent: $MISSING"

sw_lock_release
exit 0
