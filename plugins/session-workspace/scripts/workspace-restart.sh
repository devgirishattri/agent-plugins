#!/usr/bin/env bash
# workspace-restart.sh — session-workspace 'restart' verb (Phase D).
# stop (--confirmed, implicit) followed by start, for the same target.
# Accepts --no-save (the old hand-maintained launchers' `restart` did not —
# see defect #12 in the session-workspace plan).
#
# Usage: workspace-restart.sh [TARGET|all] [--config PATH] [--no-save]
#          [--no-agents] [--no-services] [--no-attach]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: workspace-restart.sh [TARGET|all] [--config PATH] [--no-save]
         [--no-agents] [--no-services] [--no-attach]
EOF
}

TARGET="all"
CONFIG_OVERRIDE=""
NO_SAVE=0
declare -a START_PASSTHRU=()

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_OVERRIDE="${2:-}"; START_PASSTHRU+=(--config "$2"); shift 2 ;;
    --no-save) NO_SAVE=1; shift ;;
    --no-agents|--no-services|--no-attach) START_PASSTHRU+=("$1"); shift ;;
    -h|--help) usage; exit 0 ;;
    all) TARGET="all"; shift ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage; exit 1 ;;
    *) TARGET="$1"; shift ;;
  esac
done

declare -a STOP_ARGS=("$TARGET" --confirmed)
[ -n "$CONFIG_OVERRIDE" ] && STOP_ARGS+=(--config "$CONFIG_OVERRIDE")
[ "$NO_SAVE" -eq 1 ] && STOP_ARGS+=(--no-save)

bash "$HERE/workspace-stop.sh" "${STOP_ARGS[@]}" || exit 1

declare -a START_ARGS=("$TARGET")
[ "${#START_PASSTHRU[@]}" -gt 0 ] && START_ARGS+=("${START_PASSTHRU[@]}")

exec bash "$HERE/workspace-start.sh" "${START_ARGS[@]}"
