#!/usr/bin/env bash
# workspace-reconcile.sh — session-workspace 'reconcile' verb (Phase D).
# Dry-run by default (reports what would change, mutates nothing); --apply
# performs the repair. Repairs missing/misnamed MANAGED resources without
# restarting healthy panes. --adopt --confirmed is the only path to claiming
# an existing unmanaged pane, and always prints the adoption plan first
# (even in dry-run / without --apply).
#
# Usage: workspace-reconcile.sh [TARGET|all] [--config PATH] [--apply]
#          [--adopt --confirmed]
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
Usage: workspace-reconcile.sh [TARGET|all] [--config PATH] [--apply]
         [--adopt --confirmed]
EOF
}

TARGET="all"
CONFIG_OVERRIDE=""
APPLY_FLAG=0
ADOPT_FLAG=0
CONFIRMED_FLAG=0
NO_AGENTS=0
NO_SERVICES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_OVERRIDE="${2:-}"; shift 2 ;;
    --apply) APPLY_FLAG=1; shift ;;
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
    echo "ERROR: --adopt requires --confirmed. Run without --apply first to review the adoption plan, then re-run with --apply --adopt --confirmed." >&2
    exit 1
  fi
  ALLOW_ADOPT=1
fi
DRY_RUN=1
[ "$APPLY_FLAG" -eq 1 ] && DRY_RUN=0

CONFIG_PATH="$(resolve_project_config_path "$CONFIG_OVERRIDE")" || exit 1
CONFIG_JSON="$(load_workspace_config_raw "$CONFIG_PATH")" || exit 1
if ! validate_workspace_config "$CONFIG_JSON" "$CONFIG_PATH"; then
  echo "ERROR: config failed validation: $CONFIG_PATH" >&2
  print_validation_errors
  exit 1
fi
PROJECT_ID="$(printf '%s' "$CONFIG_JSON" | jq -r '.project.id')"

if [ "$TARGET" != "all" ]; then
  if ! printf '%s' "$CONFIG_JSON" | jq -e --arg t "$TARGET" '[(.sessions // [])[].id] | index($t) != null' >/dev/null; then
    echo "ERROR: unknown session target \"$TARGET\"" >&2
    exit 1
  fi
fi

if [ "$DRY_RUN" -eq 0 ]; then
  sw_lock_acquire "$PROJECT_ID" || exit 1
fi

PLAN_JSON="$(bash "$HERE/workspace-plan.sh" --config "$CONFIG_PATH" --json)" || exit 1

if [ "$DRY_RUN" -eq 1 ]; then
  echo "session-workspace reconcile (DRY RUN — pass --apply to act) — $CONFIG_PATH (project: $PROJECT_ID)"
else
  echo "session-workspace reconcile --apply — $CONFIG_PATH (project: $PROJECT_ID)"
fi

sw_process_plan "$PLAN_JSON" "$TARGET"

echo
if [ "$DRY_RUN" -eq 1 ]; then
  echo "(dry run — nothing was changed; re-run with --apply to perform these repairs)"
else
  echo "repaired/adopted: $SW_CHANGED  kept (already healthy): $SW_KEPT  failed: $SW_FAILED_SLOTS"
  sw_lock_release
fi

[ "$SW_FAILED_SLOTS" -gt 0 ] && exit 1
exit 0
