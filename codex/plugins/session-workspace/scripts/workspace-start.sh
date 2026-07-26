#!/usr/bin/env bash
# workspace-start.sh — session-workspace 'start' verb (Phase D).
# Creates only MISSING managed topology; a second run against a healthy
# workspace is a no-op (no respawn of healthy panes). An unmanaged pane
# occupying a planned slot is never renamed/repurposed — that slot fails
# with actionable guidance unless --adopt --confirmed is also passed.
#
# With no TARGET argument the target is behavior.default_start_target (itself
# defaulting to "all"). On success the session is attached per behavior.attach
# unless --no-attach is passed. An unresolvable session-chat helper aborts the
# run when behavior.session_chat_helper.on_missing is "fail".
#
# Usage: workspace-start.sh [TARGET|all] [--config PATH]
#          [--no-agents] [--no-services] [--no-attach] [--adopt --confirmed]
# shellcheck disable=SC2034  # NO_AGENTS / NO_SERVICES / ALLOW_ADOPT / DRY_RUN are
# the documented caller contract that the sourced lifecycle.sh reads (see its
# header); ShellCheck cannot see across the `source` boundary.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/config.sh"
source "$HERE/validate-config.sh"
source "$HERE/tmux-lib.sh"
source "$HERE/lifecycle.sh"

usage() {
  cat >&2 <<'EOF'
Usage: workspace-start.sh [TARGET|all] [--config PATH]
         [--no-agents] [--no-services] [--no-attach] [--adopt --confirmed]
EOF
}

# Empty until the argv loop or behavior.default_start_target sets it, so
# "no TARGET given" is distinguishable from an explicit "all".
TARGET=""
CONFIG_OVERRIDE=""
NO_AGENTS=0
NO_SERVICES=0
NO_ATTACH=0
ADOPT_FLAG=0
CONFIRMED_FLAG=0

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_OVERRIDE="${2:-}"; shift 2 ;;
    --no-agents) NO_AGENTS=1; shift ;;
    --no-services) NO_SERVICES=1; shift ;;
    --no-attach) NO_ATTACH=1; shift ;;
    --adopt) ADOPT_FLAG=1; shift ;;
    --confirmed) CONFIRMED_FLAG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    all) TARGET="all"; shift ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage; exit 1 ;;
    *) TARGET="$1"; shift ;;
  esac
done

ensure_jq
ensure_tmux

ALLOW_ADOPT=0
if [ "$ADOPT_FLAG" -eq 1 ]; then
  if [ "$CONFIRMED_FLAG" -ne 1 ]; then
    echo "ERROR: --adopt requires --confirmed (adoption is the only path to claiming an unmanaged pane; review the plan it prints first)." >&2
    exit 1
  fi
  ALLOW_ADOPT=1
fi
DRY_RUN=0

CONFIG_PATH="$(resolve_project_config_path "$CONFIG_OVERRIDE")" || exit 1
CONFIG_JSON="$(load_workspace_config_raw "$CONFIG_PATH")" || exit 1
if ! validate_workspace_config "$CONFIG_JSON" "$CONFIG_PATH"; then
  echo "ERROR: config failed validation: $CONFIG_PATH" >&2
  print_validation_errors
  exit 1
fi
PROJECT_ID="$(printf '%s' "$CONFIG_JSON" | jq -r '.project.id')"

# behavior.default_start_target supplies the target for a bare `start`; the
# schema restricts it to "all" or a configured sessions[].id, so it can never
# resolve to a target the checks below would then reject.
if [ -z "$TARGET" ]; then
  TARGET="$(printf '%s' "$CONFIG_JSON" | jq -r '.behavior.default_start_target // "all"')"
fi

# behavior.session_chat_helper.on_missing gates the whole run, BEFORE the lock
# is taken and before anything in tmux is touched: "fail" means this project
# considers inter-pane messaging load-bearing, so a workspace that cannot have
# it must not come up half-wired. `workspace-doctor` reports on exactly this
# resolution (both use lib.sh's sw_session_chat_helper_root), so its
# "start WILL fail" verdict is now literally true.
SCH_RESOLVE="$(printf '%s' "$CONFIG_JSON" | jq -r '.behavior.session_chat_helper.resolve // "always"')"
SCH_ON_MISSING="$(printf '%s' "$CONFIG_JSON" | jq -r '.behavior.session_chat_helper.on_missing // "warn"')"
if [ "$SCH_RESOLVE" != "never" ] && ! sw_session_chat_helper_root >/dev/null; then
  if [ "$SCH_ON_MISSING" = "fail" ]; then
    echo "ERROR: the session-chat helper does not resolve, and behavior.session_chat_helper.on_missing is \"fail\"." >&2
    echo "       Refusing to start: nothing has been created or changed." >&2
    echo "       Install session-chat, or set behavior.session_chat_helper.on_missing to \"warn\"." >&2
    echo "       Run 'workspace-doctor' for the resolution details." >&2
    exit 1
  fi
  echo "WARNING: the session-chat helper does not resolve (behavior.session_chat_helper.on_missing: warn); panes will start without inter-pane messaging." >&2
fi

ATTACH_MODE="$(printf '%s' "$CONFIG_JSON" | jq -r '.behavior.attach // "if_terminal"')"

if [ "$TARGET" != "all" ]; then
  if ! printf '%s' "$CONFIG_JSON" | jq -e --arg t "$TARGET" '[(.sessions // [])[].id] | index($t) != null' >/dev/null; then
    echo "ERROR: unknown session target \"$TARGET\"" >&2
    exit 1
  fi
fi

sw_lock_acquire "$PROJECT_ID" || exit 1

PLAN_JSON="$(bash "$HERE/workspace-plan.sh" --config "$CONFIG_PATH" --json)" || exit 1

echo "session-workspace start — $CONFIG_PATH (project: $PROJECT_ID)"
sw_process_plan "$PLAN_JSON" "$TARGET"

echo
echo "started/adopted: $SW_CHANGED  kept (already healthy): $SW_KEPT  failed: $SW_FAILED_SLOTS"

sw_lock_release

if [ "$SW_FAILED_SLOTS" -gt 0 ]; then
  exit 1
fi

# Attach (behavior.attach), only after a fully successful start. The session
# is the explicit/default TARGET when that names one; for "all" it is the
# first session in the plan, matching the order `workspace-plan` displays.
if [ "$NO_ATTACH" -eq 1 ]; then
  echo "attach: suppressed by --no-attach"
else
  if [ "$TARGET" != "all" ]; then
    ATTACH_SESSION="$(printf '%s' "$PLAN_JSON" | jq -r --arg t "$TARGET" 'first(.sessions[] | select(.id == $t) | .name) // ""')"
  else
    ATTACH_SESSION="$(printf '%s' "$PLAN_JSON" | jq -r '(.sessions[0].name) // ""')"
  fi
  sw_attach_session "$ATTACH_MODE" "$ATTACH_SESSION"
fi

exit 0
