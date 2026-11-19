#!/usr/bin/env bash
# workspace-show.sh — session-workspace 'show' verb (schema v6 with `peers`,
# 0.17.0); `workspace hide NAME` runs this script with --hide.
#
# A worker pane lives in its owner's tmux session. Shown, it is a pane of the
# orchestrator's window; hidden, it is alone in a window of its own, sized by
# SESSION_WORKSPACE_HIDDEN_SIZE (COLSxROWS, default 160x48). `show NAME` joins
# the pane into the orchestrator's window and reapplies the session's standard
# layout; `hide NAME` breaks it back out into its own window. Both keep the
# pane id and the running process, are idempotent, and record the new state in
# instances.json under the project lock. NAME is a worker's full pane name or
# the part after "<project.id>-".
#
# Only the owner or the user may show or hide a worker: another orchestrator
# gets `[held] <session> / <pane> — owner X` and exit 3 with nothing changed,
# and a worker pane may do neither. A worker that is not running is
# `[absent]` (exit 1). If tmux refuses the move (no room in the window) the
# command exits 1 and the record is unchanged.
#
# Usage: workspace-show.sh NAME [--config PATH]
#        workspace-show.sh --hide NAME [--config PATH]      (what `workspace hide` runs)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/config.sh"
source "$HERE/validate-config.sh"
source "$HERE/tmux-lib.sh"
source "$HERE/instances.sh"

MODE="show"
usage() {
  echo "Usage: workspace-show.sh NAME [--config PATH]" >&2
  echo "       workspace-hide.sh NAME [--config PATH]" >&2
}

NAME_ARG=""
CONFIG_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      if [ $# -lt 2 ] || [ -z "$2" ]; then usage; exit 1; fi
      CONFIG_OVERRIDE="$2"; shift 2 ;;
    --hide) MODE="hide"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage; exit 1 ;;
    *)
      if [ -n "$NAME_ARG" ]; then echo "ERROR: unexpected argument: $1" >&2; usage; exit 1; fi
      NAME_ARG="$1"; shift ;;
  esac
done
if [ -z "$NAME_ARG" ]; then
  usage
  exit 1
fi

ensure_jq
ensure_tmux
sw_tmux_bind

CONFIG_PATH="$(resolve_project_config_path "$CONFIG_OVERRIDE")" || exit 1
CONFIG_JSON="$(load_workspace_config_raw "$CONFIG_PATH")" || exit 1
if ! validate_workspace_config "$CONFIG_JSON" "$CONFIG_PATH"; then
  echo "ERROR: config failed validation: $CONFIG_PATH" >&2
  print_validation_errors
  exit 1
fi
PROJECT_ID="$(printf '%s' "$CONFIG_JSON" | jq -r '.project.id')"
if ! sw_inst_peers "$CONFIG_JSON"; then
  echo "ERROR: workspace $MODE needs a schema-6 config with peers" >&2
  exit 1
fi
if [ "$MODE" = "hide" ]; then
  # Fail before anything is touched when the hidden size is unusable.
  sw_hidden_size >/dev/null || exit 1
fi

sw_inst_normalize_state_home
sw_lock_acquire "$PROJECT_ID" || exit 1
sw_inst_begin
sw_caller_check_worker_verb "$MODE a worker" 0 ""

ROW="$(sw_worker_resolve "$CONFIG_JSON" "$NAME_ARG")"
if [ -z "$ROW" ]; then
  echo "ERROR: no worker \"$NAME_ARG\" (workers: $(printf '%s' "$CONFIG_JSON" | jq -r '[(.sessions // [])[] | (.panes // [])[] | select(.worker != null) | .name] | if length == 0 then "none" else join(", ") end'))" >&2
  exit 1
fi
W_NAME="$(printf '%s' "$ROW" | jq -r '.name')"
S_NAME="$(printf '%s' "$ROW" | jq -r '.session_name')"
S_WIN="$(printf '%s' "$ROW" | jq -r '.window_index')"
S_LAYOUT="$(printf '%s' "$ROW" | jq -r '.layout')"
W_OWNER="$(printf '%s' "$ROW" | jq -r '.worker.owner')"
W_CHECKOUT="$(printf '%s' "$ROW" | jq -r '.worker.checkout')"
W_ROLE="$(printf '%s' "$ROW" | jq -r '.worker.role')"
W_LABEL="$(printf '%s' "$ROW" | jq -r '.worker["label"]')"

sw_caller_require_owner "$S_NAME" "$W_NAME" "$W_OWNER"
# The owner's window is the one that holds the orchestrator pane, wherever the
# window sits now; the configured index is only the fallback.
S_WIN="$(sw_owner_window_index "$S_NAME" "$W_OWNER" "$S_WIN")"

FOUND=""
if tmux has-session -t "=$S_NAME" 2>/dev/null && sw_session_is_managed "$S_NAME" "$PROJECT_ID"; then
  FOUND="$(sw_pane_find_session_wide "$S_NAME" "$W_NAME")" || FOUND=""
fi
if [ -z "$FOUND" ]; then
  sw_inst_report "absent" "$S_NAME" "$W_NAME" "not running; start it with: workspace start --checkout $W_CHECKOUT --role $W_ROLE${W_LABEL:+ --label $W_LABEL}"
  exit 1
fi
PANE_ID="${FOUND%%$'\t'*}"
PANE_WIN="${FOUND#*$'\t'}"

layout_window() {
  tmux select-layout -t "=$S_NAME:$S_WIN" "$S_LAYOUT" 2>/dev/null || true
}

if [ "$MODE" = "show" ]; then
  if [ "$PANE_WIN" = "$S_WIN" ]; then
    printf '  [shown] %s / %s (already)\n' "$S_NAME" "$W_NAME"
    # The record follows the pane: it may have been moved by hand.
    if [ "$(printf '%s' "$CONFIG_JSON" | jq -r --arg n "$W_NAME" '[(.sessions // [])[] | (.panes // [])[] | select(.name == $n) | .worker.visible][0]')" != "true" ]; then
      sw_inst_commit "$(sw_inst_set_visible "$W_CHECKOUT" "$W_ROLE" "$W_LABEL" true)" 0 || exit 1
    fi
    exit 0
  fi
  if ! join_err="$(tmux join-pane -d -s "$PANE_ID" -t "=$S_NAME:$S_WIN" 2>&1)"; then
    echo "ERROR: tmux could not join $W_NAME into the window of its orchestrator: ${join_err:-join-pane failed}" >&2
    exit 1
  fi
  layout_window
  sw_inst_commit "$(sw_inst_set_visible "$W_CHECKOUT" "$W_ROLE" "$W_LABEL" true)" 0 || exit 1
  sw_inst_report "shown" "$S_NAME" "$W_NAME" "$PANE_ID — now a pane of the orchestrator's window"
  exit 0
fi

# hide
if [ "$PANE_WIN" != "$S_WIN" ]; then
  printf '  [hidden] %s / %s (already)\n' "$S_NAME" "$W_NAME"
  if [ "$(printf '%s' "$CONFIG_JSON" | jq -r --arg n "$W_NAME" '[(.sessions // [])[] | (.panes // [])[] | select(.name == $n) | .worker.visible][0]')" != "false" ]; then
    sw_inst_commit "$(sw_inst_set_visible "$W_CHECKOUT" "$W_ROLE" "$W_LABEL" false)" 0 || exit 1
  fi
  exit 0
fi
# The destination session is named on purpose: without -t tmux picks a session
# from the client context, which is not the worker's owner.
if ! out="$(tmux break-pane -d -s "$PANE_ID" -t "=$S_NAME:" -n "$W_NAME" -P -F '#{pane_id} #{window_id}' 2>&1)"; then
  echo "ERROR: tmux could not move $W_NAME into a window of its own: ${out:-break-pane failed}" >&2
  exit 1
fi
sw_size_hidden_window "${out#* }" || true
layout_window
sw_inst_commit "$(sw_inst_set_visible "$W_CHECKOUT" "$W_ROLE" "$W_LABEL" false)" 0 || exit 1
sw_inst_report "hidden" "$S_NAME" "$W_NAME" "$PANE_ID — now in a window of its own"
exit 0
