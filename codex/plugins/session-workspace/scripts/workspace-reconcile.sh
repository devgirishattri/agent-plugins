#!/usr/bin/env bash
# workspace-reconcile.sh — session-workspace 'reconcile' verb (Phase D).
# Dry-run by default (reports what would change, mutates nothing); --apply
# performs the repair. Repairs missing/misnamed MANAGED resources without
# restarting healthy panes. --adopt --confirmed is the only path to claiming
# an existing unmanaged pane, and always prints the adoption plan first
# (even in dry-run / without --apply).
#
# Peer orchestrators (schema v6 with `peers`): --apply takes the lock first,
# removes stale records of instances.json and works out who is calling
# (instances.sh). An orchestrator may not apply a reconcile to an orchestrator
# session or to `all`. `all` skips an orchestrator copy that is not running, so
# records left over from a reboot do not bring it back. A running hidden
# worker is found session-wide and reported kept; a dry run changes nothing and
# never writes the state file.
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
source "$HERE/instances.sh"

usage() {
  cat >&2 <<'EOF'
Usage: workspace-reconcile.sh [TARGET|all] [--config PATH] [--apply]
         [--adopt --confirmed]
EOF
}

TARGET="all"
TARGET_GIVEN=0
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
    all) TARGET="all"; TARGET_GIVEN=1; shift ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage; exit 1 ;;
    *) TARGET="$1"; TARGET_GIVEN=1; shift ;;
  esac
done

ensure_jq
ensure_tmux
sw_tmux_bind

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
PEERS=0
sw_inst_peers "$CONFIG_JSON" && PEERS=1
# One state home for the lock and the registry (instances.sh).
[ "$PEERS" -eq 1 ] && sw_inst_normalize_state_home

if [ "$PEERS" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
  sw_lock_acquire "$PROJECT_ID" || exit 1
  sw_inst_begin
  sw_caller_check_session_verb "reconcile" "$TARGET_GIVEN" "$TARGET" 0 0 ""
fi

if [ "$TARGET" != "all" ]; then
  if ! printf '%s' "$CONFIG_JSON" | jq -e --arg t "$TARGET" '[(.sessions // [])[].id] | index($t) != null' >/dev/null; then
    echo "ERROR: unknown session target \"$TARGET\"" >&2
    exit 1
  fi
fi

if [ "$DRY_RUN" -eq 0 ] && [ "$PEERS" -eq 0 ]; then
  sw_lock_acquire "$PROJECT_ID" || exit 1
fi

PLAN_JSON="$(bash "$HERE/workspace-plan.sh" --config "$CONFIG_PATH" --json)" || exit 1

# `all` leaves out an orchestrator copy whose tmux session is not running.
if [ "$PEERS" -eq 1 ] && [ "$TARGET" = "all" ]; then
  while IFS= read -r copy_json; do
    copy_name="$(printf '%s' "$copy_json" | jq -r '.name')"
    if ! tmux has-session -t "=$copy_name" 2>/dev/null; then
      PLAN_JSON="$(printf '%s' "$PLAN_JSON" | jq -c --arg id "$(printf '%s' "$copy_json" | jq -r '.id')" '.sessions |= map(select(.id != $id))')"
    fi
  done < <(printf '%s' "$PLAN_JSON" | jq -c '.sessions[] | select((.instance.index // 1) > 1)')
fi

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
  if [ "$PEERS" -eq 1 ]; then sw_inst_cleanup; fi
  sw_lock_release
fi

[ "$SW_FAILED_SLOTS" -gt 0 ] && exit 1
exit 0
