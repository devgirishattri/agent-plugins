#!/usr/bin/env bash
# task-new.sh — Create a scheduler task
# Usage: task-new.sh <name> [--meta k=v ...]
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

if [ "$#" -lt 1 ]; then
  echo "ERROR: Usage: task-new.sh <name> [--meta k=v ...]" >&2
  exit 1
fi

require_jq || exit 1
ensure_dirs

NAME="$1"
shift
meta_json='{}'
while [ "$#" -gt 0 ]; do
  case "$1" in
    --meta)
      [ "$#" -ge 2 ] || { echo "ERROR: --meta requires k=v." >&2; exit 1; }
      item="$2"
      case "$item" in
        *=*)
          key="${item%%=*}"
          value="${item#*=}"
          meta_json=$(printf '%s\n' "$meta_json" | jq --arg key "$key" --arg value "$value" '. + {($key): $value}')
          ;;
        *)
          echo "ERROR: --meta value must be k=v: $item" >&2
          exit 1
          ;;
      esac
      shift 2
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

ID=$(generate_id)
FILE=$(task_file "$ID") || exit 1
NOW=$(now_iso)
ASSIGNER=$(current_pane_name)

jq -n \
  --arg id "$ID" \
  --arg name "$NAME" \
  --arg status "created" \
  --arg assigner "$ASSIGNER" \
  --arg created "$NOW" \
  --argjson meta "$meta_json" \
  '{
    id:$id,
    name:$name,
    status:$status,
    assigner:$assigner,
    assignee:"",
    prompt_file:"",
    created_at:$created,
    updated_at:$created,
    meta:$meta,
    history:[{ts:$created,event:"created",actor:$assigner,note:$name}]
  }' > "$FILE"

echo "Created task $ID: $NAME"
