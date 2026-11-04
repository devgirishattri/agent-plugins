#!/usr/bin/env bash
# workspace-status.sh — session-workspace 'status' verb (Phase D). Read-only:
# reports session/pane/role/runtime/configured-model/cwd/process/health for
# every planned pane. Never mutates tmux or any state file.
#
# Per pane it also reports `running` (a live, managed pane whose runtime or
# command was really launched), the idle-stop watcher's view for a pane with
# idle_stop_minutes, and the last recorded stop (when, why) for a pane that
# `workspace stop --pane` or its idle watcher stopped. Every configured
# browser gets one health line for its DevTools endpoint (up/down, the
# Browser string /json/version answers, and how many CDP clients are
# connected), so a coordinator can confirm the endpoint before a browser
# smoke. `--pane NAME` (repeatable, with a session TARGET) narrows the report
# to those service panes.
#
# Usage: workspace-status.sh [TARGET|all] [--config PATH] [--json] [--pane NAME...]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/config.sh"
source "$HERE/validate-config.sh"
source "$HERE/tmux-lib.sh"

usage() { echo "Usage: workspace-status.sh [TARGET|all] [--config PATH] [--json] [--pane NAME...]" >&2; }

TARGET="all"
CONFIG_OVERRIDE=""
JSON_MODE=0
declare -a PANE_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_OVERRIDE="${2:-}"; shift 2 ;;
    --pane)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#-}" != "$2" ]; then
        echo "ERROR: --pane requires a pane name" >&2; usage; exit 1
      fi
      PANE_ARGS+=("$2"); shift 2 ;;
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

if [ "${#PANE_ARGS[@]}" -gt 0 ] && [ "$TARGET" = "all" ]; then
  echo "ERROR: --pane needs one explicit session: workspace status SESSION --pane NAME" >&2
  exit 1
fi

PLAN_JSON="$(bash "$HERE/workspace-plan.sh" --config "$CONFIG_PATH" --json)" || exit 1

SELECTED_JSON="null"
if [ "${#PANE_ARGS[@]}" -gt 0 ]; then
  SELECTED_LIST="$(sw_select_panes "$PLAN_JSON" "$TARGET" "${PANE_ARGS[@]}")" || exit 1
  SELECTED_JSON="$(printf '%s\n' "$SELECTED_LIST" | jq -R . | jq -sc 'map(select(length > 0))')"
fi
HAVE_PY=0
command -v python3 >/dev/null 2>&1 && HAVE_PY=1

# _sw_browser_endpoint PORT -> JSON {url, up, browser, cdp_clients}. "up"
# means /json/version answered with a DevTools-shaped payload (the same test
# start waits on); null when curl is missing. cdp_clients counts ESTABLISHED
# inbound connections on the DevTools port (null when unobservable).
_sw_browser_endpoint() {
  local port="$1" payload="" up="null" browser="" clients="null"
  if command -v curl >/dev/null 2>&1; then
    up="false"
    payload="$(curl -fsS --max-time 1 "http://127.0.0.1:${port}/json/version" 2>/dev/null)" || payload=""
    if [ -n "$payload" ] && printf '%s' "$payload" | jq -e '(.Browser | type == "string") and (.webSocketDebuggerUrl | type == "string")' >/dev/null 2>&1; then
      up="true"
      browser="$(printf '%s' "$payload" | jq -r '.Browser')"
    fi
  fi
  if [ "$HAVE_PY" -eq 1 ]; then
    clients="$(python3 "$HERE/service-ports.py" clients "$port" 2>/dev/null)"
    case "$clients" in ''|*[!0-9]*) clients="null" ;; esac
  fi
  jq -cn --arg url "http://127.0.0.1:$port" --argjson up "$up" --arg browser "$browser" --argjson clients "$clients" \
    '{url: $url, up: $up, browser: (if $browser == "" then null else $browser end), cdp_clients: $clients}'
}

# _sw_pane_run_record PANE_NAME FOUND_PANE RUNNING -> JSON {idle, last_stop}
# from the pane's run record (see lib.sh sw_pane_record_path). The record
# describes the live pane only when its pane_id is the live pane's id; a
# record for an earlier incarnation contributes only its stop.
_sw_pane_run_record() {
  local pane_name="$1" found_pane="$2" running="$3" record watcher_alive="false" pid
  record="$(cat "$(sw_pane_record_path "$PROJECT_ID" "$pane_name")" 2>/dev/null)"
  printf '%s' "$record" | jq -e 'type == "object"' >/dev/null 2>&1 || record='{}'
  pid="$(printf '%s' "$record" | jq -r '.watcher_pid // empty')"
  case "$pid" in
    ''|*[!0-9]*) ;;
    *) if [ -n "$found_pane" ] && kill -0 "$pid" 2>/dev/null &&
          [ "$(sw_get_pane_option "$found_pane" "@session_workspace_idle_watcher")" = "$pid" ]; then
         watcher_alive="true"
       fi ;;
  esac
  printf '%s' "$record" | jq -c --arg found "$found_pane" --argjson running "$running" --argjson alive "$watcher_alive" '
    (($found != "") and (.pane_id // "") == $found) as $current
    | {
        idle: (if $running and $current and (.idle_stop_minutes != null) then {
                 minutes: .idle_stop_minutes,
                 activity: (if .kind == "browser" then null else (.idle_activity // ["connections"]) end),
                 watcher: (if $alive then "watching" else "not running" end),
                 clients: .clients,
                 recently_closed: (.recently_closed // null),
                 observing: (.observing // null),
                 idle_for_seconds: (if .last_active_epoch then ((now | floor) - .last_active_epoch) else null end),
                 stops_in_seconds: (if .last_active_epoch and .idle_window_seconds then
                                      ([((.idle_window_seconds | floor) - ((now | floor) - .last_active_epoch)), 0] | max) else null end),
                 observation: (.observation // null),
                 stop_error: (.stop_error // null)
               } else null end),
        last_stop: (if (($current and $running) | not) and .stopped_at then {at: .stopped_at, reason: (.stop_reason // "")}
                    elif .last_stop then .last_stop
                    else null end)
      }'
}

ROWS="[]"
BROWSERS="[]"
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
    if [ "$SELECTED_JSON" != "null" ] && ! printf '%s' "$SELECTED_JSON" | jq -e --arg n "$p_name" 'index($n) != null' >/dev/null; then
      continue
    fi
    p_role="$(printf '%s' "$pane_json" | jq -r '.role')"
    p_runtime="$(printf '%s' "$pane_json" | jq -r '.runtime.name')"
    p_model="$(printf '%s' "$pane_json" | jq -r '.agent.model // "inherit"')"
    p_cwd="$(printf '%s' "$pane_json" | jq -r '.cwd // "(unresolved)"')"
    p_browser="$(printf '%s' "$pane_json" | jq -r '.browser // false')"
    p_port="$(printf '%s' "$pane_json" | jq -r '.port // empty')"

    found_pane="" cur_cmd="" managed=0 dead=0 launched=0
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
        sw_pane_launched "$found_pane" && launched=1
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

    running=false
    [ "$health" = "healthy" ] && [ "$launched" -eq 1 ] && running=true

    readiness="n/a"
    if [ "$(printf '%s' "$PLAN_JSON" | jq -r '.schema_version')" = "5" ] && [ -n "$p_port" ] && [ "$p_browser" != "true" ]; then
      readiness="$(python3 "$HERE/service-ports.py" probe "$p_port")"
    fi
    endpoint="null"
    if [ "$p_browser" = "true" ]; then
      endpoint="$(_sw_browser_endpoint "$p_port")"
      case "$(printf '%s' "$endpoint" | jq -r '.up')" in
        true) readiness="ready" ;;
        null) readiness="unknown-curl-missing" ;;
        *) readiness="not-ready" ;;
      esac
      BROWSERS="$(printf '%s' "$BROWSERS" | jq -c --arg pane "$p_name" --arg sid "$s_id" --argjson e "$endpoint" --argjson running "$running" \
        '. + [$e + {pane: $pane, session: $sid, running: $running}]')"
    fi
    run_record="$(_sw_pane_run_record "$p_name" "$found_pane" "$running")"

    row="$(jq -n \
      --arg session "$s_id" --arg session_name "$s_name" \
      --arg pane "$p_name" --arg role "$p_role" --arg runtime "$p_runtime" \
      --arg model "$p_model" --arg cwd "$p_cwd" --arg pane_id "${found_pane:-}" \
      --arg process "${cur_cmd:-}" --arg health "$health" --arg readiness "$readiness" --arg port "$p_port" \
      --argjson read_paths "$(printf '%s' "$pane_json" | jq -c '.read_paths // []')" \
      --argjson session_exists "$session_exists" --argjson session_managed "$session_managed" \
      --argjson running "$running" --argjson endpoint "$endpoint" --argjson run_record "$run_record" \
      --argjson idle_stop_minutes "$(printf '%s' "$pane_json" | jq -c '.idle_stop_minutes // null')" \
      --argjson idle_activity "$(printf '%s' "$pane_json" | jq -c '.idle_activity // null')" \
      '{session:$session, session_name:$session_name, session_exists:($session_exists == 1), session_managed:($session_managed == 1), pane:$pane, role:$role, runtime:$runtime, model:$model, cwd:$cwd, read_paths:$read_paths, pane_id:$pane_id, process:$process, health:$health, running:$running, readiness:$readiness, port:(if $port == "" then null else ($port|tonumber) end), idle_stop_minutes:$idle_stop_minutes, idle_activity:$idle_activity, idle:$run_record.idle, last_stop:$run_record.last_stop}
       + (if $endpoint == null then {} else {endpoint:$endpoint} end)')"
    ROWS="$(printf '%s' "$ROWS" | jq -c --argjson r "$row" '. + [$r]')"
  done < <(printf '%s' "$session_json" | jq -c '.panes[]')
done < <(printf '%s' "$PLAN_JSON" | jq -c '.sessions[]')

if [ "$JSON_MODE" -eq 1 ]; then
  printf '%s\n' "$ROWS" | jq '.'
  exit 0
fi

echo "session-workspace status — $CONFIG_PATH (project: $PROJECT_ID)"
# One health line per browser, ahead of the per-session detail.
printf '%s\n' "$BROWSERS" | jq -r '
  .[] | "browser: \(.pane) \(.url) — " +
    (if .up == true then "up (\(.browser))"
     elif .up == null then "unknown (curl is not installed)"
     elif .running then "down (pane running, but /json/version does not answer yet)"
     else "down (pane not running; start it with: workspace start \(.session) --pane \(.pane))" end) +
    (if .cdp_clients == null then "" else "  cdp_clients=\(.cdp_clients)" end)
'
printf '%s\n' "$ROWS" | jq -r '
  def dur: if . == null then "?" else (. / 60 | floor | tostring) + "m" + (. % 60 | tostring) + "s" end;
  group_by(.session_name)[] |
  "== session: \(.[0].session_name) == (exists=\(.[0].session_exists) managed=\(.[0].session_managed))",
  (.[] | "  pane: \(.pane)  role=\(.role) runtime=\(.runtime) model=\(.model)\n    cwd=\(.cwd)\n    pane_id=\(.pane_id // "(none)")  process=\(.process // "(n/a)")  health=\(.health)  running=\(if .running then "yes" else "no" end)  readiness=\(.readiness)",
    (if (.read_paths | length) > 0 then "    read_paths (shell only): " + (.read_paths | tojson) else empty end),
    (if .idle != null then
       "    idle stop: \(.idle.minutes) min — watcher \(.idle.watcher), observing \(.idle.observing // "nothing yet"), "
       + (if (.idle.activity // ["connections"]) | any(. == "connections") then
            "clients=\(.idle.clients // "?")" + (if (.idle.recently_closed // 0) > 0 then " (+\(.idle.recently_closed) closed in the last 60s)" else "" end) + ", "
          else "" end)
       + "idle for \(.idle.idle_for_seconds | dur), stops in \(.idle.stops_in_seconds | dur)"
       + (if .idle.observation then " (" + .idle.observation + ")" else "" end)
       + (if .idle.stop_error then " (last stop attempt failed: " + .idle.stop_error + ")" else "" end)
     elif .idle_stop_minutes != null then
       "    idle stop: \(.idle_stop_minutes) min" + (if .idle_activity != null then " on \(.idle_activity | join("+"))" else "" end) + " (armed when the pane starts)"
     else empty end),
    (if .last_stop != null then "    last stop: \(.last_stop.at) — \(.last_stop.reason)" else empty end))
'
exit 0
