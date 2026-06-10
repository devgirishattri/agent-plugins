#!/usr/bin/env bash
# lib.sh — Shared functions for session-scheduler plugin
# Source this file: source "$(dirname "$0")/lib.sh"
# Supported platforms: macOS, Linux

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SCHEDULER_DIR="${SESSION_SCHEDULER_HOME:-$PROJECT_ROOT/tmp/scheduler}"
TASKS_DIR="$SCHEDULER_DIR/tasks"
PROMPTS_DIR="$SCHEDULER_DIR/prompts"
SESSION_CHAT_MIN_VERSION="0.11.0"

ensure_dirs() {
  mkdir -p "$TASKS_DIR" "$PROMPTS_DIR"
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required for session-scheduler." >&2
    return 1
  fi
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

now_epoch() {
  date +%s
}

# Convert ISO-8601 UTC -> epoch seconds. BSD date first, GNU fallback.
# Echoes 0 on failure so callers can skip time-based logic.
iso_to_epoch() {
  local iso="$1" epoch=""
  epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null) ||
    epoch=$(date -u -d "$iso" +%s 2>/dev/null) ||
    epoch=""
  printf '%s\n' "${epoch:-0}"
}

# Convert epoch seconds -> ISO-8601 UTC. BSD (date -r) first, GNU (-d @) fallback.
# Echoes empty string on failure.
epoch_to_iso() {
  local epoch="$1" iso=""
  iso=$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) ||
    iso=$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) ||
    iso=""
  printf '%s\n' "$iso"
}

# Humanize an age in seconds: 45s, 12m, 3h, 2d.
humanize_age() {
  local s="$1"
  [ "$s" -lt 0 ] 2>/dev/null && s=0
  if [ "$s" -lt 60 ]; then printf '%ds\n' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%dm\n' $((s / 60))
  elif [ "$s" -lt 86400 ]; then printf '%dh\n' $((s / 3600))
  else printf '%dd\n' $((s / 86400)); fi
}

generate_id() {
  local rand
  if command -v od >/dev/null 2>&1; then
    rand=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  else
    rand="${RANDOM:-0}${RANDOM:-0}"
  fi
  printf 'task-%s-%s\n' "$(now_epoch)" "$rand"
}

validate_task_id() {
  local id="$1"
  if [ -z "$id" ] || ! [[ "$id" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo "ERROR: Invalid task id: $id" >&2
    return 1
  fi
}

# Stage labels are free-form but validated like task ids.
# Suggested stages: plan, dispatch, execute, audit, push.
validate_stage() {
  local stage="$1"
  if [ -z "$stage" ] || ! [[ "$stage" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: Invalid stage: $stage (alphanumeric, _, - only)." >&2
    return 1
  fi
}

task_file() {
  local id="$1"
  validate_task_id "$id" || return 1
  printf '%s/%s.json\n' "$TASKS_DIR" "$id"
}

prompt_file() {
  local id="$1"
  validate_task_id "$id" || return 1
  printf '%s/%s.md\n' "$PROMPTS_DIR" "$id"
}

current_pane_name() {
  if command -v tmux >/dev/null 2>&1 && [ -n "${TMUX_PANE:-}" ]; then
    tmux display-message -p -t "$TMUX_PANE" '#{@name}' 2>/dev/null || true
  fi
}

session_chat_root() {
  if [ -n "${SESSION_CHAT_ROOT_OVERRIDE:-}" ] && [ -d "$SESSION_CHAT_ROOT_OVERRIDE" ]; then
    printf '%s\n' "$SESSION_CHAT_ROOT_OVERRIDE"
    return 0
  fi
  if [ -n "${SESSION_CHAT_PLUGIN_ROOT:-}" ] && [ -d "$SESSION_CHAT_PLUGIN_ROOT" ]; then
    printf '%s\n' "$SESSION_CHAT_PLUGIN_ROOT"
    return 0
  fi
  local cache_base="$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat"
  if [ -d "$cache_base" ]; then
    local latest_version
    latest_version=$(find "$cache_base" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    if [ -n "$latest_version" ] && [ -d "$cache_base/$latest_version" ]; then
      printf '%s\n' "$cache_base/$latest_version"
      return 0
    fi
  fi
  local sibling="$PLUGIN_ROOT/../session-chat"
  if [ -d "$sibling" ]; then
    printf '%s\n' "$sibling"
    return 0
  fi
  echo "ERROR: session-chat >= $SESSION_CHAT_MIN_VERSION is required but was not found." >&2
  return 1
}

session_chat_version() {
  local root="$1"
  jq -r '.version // "unknown"' "$root/.codex-plugin/plugin.json" 2>/dev/null || echo "unknown"
}

write_json_atomic() {
  local file="$1"
  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
  cat > "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$file"
}

# --- Status transition enforcement ---
# Legal transitions. assigned->assigned is allowed to support reassignment.
transition_allowed() {
  local from="$1" to="$2"
  case "${from}:${to}" in
    created:assigned | created:blocked | \
    assigned:assigned | assigned:review | assigned:done | assigned:blocked | \
    review:done | review:blocked | \
    blocked:assigned)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

legal_targets() {
  case "$1" in
    created)  echo "assigned, blocked" ;;
    assigned) echo "assigned (reassign), review, done, blocked" ;;
    review)   echo "done, blocked" ;;
    blocked)  echo "assigned" ;;
    done)     echo "(none — done is terminal)" ;;
    *)        echo "(unknown current status)" ;;
  esac
}

scheduler_force_enabled() {
  [ "${SESSION_SCHEDULER_FORCE:-0}" = "1" ]
}

# session-context snapshots live at <project_root>/tmp/contexts (same
# project-root logic as the scheduler ledger). Override with
# SESSION_CONTEXT_HOME (used by tests).
resolve_contexts_dir() {
  if [ -n "${SESSION_CONTEXT_HOME:-}" ]; then
    printf '%s\n' "$SESSION_CONTEXT_HOME"
    return 0
  fi
  printf '%s/tmp/contexts\n' "$PROJECT_ROOT"
}

# Print "dep-id (status)" per dependency of <id> that is not done.
# Missing dependency files report status "missing". Empty output = all met.
unmet_deps() {
  local id="$1" dep dstatus deps file dfile
  file=$(task_file "$id" 2>/dev/null) || return 0
  [ -f "$file" ] || return 0
  deps=$(jq -r '(.depends_on // [])[]' "$file" 2>/dev/null)
  [ -z "$deps" ] && return 0
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    dfile=$(task_file "$dep" 2>/dev/null) || dfile=""
    if [ -n "$dfile" ] && [ -f "$dfile" ]; then
      dstatus=$(jq -r '.status // ""' "$dfile")
    else
      dstatus="missing"
    fi
    [ "$dstatus" = "done" ] || printf '%s (%s)\n' "$dep" "$dstatus"
  done <<< "$deps"
}

# Compute attention flags for a task json file: OVERDUE (past eta_at and not
# done) and/or STALE (assigned/review with no update for
# SESSION_SCHEDULER_STALE_MINUTES, default 30). Prints "-" if none.
task_flags() {
  local file="$1"
  local status eta updated flags="" now stale_min eta_epoch up_epoch
  now=$(now_epoch)
  stale_min="${SESSION_SCHEDULER_STALE_MINUTES:-30}"
  [[ "$stale_min" =~ ^[0-9]+$ ]] || stale_min=30
  status=$(jq -r '.status // ""' "$file" 2>/dev/null)
  eta=$(jq -r '.eta_at // empty' "$file" 2>/dev/null)
  updated=$(jq -r '.updated_at // empty' "$file" 2>/dev/null)
  if [ -n "$eta" ] && [ "$status" != "done" ]; then
    eta_epoch=$(iso_to_epoch "$eta")
    if [ "$eta_epoch" -gt 0 ] && [ "$now" -gt "$eta_epoch" ]; then
      flags="OVERDUE"
    fi
  fi
  case "$status" in
    assigned|review)
      if [ -n "$updated" ]; then
        up_epoch=$(iso_to_epoch "$updated")
        if [ "$up_epoch" -gt 0 ] && [ $((now - up_epoch)) -gt $((stale_min * 60)) ]; then
          flags="${flags:+$flags,}STALE"
        fi
      fi
      ;;
  esac
  printf '%s\n' "${flags:--}"
}

# Update status + history. Enforces legal transitions unless
# SESSION_SCHEDULER_FORCE=1 (then the history note records "forced").
# Sets started_at the first time status becomes assigned.
append_history_update() {
  local file="$1"
  local status="$2"
  local event="$3"
  local actor="$4"
  local note="$5"
  local current
  current=$(jq -r '.status // ""' "$file" 2>/dev/null)
  if ! transition_allowed "$current" "$status"; then
    if scheduler_force_enabled; then
      note="${note:+$note }(forced)"
    else
      echo "ERROR: Illegal status transition '$current' -> '$status'." >&2
      echo "Current status: $current; legal next: $(legal_targets "$current")" >&2
      echo "Override with --force or SESSION_SCHEDULER_FORCE=1." >&2
      return 1
    fi
  fi
  local now
  now=$(now_iso)
  jq \
    --arg status "$status" \
    --arg now "$now" \
    --arg event "$event" \
    --arg actor "$actor" \
    --arg note "$note" \
    '.status=$status
     | .updated_at=$now
     | (if $status == "assigned" and ((.started_at // null) == null)
        then .started_at=$now else . end)
     | .history += [{ts:$now,event:$event,actor:$actor,note:$note}]' \
    "$file" | write_json_atomic "$file"
}

file_mtime() {
  local file="$1"
  stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null
}
