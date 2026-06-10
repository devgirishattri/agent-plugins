#!/usr/bin/env bash
# task-new.sh — create a new task in the ledger.
# Usage: task-new.sh <name> [--meta key=value ...] [--stage NAME] [--depends-on id1,id2]
set -uo pipefail

source "$(dirname "$0")/lib.sh"

require_jq || exit 1
ensure_dirs

NAME="${1:-}"
if [ -z "$NAME" ]; then
  echo "ERROR: task name required. Usage: task-new.sh <name> [--meta k=v ...] [--stage NAME] [--depends-on id1,id2]" >&2
  exit 1
fi
shift

META_JSON='{}'
STAGE=""
DEPENDS_RAW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --meta)
      pair="${2:-}"
      shift 2
      if [[ "$pair" != *=* ]]; then
        echo "ERROR: --meta expects key=value, got '$pair'" >&2
        exit 1
      fi
      key="${pair%%=*}"
      val="${pair#*=}"
      META_JSON=$(printf '%s' "$META_JSON" | jq --arg k "$key" --arg v "$val" '. + {($k): $v}')
      ;;
    --stage)
      STAGE="${2:-}"
      shift 2
      validate_stage "$STAGE" || exit 1
      ;;
    --depends-on)
      DEPENDS_RAW="${2:-}"
      shift 2
      if [ -z "$DEPENDS_RAW" ]; then
        echo "ERROR: --depends-on expects a comma-separated list of task ids." >&2
        exit 1
      fi
      ;;
    *)
      echo "ERROR: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

# Validate dependencies: each id must be well-formed and exist in the ledger.
DEPENDS_JSON='[]'
if [ -n "$DEPENDS_RAW" ]; then
  IFS=',' read -ra dep_ids <<< "$DEPENDS_RAW"
  for dep in "${dep_ids[@]}"; do
    dep=$(printf '%s' "$dep" | tr -d '[:space:]')
    [ -z "$dep" ] && continue
    validate_task_id "$dep" || exit 1
    if ! task_exists "$dep"; then
      echo "ERROR: dependency '$dep' does not exist in the ledger. Create it first with /task-new." >&2
      exit 1
    fi
    DEPENDS_JSON=$(printf '%s' "$DEPENDS_JSON" | jq --arg d "$dep" '. + [$d]')
  done
fi

ID=$(generate_task_id)
ASSIGNER=$(current_pane_name)
NOW=$(iso_now)

JSON=$(jq -n \
  --arg id "$ID" \
  --arg name "$NAME" \
  --arg status "created" \
  --arg assigner "$ASSIGNER" \
  --arg now "$NOW" \
  --arg stage "$STAGE" \
  --argjson meta "$META_JSON" \
  --argjson depends "$DEPENDS_JSON" \
  '{id: $id, name: $name, status: $status,
    stage: (if $stage == "" then null else $stage end),
    assigner: $assigner, assignee: null, prompt_file: null,
    depends_on: $depends,
    created_at: $now, updated_at: $now,
    started_at: null, eta_at: null,
    meta: $meta,
    history: [{ts: $now, event: "created", actor: $assigner, note: ""}]}')

task_write "$ID" "$JSON"

echo "Created task: $ID"
echo "  name:     $NAME"
echo "  status:   created"
echo "  assigner: $ASSIGNER"
[ -n "$STAGE" ] && echo "  stage:    $STAGE"
if [ "$DEPENDS_JSON" != "[]" ]; then
  echo "  depends:  $(printf '%s' "$DEPENDS_JSON" | jq -r 'join(", ")')"
fi
echo
echo "Next: /task-assign <pane> $ID '<prompt>'"
