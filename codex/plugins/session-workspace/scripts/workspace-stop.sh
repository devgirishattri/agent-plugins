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
# Usage: workspace-stop.sh [TARGET|all] [--config PATH] [--no-save] --confirmed [--all]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/config.sh"
source "$HERE/validate-config.sh"
source "$HERE/tmux-lib.sh"

usage() {
  echo "Usage: workspace-stop.sh [TARGET|all] [--config PATH] [--no-save] --confirmed [--all]" >&2
}

TARGET="all"
CONFIG_OVERRIDE=""
NO_SAVE=0
CONFIRMED_FLAG=0
WIDEN_ALL=0
GRACE_SECONDS="${SESSION_WORKSPACE_STOP_GRACE_SECONDS:-5}"

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_OVERRIDE="${2:-}"; shift 2 ;;
    --no-save) NO_SAVE=1; shift ;;
    --confirmed) CONFIRMED_FLAG=1; shift ;;
    --all) WIDEN_ALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    all) TARGET="all"; shift ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage; exit 1 ;;
    *) TARGET="$1"; shift ;;
  esac
done

ensure_jq
ensure_tmux

if [ "$CONFIRMED_FLAG" -ne 1 ]; then
  echo "ERROR: workspace-stop refuses to run without --confirmed (this kills live tmux sessions)." >&2
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
  KILLED=$((KILLED + 1))
done

echo
echo "killed: $KILLED  skipped (unmanaged): $SKIPPED_UNMANAGED  absent: $MISSING"

sw_lock_release
exit 0
