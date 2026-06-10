#!/usr/bin/env bash
# task-new.sh — Create a scheduler task
# Usage: task-new.sh <name> [--meta k=v ...] [--stage NAME] [--depends-on id1,id2]
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

if [ "$#" -lt 1 ]; then
  echo "ERROR: Usage: task-new.sh <name> [--meta k=v ...] [--stage NAME] [--depends-on id1,id2]" >&2
  exit 1
fi

require_jq || exit 1
ensure_dirs

NAME="$1"
shift
meta_json='{}'
STAGE=""
DEPENDS_RAW=""
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
    --stage)
      [ "$#" -ge 2 ] || { echo "ERROR: --stage requires a label." >&2; exit 1; }
      STAGE="$2"
      validate_stage "$STAGE" || exit 1
      shift 2
      ;;
    --depends-on)
      [ "$#" -ge 2 ] || { echo "ERROR: --depends-on requires a comma-separated id list." >&2; exit 1; }
      DEPENDS_RAW="$2"
      shift 2
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Validate dependencies: each id must be well-formed and exist in the ledger.
depends_json='[]'
if [ -n "$DEPENDS_RAW" ]; then
  IFS=',' read -ra dep_ids <<< "$DEPENDS_RAW"
  for dep in "${dep_ids[@]}"; do
    dep=$(printf '%s' "$dep" | tr -d '[:space:]')
    [ -z "$dep" ] && continue
    dep_file=$(task_file "$dep") || exit 1
    if [ ! -f "$dep_file" ]; then
      echo "ERROR: Dependency does not exist in the ledger: $dep" >&2
      exit 1
    fi
    depends_json=$(printf '%s\n' "$depends_json" | jq --arg d "$dep" '. + [$d]')
  done
fi

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
  --arg stage "$STAGE" \
  --argjson meta "$meta_json" \
  --argjson depends "$depends_json" \
  '{
    id:$id,
    name:$name,
    status:$status,
    stage:(if $stage == "" then null else $stage end),
    assigner:$assigner,
    assignee:"",
    prompt_file:"",
    depends_on:$depends,
    created_at:$created,
    updated_at:$created,
    started_at:null,
    eta_at:null,
    meta:$meta,
    history:[{ts:$created,event:"created",actor:$assigner,note:$name}]
  }' > "$FILE"

echo "Created task $ID: $NAME"
[ -n "$STAGE" ] && echo "Stage: $STAGE"
if [ "$depends_json" != "[]" ]; then
  echo "Depends on: $(printf '%s\n' "$depends_json" | jq -r 'join(", ")')"
fi
exit 0
