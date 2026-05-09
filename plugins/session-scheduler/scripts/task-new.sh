#!/usr/bin/env bash
# task-new.sh — create a new task in the ledger.
# Usage: task-new.sh <name> [--meta key=value ...]
set -uo pipefail

source "$(dirname "$0")/lib.sh"

require_jq || exit 1
ensure_dirs

NAME="${1:-}"
if [ -z "$NAME" ]; then
  echo "ERROR: task name required. Usage: task-new.sh <name> [--meta k=v ...]" >&2
  exit 1
fi
shift

META_JSON='{}'
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
    *)
      echo "ERROR: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

ID=$(generate_task_id)
ASSIGNER=$(current_pane_name)
NOW=$(iso_now)

JSON=$(jq -n \
  --arg id "$ID" \
  --arg name "$NAME" \
  --arg status "created" \
  --arg assigner "$ASSIGNER" \
  --arg now "$NOW" \
  --argjson meta "$META_JSON" \
  '{id: $id, name: $name, status: $status, assigner: $assigner, assignee: null, prompt_file: null, created_at: $now, updated_at: $now, meta: $meta, history: [{ts: $now, event: "created", actor: $assigner, note: ""}]}')

task_write "$ID" "$JSON"

echo "Created task: $ID"
echo "  name:     $NAME"
echo "  status:   created"
echo "  assigner: $ASSIGNER"
echo
echo "Next: /task-assign <pane> $ID '<prompt>'"
