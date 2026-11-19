#!/usr/bin/env bash
# workspace-restart.sh — session-workspace 'restart' verb (Phase D).
# stop (--confirmed, implicit) followed by start, for the same target.
# Accepts --no-save (the old hand-maintained launchers' `restart` did not —
# see defect #12 in the session-workspace plan).
#
# Peer orchestrators (schema v6 with `peers`): who may restart what is checked
# before anything is stopped (instances.sh). An orchestrator may not restart an
# orchestrator session or `all`, and a worker pane restarts nothing. Restarting
# an orchestrator session ends the workers it owned (they live in its tmux
# session), and their records go with them.
#
# Usage: workspace-restart.sh [TARGET|all] [--config PATH] [--no-save]
#          [--no-agents] [--no-services] [--no-attach]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/instances.sh"

usage() {
  cat >&2 <<'EOF'
Usage: workspace-restart.sh [TARGET|all] [--config PATH] [--no-save]
         [--no-agents] [--no-services] [--no-attach]
EOF
}

TARGET="all"
TARGET_GIVEN=0
CONFIG_OVERRIDE=""
NO_SAVE=0
declare -a START_PASSTHRU=()

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_OVERRIDE="${2:-}"; START_PASSTHRU+=(--config "$2"); shift 2 ;;
    --no-save) NO_SAVE=1; shift ;;
    --no-agents|--no-services|--no-attach) START_PASSTHRU+=("$1"); shift ;;
    -h|--help) usage; exit 0 ;;
    all) TARGET="all"; TARGET_GIVEN=1; shift ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage; exit 1 ;;
    *) TARGET="$1"; TARGET_GIVEN=1; shift ;;
  esac
done

# Peers: refuse before anything is stopped. The stop and start steps check the
# same rules again under the project lock.
ensure_jq
ensure_tmux
sw_tmux_bind
RESTART_CONFIG_PATH="$(resolve_project_config_path "$CONFIG_OVERRIDE")" || exit 1
CONFIG_PATH="$RESTART_CONFIG_PATH"
CONFIG_JSON="$(load_workspace_config_raw "$CONFIG_PATH")" || exit 1
if sw_inst_peers "$CONFIG_JSON"; then
  # shellcheck disable=SC2034  # read by sw_caller_resolve (instances.sh)
  PROJECT_ID="$(printf '%s' "$CONFIG_JSON" | jq -r '.project.id')"
  # One state home for the lock and the registry (instances.sh).
  sw_inst_normalize_state_home
  sw_caller_resolve
  sw_caller_check_session_verb "restart" "$TARGET_GIVEN" "$TARGET" 0 0 ""
fi

# Check before stop: an unavailable reviewer grant must not tear down a
# healthy session only to fail its subsequent start.
declare -a PLAN_ARGS=("$TARGET" --json)
[ -n "$CONFIG_OVERRIDE" ] && PLAN_ARGS+=(--config "$CONFIG_OVERRIDE")
PLAN_JSON="$(bash "$HERE/workspace-plan.sh" "${PLAN_ARGS[@]}")" || exit 1
sw_require_available_read_paths "$PLAN_JSON" "$TARGET" || exit 1

declare -a STOP_ARGS=("$TARGET" --confirmed)
[ -n "$CONFIG_OVERRIDE" ] && STOP_ARGS+=(--config "$CONFIG_OVERRIDE")
[ "$NO_SAVE" -eq 1 ] && STOP_ARGS+=(--no-save)

bash "$HERE/workspace-stop.sh" "${STOP_ARGS[@]}" || exit 1

declare -a START_ARGS=("$TARGET")
[ "${#START_PASSTHRU[@]}" -gt 0 ] && START_ARGS+=("${START_PASSTHRU[@]}")

exec bash "$HERE/workspace-start.sh" "${START_ARGS[@]}"
