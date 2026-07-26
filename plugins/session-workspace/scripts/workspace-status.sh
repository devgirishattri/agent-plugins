#!/usr/bin/env bash
# workspace-status.sh — session-workspace 'status' verb (Phase D). Read-only:
# reports session/pane/role/runtime/configured-model/cwd/process/health for
# every planned pane. Never mutates tmux or any state file.
#
# Usage: workspace-status.sh [TARGET|all] [--config PATH] [--json]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/config.sh"
source "$HERE/validate-config.sh"
source "$HERE/tmux-lib.sh"

usage() { echo "Usage: workspace-status.sh [TARGET|all] [--config PATH] [--json]" >&2; }

TARGET="all"
CONFIG_OVERRIDE=""
JSON_MODE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_OVERRIDE="${2:-}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    all) TARGET="all"; shift ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage; exit 1 ;;
    *) TARGET="$1"; shift ;;
  esac
done

ensure_jq
ensure_tmux

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
    KNOWN_IDS="$(printf '%s' "$CONFIG_JSON" | jq -r '[(.sessions // [])[].id] | join(", ")')"
    echo "ERROR: unknown session target \"$TARGET\" (known: $KNOWN_IDS)" >&2
    exit 1
  fi
fi

PLAN_JSON="$(bash "$HERE/workspace-plan.sh" --config "$CONFIG_PATH" --json)" || exit 1

ROWS="[]"
while IFS= read -r session_json; do
  s_id="$(printf '%s' "$session_json" | jq -r '.id')"
  s_name="$(printf '%s' "$session_json" | jq -r '.name')"
  s_win="$(printf '%s' "$session_json" | jq -r '.window_index // 0')"
  [ "$TARGET" != "all" ] && [ "$s_id" != "$TARGET" ] && continue

  session_exists=0
  session_managed=0
  if tmux has-session -t "=$s_name" 2>/dev/null; then
    session_exists=1
    sw_session_is_managed "$s_name" "$PROJECT_ID" && session_managed=1
  fi

  while IFS= read -r pane_json; do
    p_name="$(printf '%s' "$pane_json" | jq -r '.name')"
    p_role="$(printf '%s' "$pane_json" | jq -r '.role')"
    p_runtime="$(printf '%s' "$pane_json" | jq -r '.runtime.name')"
    p_model="$(printf '%s' "$pane_json" | jq -r '.agent.model // "inherit"')"
    p_cwd="$(printf '%s' "$pane_json" | jq -r '.cwd // "(unresolved)"')"

    found_pane="" cur_cmd="" managed=0 dead=0
    if [ "$session_exists" -eq 1 ]; then
      # Scoped to THIS session's window, never `-a` (server-wide): a stale
      # same-named marker left on a pane in some OTHER session (an old
      # orphaned session, a different project's leftover pane) must never be
      # able to false-report this slot as healthy.
      while IFS=$'\t' read -r pid pmark; do
        [ -z "$pid" ] && continue
        if [ "$pmark" = "$p_name" ]; then
          found_pane="$pid"
          break
        fi
      done < <(tmux list-panes -t "=$s_name:$s_win" -F "$(printf '#{pane_id}\t#{%s}' "$MARKER_PANE")" 2>/dev/null)
      if [ -n "$found_pane" ]; then
        sw_pane_is_managed "$found_pane" "$PROJECT_ID" "$p_name" && managed=1
        sw_pane_dead "$found_pane" && dead=1
        cur_cmd="$(sw_pane_current_command "$found_pane")"
      fi
    fi

    health="missing"
    if [ -n "$found_pane" ]; then
      if [ "$dead" -eq 1 ]; then health="dead"
      elif [ "$managed" -eq 1 ]; then health="healthy"
      else health="unmanaged-occupant"
      fi
    fi

    row="$(jq -n \
      --arg session "$s_id" --arg session_name "$s_name" \
      --arg pane "$p_name" --arg role "$p_role" --arg runtime "$p_runtime" \
      --arg model "$p_model" --arg cwd "$p_cwd" --arg pane_id "${found_pane:-}" \
      --arg process "${cur_cmd:-}" --arg health "$health" \
      --argjson session_exists "$session_exists" --argjson session_managed "$session_managed" \
      '{session:$session, session_name:$session_name, session_exists:($session_exists == 1), session_managed:($session_managed == 1), pane:$pane, role:$role, runtime:$runtime, model:$model, cwd:$cwd, pane_id:$pane_id, process:$process, health:$health}')"
    ROWS="$(printf '%s' "$ROWS" | jq -c --argjson r "$row" '. + [$r]')"
  done < <(printf '%s' "$session_json" | jq -c '.panes[]')
done < <(printf '%s' "$PLAN_JSON" | jq -c '.sessions[]')

if [ "$JSON_MODE" -eq 1 ]; then
  printf '%s\n' "$ROWS" | jq '.'
  exit 0
fi

echo "session-workspace status — $CONFIG_PATH (project: $PROJECT_ID)"
printf '%s\n' "$ROWS" | jq -r '
  group_by(.session_name)[] |
  "== session: \(.[0].session_name) == (exists=\(.[0].session_exists) managed=\(.[0].session_managed))",
  (.[] | "  pane: \(.pane)  role=\(.role) runtime=\(.runtime) model=\(.model)\n    cwd=\(.cwd)\n    pane_id=\(.pane_id // "(none)")  process=\(.process // "(n/a)")  health=\(.health)")
'
exit 0
