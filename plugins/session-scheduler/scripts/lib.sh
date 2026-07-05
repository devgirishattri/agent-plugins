#!/usr/bin/env bash
# lib.sh — shared helpers for session-scheduler plugin.
# Storage (default): <project_root>/tmp/scheduler/{tasks,prompts}/...
#   project_root resolves via `git rev-parse --show-toplevel` or pwd.
# Override: SESSION_SCHEDULER_HOME=<dir>  (same env var as codex side, so
#   claude and codex panes in the same project share a ledger).
# One JSON file per task. Atomic writes (tmp + mv).
# Requires: jq, bash 4+. Depends on session-chat lib.sh for /send.

# SESSION_SCHEDULER_HOME must be provided by the caller. The /task-* commands
# export it automatically (resolving <git-root|pwd>/tmp/scheduler). Scripts
# refuse to run without it rather than silently writing a ledger into a guessed
# cwd/tmp location.
if [ -z "${SESSION_SCHEDULER_HOME:-}" ]; then
  echo "ERROR: SESSION_SCHEDULER_HOME is not set." >&2
  echo "Run session-scheduler through its /task-* commands (they set it automatically)," >&2
  echo "or export SESSION_SCHEDULER_HOME=<dir> before invoking the scripts directly." >&2
  exit 1
fi

SCHEDULER_DIR="$SESSION_SCHEDULER_HOME"
TASKS_DIR="$SCHEDULER_DIR/tasks"
PROMPTS_DIR="$SCHEDULER_DIR/prompts"

ensure_dirs() {
  mkdir -p "$TASKS_DIR" "$PROMPTS_DIR"
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not installed. Install with: brew install jq" >&2
    return 1
  fi
}

# Locate session-chat scripts. Prefer the test override env var, then the
# cached install, then a sibling source dir.
session_chat_root() {
  if [ -n "${SESSION_CHAT_ROOT_OVERRIDE:-}" ]; then
    printf '%s\n' "$SESSION_CHAT_ROOT_OVERRIDE"
    return 0
  fi
  local versioned
  versioned=$(ls -1 "$HOME/.claude/plugins/cache/girishattri-plugins/session-chat" 2>/dev/null | sort -V | tail -1)
  if [ -n "$versioned" ]; then
    printf '%s/.claude/plugins/cache/girishattri-plugins/session-chat/%s\n' "$HOME" "$versioned"
    return 0
  fi
  local here
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
  if [ -d "$here/session-chat" ]; then
    printf '%s/session-chat\n' "$here"
    return 0
  fi
  return 1
}

# Send a one-line message via session-chat /send. Best-effort: if session-chat
# is missing or send fails, log to stderr but do not abort the scheduler op.
session_chat_send() {
  local target="$1"
  local message="$2"
  local root
  if ! root=$(session_chat_root); then
    echo "WARN: session-chat not installed; skipping ack to '$target'." >&2
    return 0
  fi
  if ! bash "$root/scripts/send-message.sh" "$target" "$message" >/dev/null 2>&1; then
    echo "WARN: session-chat /send to '$target' failed (recipient busy or absent)." >&2
  fi
}

session_chat_dispatch() {
  local target="$1"
  local prompt_file="$2"
  local root
  if ! root=$(session_chat_root); then
    echo "ERROR: session-chat not installed; cannot dispatch task. Install session-chat>=0.11.0." >&2
    return 1
  fi
  bash "$root/scripts/dispatch-to-session.sh" "$target" "$prompt_file"
}

# Get current pane name via session-chat helper, or fall back to '?'.
current_pane_name() {
  local root
  if ! root=$(session_chat_root); then
    echo "?"
    return 0
  fi
  local name
  name=$(bash "$root/scripts/get-my-name.sh" 2>/dev/null | tail -1 | tr -d '[:space:]')
  if [ -z "$name" ] || [ "$name" = "(unnamed)" ]; then
    echo "?"
  else
    echo "$name"
  fi
}

# Generate task id: 8 hex chars from /dev/urandom.
generate_task_id() {
  if command -v od >/dev/null 2>&1; then
    od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
  else
    printf '%s%s' "$$" "${RANDOM:-0}${RANDOM:-0}"
  fi
}

iso_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

epoch_now() {
  date +%s
}

# Convert ISO-8601 UTC -> epoch seconds. Tries BSD date first, then GNU.
# Echoes 0 on failure so callers can detect and skip time-based logic.
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

task_path() {
  printf '%s/%s.json\n' "$TASKS_DIR" "$1"
}

prompt_path() {
  printf '%s/%s.md\n' "$PROMPTS_DIR" "$1"
}

task_exists() {
  [ -f "$(task_path "$1")" ]
}

# Read a task field via jq. Usage: task_get <id> <jq-expr>
task_get() {
  local id="$1"
  local expr="$2"
  jq -r "$expr" "$(task_path "$id")" 2>/dev/null
}

# Atomic write of JSON content to a task file. Returns non-zero on any
# write/mv failure so callers can refuse to claim success on a corrupted
# ledger.
task_write() {
  local id="$1"
  local json="$2"
  local target
  target=$(task_path "$id")
  local tmp="${target}.tmp.$$"
  if ! printf '%s\n' "$json" > "$tmp"; then
    rm -f "$tmp" 2>/dev/null
    echo "ERROR: failed to stage ledger write for $id at $tmp" >&2
    return 1
  fi
  if ! mv "$tmp" "$target"; then
    rm -f "$tmp" 2>/dev/null
    echo "ERROR: failed to commit ledger write for $id at $target" >&2
    return 1
  fi
  return 0
}

# Append a history entry. Usage: task_append_history <id> <event> <actor> <note>
task_append_history() {
  local id="$1" event="$2" actor="$3" note="$4"
  local current
  current=$(cat "$(task_path "$id")")
  local updated
  updated=$(printf '%s' "$current" | jq \
    --arg ts "$(iso_now)" \
    --arg event "$event" \
    --arg actor "$actor" \
    --arg note "$note" \
    '.updated_at = $ts
     | .history += [{ts: $ts, event: $event, actor: $actor, note: $note}]')
  task_write "$id" "$updated"
}

# --- Status transition enforcement ---
# Legal transitions. assigned->assigned is allowed to support reassignment
# (documented behavior: re-dispatch a silent executor's task to a new pane).
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

# Update status + history together. Usage: task_set_status <id> <status> <actor> [note]
# Enforces legal transitions unless SESSION_SCHEDULER_FORCE=1 (then the history
# note records "forced"). Sets started_at the first time status becomes assigned.
task_set_status() {
  local id="$1" status="$2" actor="$3" note="${4:-}"
  local current_status
  current_status=$(task_get "$id" '.status')
  if ! transition_allowed "$current_status" "$status"; then
    if scheduler_force_enabled; then
      note="${note:+$note }(forced)"
    else
      echo "ERROR: illegal status transition '$current_status' -> '$status' for task $id." >&2
      echo "  current status: $current_status; legal next: $(legal_targets "$current_status")" >&2
      echo "  Override with --force (or SESSION_SCHEDULER_FORCE=1)." >&2
      return 1
    fi
  fi
  local current
  current=$(cat "$(task_path "$id")")
  local updated
  updated=$(printf '%s' "$current" | jq \
    --arg ts "$(iso_now)" \
    --arg status "$status" \
    --arg actor "$actor" \
    --arg note "$note" \
    '.status = $status
     | .updated_at = $ts
     | (if $status == "assigned" and ((.started_at // null) == null)
        then .started_at = $ts else . end)
     | .history += [{ts: $ts, event: $status, actor: $actor, note: $note}]')
  task_write "$id" "$updated"
}

# Set assignee (used by task-assign).
task_set_assignee() {
  local id="$1" assignee="$2" prompt_file="$3"
  local current
  current=$(cat "$(task_path "$id")")
  local updated
  updated=$(printf '%s' "$current" | jq \
    --arg assignee "$assignee" \
    --arg prompt_file "$prompt_file" \
    '.assignee = $assignee | .prompt_file = $prompt_file')
  task_write "$id" "$updated"
}

validate_task_id() {
  local id="$1"
  if [ -z "$id" ]; then
    echo "ERROR: task id required." >&2
    return 1
  fi
  if ! [[ "$id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: invalid task id '$id' (alphanumeric, _, - only)." >&2
    return 1
  fi
}

# Stage labels are free-form but validated like task ids.
# Suggested stages: plan, dispatch, execute, audit, push.
validate_stage() {
  local stage="$1"
  if [ -z "$stage" ] || ! [[ "$stage" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: invalid stage '$stage' (alphanumeric, _, - only)." >&2
    return 1
  fi
}

# session-context snapshots live under SESSION_CONTEXT_HOME, which must match
# the same override honored by session-context's own get_contexts_dir(). The
# /task-assign command exports it automatically when --context is used. Fail
# closed if it is not set rather than guessing a snapshot location.
resolve_contexts_dir() {
  if [ -z "${SESSION_CONTEXT_HOME:-}" ]; then
    echo "ERROR: SESSION_CONTEXT_HOME is not set (required to attach a --context snapshot)." >&2
    echo "The /task-assign command exports it automatically; export it before direct use." >&2
    return 1
  fi
  printf '%s\n' "$SESSION_CONTEXT_HOME"
}

# Print "dep-id (status)" per dependency of <id> that is not done.
# Missing dependency files report status "missing". Empty output = all met.
unmet_deps() {
  local id="$1" dep dstatus deps
  deps=$(task_get "$id" '(.depends_on // [])[]')
  [ -z "$deps" ] && return 0
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    if task_exists "$dep"; then
      dstatus=$(task_get "$dep" '.status')
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
  now=$(epoch_now)
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
