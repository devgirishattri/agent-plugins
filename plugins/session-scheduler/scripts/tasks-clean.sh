#!/usr/bin/env bash
# tasks-clean.sh — delete old ledger files and every artifact they own.
# Dry-run by default.
# Usage: tasks-clean.sh [--older-than DAYS] [--status STATUS] [--apply]
#
# Per candidate task (updated_at older than the threshold): tasks/<id>.json,
# prompts/<id>.md, prompts/<id>-review.md, prompts/<id>-ack-{done,blocked,review}.md,
# handoffs/<id>/ and locks/<id>.lock/. Exact names only — never <id>-* globs.
# A candidate still referenced by a surviving task's depends_on is KEPT, so
# cleanup never turns an assignable task into an unmet-dependency one.
# The same run also sweeps ORPHANS: handoff dirs and known-suffix prompt files
# whose task JSON is gone and whose mtime is older than the threshold.
set -uo pipefail

source "$(dirname "$0")/lib.sh"

require_jq || exit 1
ensure_dirs || exit 1

USAGE="Usage: tasks-clean.sh [--older-than DAYS] [--status done|blocked|...] [--apply]"

DAYS=7
STATUS_FILTER=""
APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --older-than)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "ERROR: --older-than requires a value (days). $USAGE" >&2; exit 1; }
      DAYS="$2"; shift 2 ;;
    --status)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "ERROR: --status requires a value. $USAGE" >&2; exit 1; }
      STATUS_FILTER="$2"; shift 2 ;;
    --apply)      APPLY=1; shift ;;
    -h|--help)
      echo "$USAGE"
      exit 0
      ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --older-than must be an integer number of days." >&2
  exit 1
fi

now=$(date +%s)
threshold=$((now - DAYS * 86400))

# file_mtime <path> -> epoch seconds (BSD stat first, then GNU); 0 on failure.
file_mtime() {
  local m
  m=$(stat -f %m "$1" 2>/dev/null) || m=$(stat -c %Y "$1" 2>/dev/null) || m=0
  printf '%s\n' "${m:-0}"
}

# --- Phase 1: task candidates ---
shopt -s nullglob
files=("$TASKS_DIR"/*.json)
shopt -u nullglob

candidates=()      # task JSON paths
candidate_ids=()   # their ids (from file content, validated)
for f in "${files[@]}"; do
  updated=$(jq -r '.updated_at' "$f" 2>/dev/null) || continue
  status=$(jq -r '.status' "$f" 2>/dev/null) || continue
  id=$(jq -r '.id' "$f" 2>/dev/null) || continue
  epoch=$(iso_to_epoch "$updated")
  if [ "$epoch" -le 0 ]; then
    echo "WARN: skipping $(basename "$f"): invalid updated_at '$updated'." >&2
    continue
  fi
  [ "$epoch" -ge "$threshold" ] && continue
  if [ -n "$STATUS_FILTER" ] && [ "$status" != "$STATUS_FILTER" ]; then continue; fi
  # The id comes from file content; validate so a crafted .id like "../../x"
  # can never steer a delete outside the ledger (validate_task_id forbids "/").
  if ! validate_task_id "$id" >/dev/null 2>&1 || [ "$(task_path "$id")" != "$f" ]; then
    echo "WARN: skipping $(basename "$f"): .id '$id' does not match its filename." >&2
    continue
  fi
  candidates+=("$f")
  candidate_ids+=("$id")
done

# Reverse-dependency guard: keep any candidate that a SURVIVING task (one not
# also being deleted) still lists in depends_on.
is_candidate() {
  local x
  for x in "${candidate_ids[@]+"${candidate_ids[@]}"}"; do [ "$x" = "$1" ] && return 0; done
  return 1
}
kept_lines=()
final_ids=()
for cid in "${candidate_ids[@]+"${candidate_ids[@]}"}"; do
  referrers=""
  for f in "${files[@]}"; do
    rid=$(jq -r '.id' "$f" 2>/dev/null) || continue
    [ "$rid" = "$cid" ] && continue
    is_candidate "$rid" && continue
    if jq -e --arg d "$cid" '(.depends_on // []) | index($d) != null' "$f" >/dev/null 2>&1; then
      referrers="${referrers:+$referrers, }$rid"
    fi
  done
  if [ -n "$referrers" ]; then
    kept_lines+=("kept $cid (referenced by $referrers)")
  else
    final_ids+=("$cid")
  fi
done

# --- Phase 2: orphan sweep ---
# A prompt file <X>.md is OWNED if task X exists, or if X ends with a known
# packet suffix and the task with that suffix stripped exists (so task
# "a-review"'s base prompt is never mistaken for task "a"'s review packet).
prompt_owned() {
  local stem="$1" suffix
  task_exists "$stem" && return 0
  for suffix in -review -ack-done -ack-blocked -ack-review; do
    case "$stem" in
      *"$suffix")
        task_exists "${stem%"$suffix"}" && return 0 ;;
    esac
  done
  return 1
}
orphans=()
shopt -s nullglob
for p in "$PROMPTS_DIR"/*.md; do
  stem=$(basename "$p" .md)
  prompt_owned "$stem" && continue
  [ "$(file_mtime "$p")" -lt "$threshold" ] || continue
  orphans+=("$p")
done
for d in "$HANDOFFS_DIR"/*/; do
  d="${d%/}"
  hid=$(basename "$d")
  task_exists "$hid" && continue
  [ "$(file_mtime "$d")" -lt "$threshold" ] || continue
  orphans+=("$d")
done
shopt -u nullglob

# --- Report / apply ---
n_tasks=${#final_ids[@]}
n_orphans=${#orphans[@]}
if [ "$n_tasks" -eq 0 ] && [ "$n_orphans" -eq 0 ]; then
  echo "Nothing to clean (older than ${DAYS}d${STATUS_FILTER:+, status=$STATUS_FILTER})."
  for k in "${kept_lines[@]+"${kept_lines[@]}"}"; do echo "  $k"; done
  exit 0
fi

if [ "$APPLY" -ne 1 ]; then
  echo "DRY-RUN: would delete ${n_tasks} task(s) older than ${DAYS}d${STATUS_FILTER:+, status=$STATUS_FILTER} (plus their prompt, packet, and handoff files):"
  for id in "${final_ids[@]+"${final_ids[@]}"}"; do
    status=$(task_get "$id" '.status')
    printf '  %s\t%s\t%s\n' "$id" "$status" "$(basename "$(task_path "$id")")"
  done
  for k in "${kept_lines[@]+"${kept_lines[@]}"}"; do echo "  $k"; done
  if [ "$n_orphans" -gt 0 ]; then
    echo "Orphans (no task JSON, older than ${DAYS}d): ${n_orphans}"
    for o in "${orphans[@]}"; do echo "  ${o#"$SCHEDULER_DIR"/}"; done
  fi
  echo
  echo "Re-run with --apply to actually delete."
  exit 0
fi

deleted=0
for id in "${final_ids[@]+"${final_ids[@]}"}"; do
  rm -f "$(task_path "$id")"
  while IFS= read -r artifact; do
    # Dual-ownership rule (same as the orphan sweep): prompts/<id>-review.md is
    # ALSO the base prompt of a task literally named "<id>-review". If such a
    # task survives, its prompt stays.
    stem=$(basename "$artifact" .md)
    if [ "$stem" != "$id" ] && task_exists "$stem"; then continue; fi
    rm -f "$artifact"
  done < <(task_prompt_artifacts "$id")
  rm -rf "$(handoff_dir "$id")"
  rm -rf "$(task_lock_path "$id")"
  deleted=$((deleted + 1))
done
orphans_deleted=0
for o in "${orphans[@]+"${orphans[@]}"}"; do
  rm -rf "$o"
  orphans_deleted=$((orphans_deleted + 1))
done
echo "Deleted ${deleted} task(s) with their prompt, packet, and handoff files; removed ${orphans_deleted} orphan(s)."
for k in "${kept_lines[@]+"${kept_lines[@]}"}"; do echo "  $k"; done
