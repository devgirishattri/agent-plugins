#!/usr/bin/env bash
# tasks-clean.sh — Dry-run or delete scheduler task files
# Usage: tasks-clean.sh [--older-than 7d] [--status status] [--apply]
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

OLDER_THAN="7d"
STATUS_FILTER=""
APPLY=0

usage() {
  echo "Usage: tasks-clean.sh [--older-than 7d] [--status status] [--apply]"
}

duration_to_seconds() {
  local value="$1"
  local number unit
  number="${value%[smhd]}"
  unit="${value#"$number"}"
  case "$number" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$unit" in
    s) printf '%s\n' "$number" ;;
    m) printf '%s\n' $((10#$number * 60)) ;;
    h) printf '%s\n' $((10#$number * 3600)) ;;
    d|'') printf '%s\n' $((10#$number * 86400)) ;;
    *) return 1 ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --older-than)
      [ "$#" -ge 2 ] && [[ "$2" != --* ]] && [ -n "$2" ] || { usage >&2; exit 1; }
      OLDER_THAN="$2"
      shift 2
      ;;
    --status)
      [ "$#" -ge 2 ] && [[ "$2" != --* ]] && [ -n "$2" ] || { usage >&2; exit 1; }
      STATUS_FILTER="$2"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_jq || exit 1
ensure_dirs || exit 1
threshold=$(duration_to_seconds "$OLDER_THAN") || {
  echo "ERROR: Invalid duration: $OLDER_THAN. Use values like 7d, 12h, 30m, or 60s." >&2
  exit 1
}
now=$(now_epoch)
count=0
orphans=0
candidates='[]'
CLEAN_LOCK_ID=''
trap '[ -z "$CLEAN_LOCK_ID" ] || release_task_lock "$CLEAN_LOCK_ID"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for file in "$TASKS_DIR"/*.json; do
  [ -f "$file" ] || continue
  status=$(jq -r '.status // ""' "$file")
  [ -n "$STATUS_FILTER" ] && [ "$status" != "$STATUS_FILTER" ] && continue
  updated=$(jq -r '.updated_at // ""' "$file" 2>/dev/null)
  updated_epoch=$(iso_to_epoch "$updated")
  if [ "$updated_epoch" -le 0 ]; then
    echo "WARN: skipping $(basename "$file"): invalid updated_at '$updated'." >&2
    continue
  fi
  age=$((now - updated_epoch))
  [ "$age" -lt "$threshold" ] && continue
  # Filesystem names, never ledger-provided paths, define cleanup targets.
  id=${file##*/}; id=${id%.json}
  candidates=$(jq -c --arg id "$id" '. + [$id]' <<< "$candidates")
done

# Iterate to a fixed point: retaining B because C needs it must also retain A
# when B depends on A, regardless of filename order.
changed=1
while [ "$changed" -eq 1 ]; do
  changed=0
  while IFS= read -r id; do
    refs=''
    for file in "$TASKS_DIR"/*.json; do
      [ -f "$file" ] || continue
      other=${file##*/}; other=${other%.json}
      jq -e --arg id "$other" 'index($id) != null' <<< "$candidates" >/dev/null && continue
      if jq -e --arg id "$id" '(.depends_on // []) | index($id) != null' "$file" >/dev/null; then
        refs="${refs:+$refs,}$other"
      fi
    done
    if [ -n "$refs" ]; then
      printf 'kept %s (referenced by %s)\n' "$id" "$refs"
      candidates=$(jq -c --arg id "$id" 'map(select(. != $id))' <<< "$candidates")
      changed=1
    fi
  done < <(jq -r '.[]' <<< "$candidates")
done

while IFS= read -r id; do
  file="$TASKS_DIR/$id.json"
  status=$(jq -r '.status // ""' "$file")
  updated_epoch=$(iso_to_epoch "$(jq -r '.updated_at // ""' "$file")")
  age=$((now - updated_epoch))
  count=$((count + 1))
  if [ "$APPLY" -eq 1 ]; then
    acquire_task_lock "$id" || exit 1
    CLEAN_LOCK_ID=$id
    # An assignment may have refreshed this task while cleanup was planning.
    updated_epoch=$(iso_to_epoch "$(jq -r '.updated_at // ""' "$file" 2>/dev/null)")
    status=$(jq -r '.status // ""' "$file" 2>/dev/null)
    if [ "$updated_epoch" -le 0 ] || [ $((now - updated_epoch)) -lt "$threshold" ] ||
       { [ -n "$STATUS_FILTER" ] && [ "$status" != "$STATUS_FILTER" ]; }; then
      release_task_lock "$id"
      echo "ERROR: task $id changed during cleanup; rerun to recompute dependencies." >&2
      exit 1
    fi
    rm -f "$file" || { release_task_lock "$id"; exit 1; }
    for suffix in '' -review -ack-done -ack-blocked -ack-review; do
      rm -f "$PROMPTS_DIR/$id$suffix.md" || { release_task_lock "$id"; exit 1; }
    done
    # The fixed child path is validated by ensure_dirs; no task-id prefix glob.
    if [ "$id" != . ] && [ "$id" != .. ] && [ -d "$SCHEDULER_DIR/handoffs/$id" ]; then
      rm -r "$SCHEDULER_DIR/handoffs/$id" || { release_task_lock "$id"; exit 1; }
    fi
    release_task_lock "$id"
    CLEAN_LOCK_ID=''
    printf 'Deleted\t%s\n' "$id"
  else
    printf 'Would delete\t%s\tstatus=%s\tage=%ss\n' "$id" "$status" "$age"
  fi
done < <(jq -r '.[]' <<< "$candidates")

echo 'Orphans:'
for artifact in "$SCHEDULER_DIR/handoffs"/* "$PROMPTS_DIR"/*.md; do
  [ -e "$artifact" ] || continue
  [ ! -L "$artifact" ] || { echo "ERROR: symlink orphan: $artifact" >&2; exit 1; }
  name=${artifact##*/}
  if [ -d "$artifact" ]; then
    id=$name
    [ ! -e "$TASKS_DIR/$id.json" ] || continue
  else
    id=${name%.md}
    # A filename may be either a primary prompt or a lifecycle packet. If
    # either interpretation has a live task, keep it conservatively.
    [ ! -e "$TASKS_DIR/$id.json" ] || continue
    if [[ "$id" == *-review ]] && [ -e "$TASKS_DIR/${id%-review}.json" ]; then
      continue
    fi
    case "$id" in
      *-ack-done) id=${id%-ack-done} ;;
      *-ack-blocked) id=${id%-ack-blocked} ;;
      *-ack-review) id=${id%-ack-review} ;;
      *-review) id=${id%-review} ;;
    esac
    [ ! -e "$TASKS_DIR/$id.json" ] || continue
  fi
  validate_task_id "$id" || continue
  [ "$id" != . ] && [ "$id" != .. ] || continue
  modified=$(file_mtime "$artifact") || exit 1
  [ $((now - modified)) -ge "$threshold" ] || continue
  if [ "$APPLY" -eq 1 ]; then
    acquire_task_lock "$id" || exit 1
    CLEAN_LOCK_ID=$id
    if [ -e "$TASKS_DIR/$id.json" ]; then
      release_task_lock "$id"
      CLEAN_LOCK_ID=''
      continue
    fi
    if [ -d "$artifact" ]; then
      rm -r "$artifact" || { release_task_lock "$id"; exit 1; }
    else
      rm -f "$artifact" || { release_task_lock "$id"; exit 1; }
    fi
    release_task_lock "$id"
    CLEAN_LOCK_ID=''
    printf 'Deleted orphan\t%s\n' "$artifact"
  else
    printf 'Would delete orphan\t%s\n' "$artifact"
  fi
  orphans=$((orphans + 1))
done

if [ "$APPLY" -eq 1 ]; then
  printf 'Summary\tdeleted=%s\torphans=%s\n' "$count" "$orphans"
else
  printf 'Summary\twould_delete=%s\torphans=%s\n' "$count" "$orphans"
  echo "Dry run only. Re-run with --apply to delete matching tasks."
fi
