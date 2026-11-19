#!/usr/bin/env bash
# workspace-label.sh — session-workspace 'label' verb (schema v5, 0.16.0).
#
# An environment's executor and reviewer panes that leave out `name` in the
# config are named <project.id>-<environment>-<executor|reviewer>, plus
# -<label> once the environment has a label (config.sh). This verb shows or
# sets that label. The coordinator picks only the label; the engine builds
# the names, checks under the project lock that the config still validates
# with them (names stay unique), and keeps the label in the project state
# file labels.json, so the names survive restarts until the label is set
# again or cleared.
#
# A label changes only while every worker pane of that environment is
# stopped: run records, session-chat queues and scheduler assignments are
# keyed by pane name, and a running pane is pinned to the name it started
# with.
#
# Usage: workspace-label.sh ENVIRONMENT [LABEL | --clear] [--config PATH] [--json]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/config.sh"
source "$HERE/validate-config.sh"
source "$HERE/tmux-lib.sh"

usage() { echo "Usage: workspace-label.sh ENVIRONMENT [LABEL | --clear] [--config PATH] [--json]" >&2; }

ENVIRONMENT=""
LABEL=""
CLEAR=0
JSON_MODE=0
CONFIG_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      if [ $# -lt 2 ]; then usage; exit 1; fi
      CONFIG_OVERRIDE="$2"; shift 2 ;;
    --clear) CLEAR=1; shift ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage; exit 1 ;;
    *)
      if [ -z "$ENVIRONMENT" ]; then ENVIRONMENT="$1"
      elif [ -z "$LABEL" ]; then LABEL="$1"
      else echo "ERROR: unexpected argument: $1" >&2; usage; exit 1
      fi
      shift ;;
  esac
done

if [ -z "$ENVIRONMENT" ]; then
  usage
  exit 1
fi
if [ "$CLEAR" -eq 1 ] && [ -n "$LABEL" ]; then
  echo "ERROR: give a LABEL or --clear, not both" >&2
  exit 1
fi
if [ -n "$LABEL" ] && ! [[ "$LABEL" =~ $SW_WORKER_LABEL_RE ]]; then
  echo "ERROR: a label is 1-24 characters of a-z, 0-9 and -, starting with a letter or digit: $LABEL" >&2
  exit 1
fi

ensure_jq

CONFIG_PATH="$(resolve_project_config_path "$CONFIG_OVERRIDE")" || exit 1
CONFIG_JSON="$(load_workspace_config_raw "$CONFIG_PATH")" || exit 1
if ! validate_workspace_config "$CONFIG_JSON" "$CONFIG_PATH"; then
  echo "ERROR: config failed validation: $CONFIG_PATH" >&2
  print_validation_errors
  exit 1
fi
PROJECT_ID="$(printf '%s' "$CONFIG_JSON" | jq -r '.project.id')"

if printf '%s' "$CONFIG_JSON" | jq -e '.schema_version == 6 and has("peers")' >/dev/null; then
  echo "ERROR: labels are not used with peers: give the label when you start a worker, with --label" >&2
  exit 1
fi
if ! printf '%s' "$CONFIG_JSON" | jq -e --arg e "$ENVIRONMENT" '(.schema_version == 5 or .schema_version == 6) and ([(.environments // [])[].id] | index($e) != null)' >/dev/null; then
  echo "ERROR: unknown environment \"$ENVIRONMENT\" (labels need a schema-v5 environment)" >&2
  exit 1
fi

# The worker panes whose names the label decides: executor/reviewer panes of
# the environment's development sessions that leave out `name` in the file.
RAW_JSON="$(jq -c '.' "$CONFIG_PATH")" || exit 1
LABELED_SLOTS="$(printf '%s' "$RAW_JSON" | jq -c --arg e "$ENVIRONMENT" '
  (.harness.roles // {}) as $roles
  | ([(.environments // [])[] | select(.id == $e)][0].development // []) as $dev
  | [(.sessions // [])[] | select(.id as $id | $dev | index($id) != null) | .id as $sid
     | (.panes // []) | to_entries[] | select((.value | has("name") | not) and (.value.role == $roles.executor or .value.role == $roles.reviewer))
     | {session: $sid, index: .key}]
')"
worker_names() {
  # worker_names CONFIG_JSON — the names those slots get in CONFIG_JSON.
  printf '%s' "$1" | jq -c --argjson slots "$LABELED_SLOTS" '
    . as $cfg | [$slots[] | . as $slot | ($cfg.sessions[] | select(.id == $slot.session) | .panes[$slot.index].name)]
  '
}
CURRENT_NAMES="$(worker_names "$CONFIG_JSON")"
CURRENT_LABEL="$(sw_read_worker_labels "$PROJECT_ID" | jq -r --arg e "$ENVIRONMENT" '.[$e] // ""')"

report() {
  local label="$1" names="$2" changed="$3"
  if [ "$JSON_MODE" -eq 1 ]; then
    jq -cn --arg e "$ENVIRONMENT" --arg l "$label" --argjson n "$names" --argjson c "$changed" \
      '{environment: $e, "label": (if $l == "" then null else $l end), workers: $n, changed: $c}'
  else
    printf 'environment %s: label %s\n' "$ENVIRONMENT" "${label:-(none)}"
    printf '%s' "$names" | jq -r '.[] | "  worker: " + .'
  fi
}

if [ -z "$LABEL" ] && [ "$CLEAR" -eq 0 ]; then
  report "$CURRENT_LABEL" "$CURRENT_NAMES" false
  exit 0
fi

if [ "$(printf '%s' "$LABELED_SLOTS" | jq 'length')" -eq 0 ]; then
  echo "ERROR: environment \"$ENVIRONMENT\" has no unnamed executor or reviewer pane; its worker names are written in the config" >&2
  exit 1
fi

if [ "$LABEL" = "$CURRENT_LABEL" ] && { [ -n "$LABEL" ] || [ "$CLEAR" -eq 1 ]; }; then
  report "$CURRENT_LABEL" "$CURRENT_NAMES" false
  exit 0
fi

sw_lock_acquire "$PROJECT_ID" || exit 1

# Every current worker of this environment must be stopped.
if [ -n "$(type -P tmux 2>/dev/null)" ]; then
  running="$(tmux list-panes -a -F "#{$MARKER_PROJECT}	#{$MARKER_PANE}" 2>/dev/null | awk -F '\t' -v p="$PROJECT_ID" '$1 == p { print $2 }')"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if printf '%s\n' "$running" | grep -Fxq -- "$name"; then
      echo "ERROR: worker $name is running; stop the environment's workers first (workspace stop SESSION --pane $name --confirmed)" >&2
      exit 1
    fi
  done < <(printf '%s' "$CURRENT_NAMES" | jq -r '.[]')
fi

LABELS_JSON="$(sw_read_worker_labels "$PROJECT_ID" | jq -c --arg e "$ENVIRONMENT" --arg l "$LABEL" 'if $l == "" then del(.[$e]) else .[$e] = $l end')"
CANDIDATE_JSON="$(load_workspace_config_raw "$CONFIG_PATH" "$LABELS_JSON")" || exit 1
if ! validate_workspace_config "$CANDIDATE_JSON" "$CONFIG_PATH"; then
  echo "ERROR: label \"$LABEL\" gives worker names the config does not accept:" >&2
  print_validation_errors
  exit 1
fi
NEW_NAMES="$(worker_names "$CANDIDATE_JSON")"

LABELS_PATH="$(sw_worker_labels_path "$PROJECT_ID")"
STATE_DIR="$(sw_ensure_state_dir "$PROJECT_ID")"
TMP_PATH="$(mktemp "$STATE_DIR/labels.json.XXXXXX")" || { echo "ERROR: cannot write $STATE_DIR" >&2; exit 1; }
if ! printf '%s\n' "$LABELS_JSON" > "$TMP_PATH" || ! mv -f "$TMP_PATH" "$LABELS_PATH"; then
  rm -f "$TMP_PATH"
  echo "ERROR: could not write $LABELS_PATH" >&2
  exit 1
fi
sw_lock_release
report "$LABEL" "$NEW_NAMES" true
