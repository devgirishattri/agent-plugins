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
# `--pane NAME` (repeatable) starts only the named service panes, or
# executor/reviewer panes marked launch "on_demand", of ONE session: the
# session is created if needed with just those panes, their declared commands
# or agents run, and no other pane of the session is created or touched. A
# NAME is a pane's full name or the part after "<project.id>-". Each selected
# dev server's port must be free (or held by that pane's own live launch) or
# nothing is started and the holder's PID is named. Each selected agent pane
# must show and keep its input line within SESSION_WORKSPACE_AGENT_READY_TIMEOUT
# seconds (default 120) or the run fails, leaving the pane running. A --pane
# start never attaches: it brings panes up in the background. A full start
# leaves on-demand panes down (and keeps them when they already run).
#
# Peer orchestrators (schema v6 with `peers`, 0.17.0). Everything below happens
# under ONE hold of the project lock, in this order: reload the config, remove
# stale records of instances.json, work out who is calling (instances.sh), then
# the form's own work.
#   `start <peers.session>-N` (N 2..999, the user only) records the extra
#   orchestrator and starts its session; an id that is already recorded starts
#   like any session. A bare `start` / `start all` starts only the sessions
#   that are not copies, so records left over from a reboot do not bring the
#   copies back; a copy starts by name.
#   `start --checkout ID --role executor|reviewer [--label L] [--show]
#   [--owner PANE]` starts one worker of a checkout for an orchestrator (the
#   caller, or --owner for the user). The caller picks only checkout, role,
#   label and visibility; runtime, cwd, grants, secrets and launch argv come
#   from the configured role and checkout. A hidden worker (the default) gets a
#   window of its own in its owner's tmux session, sized by
#   SESSION_WORKSPACE_HIDDEN_SIZE (COLSxROWS, default 160x48); --show splits the
#   orchestrator's window instead. Exit 3 with a `[held] ... owner X` line when
#   another orchestrator holds the worker or its checkout, or left work under
#   that name; exit 1 with `[limit]` at a configured limit.
#
# Usage: workspace-start.sh [TARGET|all] [--config PATH]
#          [--no-agents] [--no-services] [--no-attach] [--adopt --confirmed]
#        workspace-start.sh SESSION --pane NAME [--pane NAME...] [--config PATH] [--no-attach]
#        workspace-start.sh --checkout ID --role executor|reviewer [--label L] [--show]
#          [--owner PANE] [--config PATH] [--no-attach]
# shellcheck disable=SC2034  # NO_AGENTS / NO_SERVICES / ALLOW_ADOPT / DRY_RUN / SW_PANE_SUBSET are
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
Usage: workspace-start.sh [TARGET|all] [--config PATH]
         [--no-agents] [--no-services] [--no-attach] [--adopt --confirmed]
       workspace-start.sh SESSION --pane NAME [--pane NAME...] [--config PATH] [--no-attach]
       workspace-start.sh --checkout ID --role executor|reviewer [--label L] [--show]
         [--owner PANE] [--config PATH] [--no-attach]
EOF
}

# Empty until the argv loop or behavior.default_start_target sets it, so
# "no TARGET given" is distinguishable from an explicit "all".
TARGET=""
TARGET_GIVEN=0
CONFIG_OVERRIDE=""
CHECKOUT_ARG=""
ROLE_ARG=""
LABEL_ARG=""
SHOW_FLAG=0
OWNER_ARG=""
NO_AGENTS=0
NO_SERVICES=0
NO_ATTACH=0
ADOPT_FLAG=0
CONFIRMED_FLAG=0
declare -a PANE_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_OVERRIDE="${2:-}"; shift 2 ;;
    --pane)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#-}" != "$2" ]; then
        echo "ERROR: --pane requires a pane name" >&2; usage; exit 1
      fi
      PANE_ARGS+=("$2"); shift 2 ;;
    --checkout|--role|--label|--owner)
      if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#-}" != "$2" ]; then
        echo "ERROR: $1 requires a value" >&2; usage; exit 1
      fi
      case "$1" in
        --checkout) CHECKOUT_ARG="$2" ;;
        --role) ROLE_ARG="$2" ;;
        --label) LABEL_ARG="$2" ;;
        --owner) OWNER_ARG="$2" ;;
      esac
      shift 2 ;;
    --show) SHOW_FLAG=1; shift ;;
    --no-agents) NO_AGENTS=1; shift ;;
    --no-services) NO_SERVICES=1; shift ;;
    --no-attach) NO_ATTACH=1; shift ;;
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
sw_tmux_bind --may-start

SW_PANE_SUBSET=0
if [ "${#PANE_ARGS[@]}" -gt 0 ]; then
  if [ -z "$TARGET" ] || [ "$TARGET" = "all" ]; then
    echo "ERROR: --pane needs one explicit session: workspace start SESSION --pane NAME" >&2
    exit 1
  fi
  if [ "$NO_AGENTS" -eq 1 ] || [ "$NO_SERVICES" -eq 1 ] || [ "$ADOPT_FLAG" -eq 1 ] || [ "$CONFIRMED_FLAG" -eq 1 ]; then
    echo "ERROR: --pane cannot be combined with --no-agents, --no-services, --adopt, or --confirmed" >&2
    exit 1
  fi
  SW_PANE_SUBSET=1
fi

# The worker form: the caller chooses a checkout, a role, a label and whether
# the pane is shown, nothing else.
WORKER_FORM=0
if [ -n "$CHECKOUT_ARG" ]; then
  WORKER_FORM=1
  if [ "$TARGET_GIVEN" -eq 1 ] || [ "${#PANE_ARGS[@]}" -gt 0 ] || [ "$NO_AGENTS" -eq 1 ] || [ "$NO_SERVICES" -eq 1 ] || [ "$ADOPT_FLAG" -eq 1 ] || [ "$CONFIRMED_FLAG" -eq 1 ]; then
    echo "ERROR: --checkout cannot be combined with a session, --pane, --no-agents, --no-services, --adopt, or --confirmed" >&2
    exit 1
  fi
  case "$ROLE_ARG" in
    executor|reviewer) ;;
    *) echo "ERROR: --checkout needs --role executor or --role reviewer" >&2; exit 1 ;;
  esac
  if [ -n "$LABEL_ARG" ] && ! [[ "$LABEL_ARG" =~ $SW_WORKER_LABEL_RE ]]; then
    echo "ERROR: a label is 1-24 characters of a-z, 0-9 and -, starting with a letter or digit: $LABEL_ARG" >&2
    exit 1
  fi
elif [ -n "$ROLE_ARG" ] || [ -n "$LABEL_ARG" ] || [ -n "$OWNER_ARG" ] || [ "$SHOW_FLAG" -eq 1 ]; then
  echo "ERROR: --role, --label, --show and --owner belong to: workspace start --checkout ID --role executor|reviewer" >&2
  exit 1
fi

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
PEERS=0
sw_inst_peers "$CONFIG_JSON" && PEERS=1
# One state home for the lock and the registry (instances.sh).
[ "$PEERS" -eq 1 ] && sw_inst_normalize_state_home
if [ "$WORKER_FORM" -eq 1 ] && [ "$PEERS" -eq 0 ]; then
  echo "ERROR: --checkout needs a schema-6 config with peers" >&2
  exit 1
fi

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

# A peers config also accepts <peers.session>-N (N 2..999) for a copy that is
# not recorded. Whether the id is recorded, new, an orchestrator session the
# caller may not touch, or unknown is decided under the lock after the stale
# records are removed (COPY_NEW below): a copy closed from outside is a stale
# record until then, and a decision taken before the lock would find it
# recorded and then have nothing to start.
COPY_NEW=0
COPY_INDEX=""
if [ "$WORKER_FORM" -eq 0 ] && [ "$TARGET" != "all" ] && [ "$PEERS" -eq 0 ]; then
  if ! printf '%s' "$CONFIG_JSON" | jq -e --arg t "$TARGET" '[(.sessions // [])[].id] | index($t) != null' >/dev/null; then
    echo "ERROR: unknown session target \"$TARGET\"" >&2
    exit 1
  fi
fi

sw_lock_acquire "$PROJECT_ID" || exit 1

ADDED_WORKER=""      # "checkout<TAB>role<TAB>label" of a record this run added
ADDED_COPY=""        # index of a copy this run recorded
COPY_SESSION_NAME="" # its tmux session name (the target id is not a tmux name)
if [ "$PEERS" -eq 1 ]; then
  sw_inst_begin
  if [ "$WORKER_FORM" -eq 1 ]; then
    sw_caller_check_worker_verb "start a worker" 0 "$OWNER_ARG"
  elif [ "${#PANE_ARGS[@]}" -gt 0 ]; then
    sw_caller_check_worker_verb "start panes" 0 ""
  else
    sw_caller_check_session_verb start "$TARGET_GIVEN" "$TARGET" 0 0 "$OWNER_ARG"
    if [ "$TARGET" != "all" ] && ! printf '%s' "$CONFIG_JSON" | jq -e --arg t "$TARGET" '[(.sessions // [])[].id] | index($t) != null' >/dev/null; then
      COPY_PS="$(printf '%s' "$CONFIG_JSON" | jq -r '.peers.session // ""')"
      if [[ "$TARGET" =~ ^${COPY_PS}-([2-9]|[1-9][0-9]|[1-9][0-9][0-9])$ ]]; then
        COPY_NEW=1
        COPY_INDEX="${BASH_REMATCH[1]}"
      else
        echo "ERROR: unknown session target \"$TARGET\"" >&2
        exit 1
      fi
    fi
  fi
fi

# --- peers: a new orchestrator copy --------------------------------------------
if [ "$COPY_NEW" -ne 0 ]; then
  if ! printf '%s' "$CONFIG_JSON" | jq -e --arg t "$TARGET" 'any((.sessions // [])[]; .id == $t)' >/dev/null; then
    LIMIT_ORCH="$(printf '%s' "$CONFIG_JSON" | jq -r '.peers.limits.orchestrators // empty')"
    HAVE_ORCH="$(printf '%s' "$CONFIG_JSON" | jq '[(.sessions // [])[] | select(.instance != null)] | length')"
    if [ -n "$LIMIT_ORCH" ] && [ "$HAVE_ORCH" -ge "$LIMIT_ORCH" ]; then
      echo "  [limit] $TARGET — peers.limits.orchestrators is $LIMIT_ORCH and $HAVE_ORCH orchestrator session(s) are recorded"
      exit 1
    fi
    sw_inst_commit "$(sw_inst_with_orchestrator "$COPY_INDEX")" || exit 1
    if ! printf '%s' "$CONFIG_JSON" | jq -e --arg t "$TARGET" 'any((.sessions // [])[]; .id == $t)' >/dev/null; then
      echo "ERROR: could not record orchestrator session \"$TARGET\"" >&2
      exit 1
    fi
    ADDED_COPY="$COPY_INDEX"
    COPY_SESSION_NAME="$(printf '%s' "$CONFIG_JSON" | jq -r --arg t "$TARGET" '[(.sessions // [])[] | select(.id == $t) | .name][0] // ""')"
  fi
fi

# --- peers: one worker for an orchestrator -------------------------------------
if [ "$WORKER_FORM" -eq 1 ]; then
  if [ "$SW_CALLER_KIND" = "orchestrator" ]; then
    WORKER_OWNER="$SW_CALLER_NAME"
  else
    WORKER_OWNER="$OWNER_ARG"
    if [ -z "$WORKER_OWNER" ]; then
      echo "ERROR: --owner PANE is required: name the orchestrator pane that owns the worker" >&2
      exit 1
    fi
  fi
  OWNER_ROW="$(printf '%s' "$CONFIG_JSON" | jq -c --arg o "$WORKER_OWNER" '
    (.harness.roles.orchestrator // "") as $orole
    | [(.sessions // [])[] | . as $s | (.panes // [])[] | select(.name == $o and .role == $orole)
       | {session_id: $s.id, session_name: $s.name}][0] // empty')"
  if [ -z "$OWNER_ROW" ]; then
    echo "ERROR: --owner must name an orchestrator pane of this config: $WORKER_OWNER" >&2
    exit 1
  fi
  OWNER_SESSION_ID="$(printf '%s' "$OWNER_ROW" | jq -r '.session_id')"
  OWNER_SESSION_NAME="$(printf '%s' "$OWNER_ROW" | jq -r '.session_name')"
  if ! printf '%s' "$CONFIG_JSON" | jq -e --arg c "$CHECKOUT_ARG" 'any((.environments // [])[]; .id == $c)' >/dev/null; then
    echo "ERROR: unknown checkout \"$CHECKOUT_ARG\" (checkouts: $(printf '%s' "$CONFIG_JSON" | jq -r '[(.environments // [])[].id] | join(", ")'))" >&2
    exit 1
  fi
  if [ "$SHOW_FLAG" -eq 0 ]; then
    sw_hidden_size >/dev/null || exit 1
  fi
  if ! tmux has-session -t "=$OWNER_SESSION_NAME" 2>/dev/null || ! sw_session_is_managed "$OWNER_SESSION_NAME" "$PROJECT_ID"; then
    echo "ERROR: the tmux session of $WORKER_OWNER (\"$OWNER_SESSION_NAME\") is not running; start it first: workspace start $OWNER_SESSION_ID" >&2
    exit 1
  fi
  WORKER_NAME="$(sw_worker_name "$CONFIG_JSON" "$CHECKOUT_ARG" "$ROLE_ARG" "$LABEL_ARG")"
  # The same worker: kept for its owner, held against any other orchestrator.
  EXISTING="$(printf '%s' "$CONFIG_JSON" | jq -c --arg c "$CHECKOUT_ARG" --arg r "$ROLE_ARG" --arg l "$LABEL_ARG" '
    [(.sessions // [])[] | . as $s | (.panes // [])[] | select(.worker != null and .worker.checkout == $c and .worker.role == $r and .worker["label"] == $l)
     | {name, session: $s.name, owner: .worker.owner}][0] // empty')"
  if [ -n "$EXISTING" ]; then
    EX_OWNER="$(printf '%s' "$EXISTING" | jq -r '.owner')"
    if [ "$EX_OWNER" != "$WORKER_OWNER" ]; then
      sw_inst_report "held" "$(printf '%s' "$EXISTING" | jq -r '.session')" "$WORKER_NAME" "owner $EX_OWNER"
      exit 3
    fi
  else
    # A checkout that runs one executor at a time (the default).
    if [ "$ROLE_ARG" = "executor" ]; then
      ONE_EXEC="$(printf '%s' "$CONFIG_JSON" | jq -r --arg c "$CHECKOUT_ARG" '[(.environments // [])[] | select(.id == $c)][0].executors // "one"')"
      OTHER="$(printf '%s' "$CONFIG_JSON" | jq -c --arg c "$CHECKOUT_ARG" '
        [(.sessions // [])[] | . as $s | (.panes // [])[] | select(.worker != null and .worker.checkout == $c and .worker.role == "executor")
         | {name, session: $s.name, owner: .worker.owner}][0] // empty')"
      if [ "$ONE_EXEC" = "one" ] && [ -n "$OTHER" ]; then
        sw_inst_report "held" "$(printf '%s' "$OTHER" | jq -r '.session')" "$WORKER_NAME"           "$CHECKOUT_ARG runs one executor at a time: $(printf '%s' "$OTHER" | jq -r '.name'), owner $(printf '%s' "$OTHER" | jq -r '.owner')"
        exit 3
      fi
    fi
    # Work another owner left under this name stays with that owner.
    LEFT_PLAN="$(bash "$HERE/workspace-plan.sh" --config "$CONFIG_PATH" --json)" || exit 1
    sw_worker_store_args "$LEFT_PLAN" "$WORKER_NAME"
    if [ "${#SW_STORE_ARGS[@]}" -gt 0 ]; then
      command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required to check for work another owner left under $WORKER_NAME" >&2; exit 1; }
      if ! LEFT_OUT="$(python3 "$HERE/agent-pane.py" leftover --pane "$WORKER_NAME" --owner "$WORKER_OWNER" "${SW_STORE_ARGS[@]}")"; then
        IFS=$'\t' read -r LEFT_REASON LEFT_OTHER <<<"$(printf '%s\n' "$LEFT_OUT" | head -n1)"
        sw_inst_report "held" "$OWNER_SESSION_NAME" "$WORKER_NAME" "${LEFT_REASON:-unfinished work}; owner ${LEFT_OTHER:-unknown}"
        exit 3
      fi
    fi
    LIMIT_WORKERS="$(printf '%s' "$CONFIG_JSON" | jq -r '.peers.limits.workers_per_orchestrator // empty')"
    OWNED="$(printf '%s' "$CONFIG_JSON" | jq --arg o "$WORKER_OWNER" '[(.sessions // [])[] | (.panes // [])[] | select(.worker != null and .worker.owner == $o)] | length')"
    if [ -n "$LIMIT_WORKERS" ] && [ "$OWNED" -ge "$LIMIT_WORKERS" ]; then
      echo "  [limit] $OWNER_SESSION_NAME / $WORKER_NAME — peers.limits.workers_per_orchestrator is $LIMIT_WORKERS and $WORKER_OWNER already owns $OWNED"
      exit 1
    fi
    VISIBLE_JSON=false
    [ "$SHOW_FLAG" -eq 1 ] && VISIBLE_JSON=true
    sw_inst_commit "$(sw_inst_with_worker "$CHECKOUT_ARG" "$ROLE_ARG" "$LABEL_ARG" "$WORKER_OWNER" "$VISIBLE_JSON")" || exit 1
    if ! printf '%s' "$CONFIG_JSON" | jq -e --arg n "$WORKER_NAME" --arg o "$WORKER_OWNER" 'any((.sessions // [])[].panes[]?; .name == $n and .worker.owner == $o)' >/dev/null; then
      echo "ERROR: could not record worker $WORKER_NAME" >&2
      exit 1
    fi
    ADDED_WORKER="$CHECKOUT_ARG"$'\t'"$ROLE_ARG"$'\t'"$LABEL_ARG"
  fi
  TARGET="$OWNER_SESSION_ID"
  PANE_ARGS=("$WORKER_NAME")
  SW_PANE_SUBSET=1
fi

PLAN_JSON="$(bash "$HERE/workspace-plan.sh" --config "$CONFIG_PATH" --json)" || exit 1

# A bare start leaves the orchestrator copies alone: leftover records after a
# reboot must not bring them back. A copy starts by name.
if [ "$PEERS" -eq 1 ] && [ "$TARGET" = "all" ]; then
  PLAN_JSON="$(printf '%s' "$PLAN_JSON" | jq -c '.sessions |= map(select((.instance.index // 1) == 1))')"
fi

declare -a SELECTED_PANES=()
if [ "$SW_PANE_SUBSET" -eq 1 ]; then
  SELECTED_LIST="$(sw_select_panes "$PLAN_JSON" "$TARGET" "${PANE_ARGS[@]}")" || exit 1
  while IFS= read -r selected_pane; do
    [ -n "$selected_pane" ] && SELECTED_PANES+=("$selected_pane")
  done <<<"$SELECTED_LIST"
  if [ "$PEERS" -eq 1 ] && [ "$WORKER_FORM" -eq 0 ]; then
    for selected_pane in "${SELECTED_PANES[@]}"; do
      HELD_ROW="$(printf '%s' "$CONFIG_JSON" | jq -r --arg n "$selected_pane" '
        [(.sessions // [])[] | . as $s | (.panes // [])[] | select(.name == $n and .worker != null) | $s.name + "\t" + .worker.owner][0] // empty')"
      if [ -n "$HELD_ROW" ]; then
        IFS=$'\t' read -r HELD_SESSION HELD_OWNER <<<"$HELD_ROW"
        sw_caller_require_owner "$HELD_SESSION" "$selected_pane" "$HELD_OWNER"
      fi
    done
  fi
  SELECTED_JSON="$(printf '%s\n' "${SELECTED_PANES[@]}" | jq -R . | jq -sc .)"
  UNRESOLVED="$(printf '%s' "$PLAN_JSON" | jq -r --arg t "$TARGET" --argjson sel "$SELECTED_JSON" \
    '.sessions[] | select(.id == $t) | .panes[] | select((.name as $n | $sel | index($n)) != null and (.skip_unresolved // false)) | .name')"
  if [ -n "$UNRESOLVED" ]; then
    echo "ERROR: --pane: optional pane(s) with an unresolved cwd cannot start: $(printf '%s' "$UNRESOLVED" | tr '\n' ' ')" >&2
    exit 1
  fi
  # Narrow the plan to the selected panes of TARGET. .all_panes keeps the
  # whole session for the session-env pin (see lifecycle.sh).
  PLAN_JSON="$(printf '%s' "$PLAN_JSON" | jq -c --arg t "$TARGET" --argjson sel "$SELECTED_JSON" '
    .sessions |= map(if .id == $t then (.all_panes = .panes | .panes |= map(select(.name as $n | $sel | index($n) != null))) else . end)')"
fi

sw_require_available_read_paths "$PLAN_JSON" "$TARGET" || exit 1

# Port safety. A whole-session start keeps its schema-v5-only preflight; a
# --pane start checks every selected dev server on every schema version,
# because starting one service next to an executor's own `pnpm dev` is exactly
# the collision --pane exists to avoid.
if [ "$SW_PANE_SUBSET" -eq 1 ]; then
  if printf '%s' "$PLAN_JSON" | jq -e --arg t "$TARGET" 'any(.sessions[] | select(.id == $t) | .panes[]; (.browser | not) and .port != null and .command != null)' >/dev/null; then
    command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required to check that a --pane dev server's port is free" >&2; exit 1; }
    printf '%s' "$PLAN_JSON" | python3 "$HERE/service-ports.py" "$TARGET" "${SELECTED_PANES[@]}" || exit 1
  fi
elif printf '%s' "$PLAN_JSON" | jq -e '.schema_version == 5 or .schema_version == 6' >/dev/null && [ "$NO_SERVICES" -eq 0 ]; then
  printf '%s' "$PLAN_JSON" | python3 "$HERE/service-ports.py" "$TARGET" || exit 1
fi

declare -a BROWSER_PORTS=()
while IFS= read -r browser_json; do
  BROWSER_SESSION_ID="$(printf '%s' "$browser_json" | jq -r '.session_id')"
  BROWSER_PORT="$(printf '%s' "$browser_json" | jq -r '.port')"
  BROWSER_PANE="$(printf '%s' "$browser_json" | jq -r '.pane_name // ""')"
  if [ "$SW_PANE_SUBSET" -eq 1 ]; then
    # A --pane start claims and waits for a browser only when its pane is selected.
    printf '%s\n' "${SELECTED_PANES[@]}" | grep -Fxq -- "$BROWSER_PANE" || continue
  fi
  if { [ "$TARGET" = "all" ] || [ "$TARGET" = "$BROWSER_SESSION_ID" ]; } && [ "$NO_SERVICES" -eq 0 ]; then
    command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required to verify browser readiness" >&2; exit 1; }
    sw_browser_claim_port "$PROJECT_ID" "$BROWSER_PORT" || exit 1
    mkdir -p "$(printf '%s' "$browser_json" | jq -r '.profile_dir')" || exit 1
    BROWSER_PORTS+=("$BROWSER_PORT")
  fi
done < <(printf '%s' "$PLAN_JSON" | jq -c '(.browsers // (if .browser != null then [.browser] else [] end))[]')

if [ "$SW_PANE_SUBSET" -eq 1 ]; then
  echo "session-workspace start — $CONFIG_PATH (project: $PROJECT_ID, session: $TARGET, panes: ${SELECTED_PANES[*]})"
else
  echo "session-workspace start — $CONFIG_PATH (project: $PROJECT_ID)"
fi
if [ "$WORKER_FORM" -eq 1 ]; then
  printf 'worker: %s (checkout %s, role %s, owner %s, %s)\n' "$WORKER_NAME" "$CHECKOUT_ARG" "$ROLE_ARG" "$WORKER_OWNER" \
    "$(printf '%s' "$CONFIG_JSON" | jq -r --arg n "$WORKER_NAME" 'if any((.sessions // [])[].panes[]?; .name == $n and .worker.visible == true) then "shown" else "hidden" end')"
fi
sw_process_plan "$PLAN_JSON" "$TARGET"

# A record this run added is taken back when its pane or session did not come
# up, so a failed start leaves no claim on the name.
if [ "$SW_FAILED_SLOTS" -gt 0 ] && [ "$PEERS" -eq 1 ]; then
  if [ -n "$ADDED_WORKER" ]; then
    IFS=$'\t' read -r AW_CHECKOUT AW_ROLE AW_LABEL <<<"$ADDED_WORKER"
    # The window this run made for the pane is closed with it when the pane
    # never got its marker. Only that window id: a window of the user's with
    # the same name is not ours.
    if [ -n "$SW_HIDDEN_WINDOW_ID" ] &&
       [ -z "$(tmux list-panes -t "$SW_HIDDEN_WINDOW_ID" -F "#{$MARKER_PANE}" 2>/dev/null | tr -d '\n')" ]; then
      tmux kill-window -t "$SW_HIDDEN_WINDOW_ID" 2>/dev/null || true
    fi
    sw_inst_commit "$(sw_inst_drop_worker "$AW_CHECKOUT" "$AW_ROLE" "$AW_LABEL")" 0 || true
  elif [ -n "$ADDED_COPY" ] && ! tmux has-session -t "=$COPY_SESSION_NAME" 2>/dev/null; then
    sw_inst_commit "$(sw_read_instances "$PROJECT_ID" | jq -c --argjson n "$ADDED_COPY" '.orchestrators |= map(select(.index != $n))')" 0 || true
  fi
fi
if [ "$PEERS" -eq 1 ]; then sw_inst_cleanup; fi

# The project lock covers the tmux changes above, not the readiness waits
# below: an agent can take up to SESSION_WORKSPACE_AGENT_READY_TIMEOUT (120 s)
# to draw its input line, and another orchestrator's start or stop must not
# time out behind it. A pane stopped meanwhile is reported as not ready.
sw_lock_release

for BROWSER_PORT in "${BROWSER_PORTS[@]:-}"; do
  [ -n "$BROWSER_PORT" ] || continue
  if [ "$SW_FAILED_SLOTS" -eq 0 ]; then
  if sw_browser_wait_ready "$BROWSER_PORT"; then
    echo "  [ready]  browser DevTools endpoint http://127.0.0.1:$BROWSER_PORT"
  else
    echo "  [failed] browser DevTools endpoint did not become ready on 127.0.0.1:$BROWSER_PORT" >&2
    SW_FAILED_SLOTS=$((SW_FAILED_SLOTS + 1))
  fi
  fi
done

# An on-demand worker is ready when its agent keeps an input line on screen, so a
# message sent right after this command lands in it. A pane that does not get
# there in time is reported and left running for a look, and the run fails.
if [ "$SW_PANE_SUBSET" -eq 1 ] && [ "$SW_FAILED_SLOTS" -eq 0 ]; then
  AGENT_SELECTED="$(printf '%s' "$PLAN_JSON" | jq -r --arg t "$TARGET" '.sessions[] | select(.id == $t) | .panes[] | select(.runtime.name != "shell") | .name')"
  if [ -n "$AGENT_SELECTED" ]; then
    SEL_SESSION_NAME="$(printf '%s' "$PLAN_JSON" | jq -r --arg t "$TARGET" '.sessions[] | select(.id == $t) | .name')"
    SEL_WINDOW="$(printf '%s' "$PLAN_JSON" | jq -r --arg t "$TARGET" '.sessions[] | select(.id == $t) | .window_index // 0')"
    if ! command -v python3 >/dev/null 2>&1; then
      echo "ERROR: python3 is required to wait for an on-demand worker's agent to be ready" >&2
      SW_FAILED_SLOTS=$((SW_FAILED_SLOTS + 1))
    else
      while IFS= read -r agent_pane; do
        [ -n "$agent_pane" ] || continue
        # A worker of a peers config may sit in a window of its own (hidden), so
        # its lookup covers the whole session.
        ready_scope=(-t "=$SEL_SESSION_NAME:$SEL_WINDOW")
        if printf '%s' "$PLAN_JSON" | jq -e --arg t "$TARGET" --arg n "$agent_pane" 'any(.sessions[] | select(.id == $t) | .panes[]; .name == $n and (.worker // null) != null)' >/dev/null; then
          ready_scope=(-s -t "=$SEL_SESSION_NAME")
        fi
        agent_pane_id="$(tmux list-panes "${ready_scope[@]}" -F "$(printf '#{pane_id}\t#{%s}' "$MARKER_PANE")" 2>/dev/null |
          awk -F'\t' -v n="$agent_pane" '$2 == n {print $1; exit}')"
        if [ -z "$agent_pane_id" ]; then
          echo "  [not ready] $SEL_SESSION_NAME / $agent_pane — no pane carries its marker" >&2
          SW_FAILED_SLOTS=$((SW_FAILED_SLOTS + 1))
        elif ready_out="$(python3 "$HERE/agent-pane.py" ready --pane-id "$agent_pane_id" 2>&1)"; then
          echo "  [ready] $SEL_SESSION_NAME / $agent_pane — agent input line on screen"
        else
          echo "  [not ready] $SEL_SESSION_NAME / $agent_pane — ${ready_out:-agent did not become ready}; the pane is left running" >&2
          SW_FAILED_SLOTS=$((SW_FAILED_SLOTS + 1))
        fi
      done <<<"$AGENT_SELECTED"
    fi
  fi
fi

echo
echo "started/adopted: $SW_CHANGED  kept (already healthy): $SW_KEPT  failed: $SW_FAILED_SLOTS"

if [ "$SW_FAILED_SLOTS" -gt 0 ]; then
  exit 1
fi

# Attach (behavior.attach), only after a fully successful start. The session
# is the explicit/default TARGET when that names one; for "all" it is the
# first session in the plan, matching the order `workspace-plan` displays.
if [ "$NO_ATTACH" -eq 1 ]; then
  echo "attach: suppressed by --no-attach"
elif [ "$SW_PANE_SUBSET" -eq 1 ]; then
  echo "attach: skipped (--pane starts panes in the background)"
else
  if [ "$TARGET" != "all" ]; then
    ATTACH_SESSION="$(printf '%s' "$PLAN_JSON" | jq -r --arg t "$TARGET" 'first(.sessions[] | select(.id == $t) | .name) // ""')"
  else
    ATTACH_SESSION="$(printf '%s' "$PLAN_JSON" | jq -r '(.sessions[0].name) // ""')"
  fi
  sw_attach_session "$ATTACH_MODE" "$ATTACH_SESSION"
fi

exit 0
