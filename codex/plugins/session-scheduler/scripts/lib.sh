#!/usr/bin/env bash
# lib.sh — Shared functions for session-scheduler plugin
# Source this file: source "$(dirname "$0")/lib.sh"
# Supported platforms: macOS, Linux

# Ledger records and assignment/review prompts contain private workflow data.
# Make every subsequently created file owner-only by default; immutable auto
# contexts are explicitly tightened further to 0400 by task-assign.sh.
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# SESSION_SCHEDULER_HOME must already be present in this process's environment,
# inherited when the invoking agent/session started: the pane/session launcher
# (or a human's parent shell, for direct script use) establishes it BEFORE the
# agent starts. There is no cwd/git-root fallback and the $session-scheduler:*
# skills never export it — scripts fail closed rather than guessing a ledger.
if [ -z "${SESSION_SCHEDULER_HOME:-}" ]; then
  echo "ERROR: SESSION_SCHEDULER_HOME is not set." >&2
  echo "It must be inherited from the environment this agent process started with" >&2
  echo "(set by the pane/session launcher). An already-running agent must not export" >&2
  echo "it or wrap this helper in env/variable assignments — request a relaunch of the" >&2
  echo "pane/session with the correct environment instead. (A human invoking the script" >&2
  echo "directly may export the variable in their own parent shell first.)" >&2
  exit 1
fi

SCHEDULER_DIR="$SESSION_SCHEDULER_HOME"
TASKS_DIR="$SCHEDULER_DIR/tasks"
PROMPTS_DIR="$SCHEDULER_DIR/prompts"
SESSION_CHAT_MIN_VERSION="0.13.0"

_scheduler_uid() {
  local uid="${EUID:-}"
  case "$uid" in
    ''|*[!0-9]*) uid=$(id -u 2>/dev/null) || return 1 ;;
  esac
  case "$uid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$uid"
}

_scheduler_safe_dir() {
  local dir="$1"
  if [ ! -d "$dir" ] || [ -L "$dir" ] || [ ! -O "$dir" ]; then
    echo "ERROR: Refusing unsafe scheduler directory: $dir" >&2
    return 1
  fi
  # Close an overly broad legacy directory before inspecting or creating
  # anything beneath it. This changes only an owner-owned directory.
  chmod 700 "$dir" 2>/dev/null || return 1
}

ensure_dirs() {
  local dir uid unsafe
  agent_plugins_timezone >/dev/null || return 1

  # Test -L before -e so a dangling pre-planted link is rejected instead of
  # being followed by mkdir -p.
  if [ -L "$SCHEDULER_DIR" ]; then
    echo "ERROR: Refusing unsafe scheduler root: $SCHEDULER_DIR" >&2
    return 1
  fi
  if [ ! -e "$SCHEDULER_DIR" ]; then
    mkdir -p "$SCHEDULER_DIR" || return 1
  fi
  _scheduler_safe_dir "$SCHEDULER_DIR" || return 1

  for dir in "$TASKS_DIR" "$PROMPTS_DIR"; do
    if [ -L "$dir" ]; then
      echo "ERROR: Refusing unsafe scheduler directory: $dir" >&2
      return 1
    fi
    if [ ! -e "$dir" ]; then
      # Initial callers can race while creating the shared ledger. A competing
      # mkdir is acceptable only if the winner's path passes the safety checks.
      if ! mkdir -m 700 "$dir" 2>/dev/null && [ ! -e "$dir" ]; then
        return 1
      fi
    fi
    _scheduler_safe_dir "$dir" || return 1
  done

  # Existing ledgers may pre-date private defaults. Migrate files only after
  # proving the complete tree is owner-owned and contains no symlinks or
  # special files; otherwise fail closed before any task/prompt read. This
  # protects every consumer, including commands that load task JSON directly.
  uid=$(_scheduler_uid) || {
    echo "ERROR: Could not determine the current UID for scheduler ownership checks." >&2
    return 1
  }
  unsafe=$(find "$SCHEDULER_DIR" -type l -print -quit 2>/dev/null) || {
    echo "ERROR: Could not inspect scheduler tree: $SCHEDULER_DIR" >&2
    return 1
  }
  if [ -n "$unsafe" ]; then
    echo "ERROR: Refusing scheduler tree containing a symlink: $unsafe" >&2
    return 1
  fi
  unsafe=$(find "$SCHEDULER_DIR" ! -user "$uid" -print -quit 2>/dev/null) || {
    echo "ERROR: Could not inspect scheduler tree ownership: $SCHEDULER_DIR" >&2
    return 1
  }
  if [ -n "$unsafe" ]; then
    echo "ERROR: Refusing scheduler tree containing an unowned path: $unsafe" >&2
    return 1
  fi
  unsafe=$(find "$SCHEDULER_DIR" ! -type d ! -type f -print -quit 2>/dev/null) || {
    echo "ERROR: Could not inspect scheduler tree types: $SCHEDULER_DIR" >&2
    return 1
  }
  if [ -n "$unsafe" ]; then
    echo "ERROR: Refusing scheduler tree containing a special file: $unsafe" >&2
    return 1
  fi

  find "$SCHEDULER_DIR" -type d -exec chmod 700 {} + 2>/dev/null || return 1
  find "$SCHEDULER_DIR" -type f -exec chmod 600 {} + 2>/dev/null || return 1
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required for session-scheduler." >&2
    return 1
  fi
}

agent_plugins_timezone() {
  local timezone="${AGENT_PLUGINS_TIME_ZONE:-Asia/Kolkata}" root
  case "$timezone" in
    ""|/*|*..*|*[!A-Za-z0-9_+./-]*)
      echo "ERROR: AGENT_PLUGINS_TIME_ZONE must be a valid IANA timezone, got '$timezone'." >&2
      return 1
      ;;
  esac
  for root in /usr/share/zoneinfo /usr/share/lib/zoneinfo /usr/lib/zoneinfo; do
    [ -f "$root/$timezone" ] && { printf '%s\n' "$timezone"; return 0; }
  done
  echo "ERROR: unknown IANA timezone in AGENT_PLUGINS_TIME_ZONE: '$timezone'." >&2
  return 1
}

now_iso() {
  local raw timezone
  timezone=$(agent_plugins_timezone) || return 1
  raw=$(TZ="$timezone" date +%Y-%m-%dT%H:%M:%S%z) || return 1
  printf '%s:%s\n' "${raw%??}" "${raw#${raw%??}}"
}

now_epoch() {
  date +%s
}

# Convert an ISO-8601 timestamp (configured timezone for new records; UTC for legacy records)
# -> epoch seconds. BSD date first, GNU fallback.
# Echoes 0 on failure so callers can skip time-based logic.
iso_to_epoch() {
  local iso="$1" epoch=""
  if [[ "$iso" =~ Z$ ]]; then
    iso="${iso%Z}+0000"
  elif [[ "$iso" =~ [+-][0-9]{2}:[0-9]{2}$ ]]; then
    iso="${iso%:*}${iso##*:}"
  fi
  epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$iso" +%s 2>/dev/null) ||
    epoch=$(date -d "$iso" +%s 2>/dev/null) ||
    epoch=""
  printf '%s\n' "${epoch:-0}"
}

# Convert epoch seconds -> ISO-8601 in the configured timezone. BSD (date -r) first, GNU (-d @) fallback.
# Echoes empty string on failure.
epoch_to_iso() {
  local epoch="$1" iso="" timezone
  timezone=$(agent_plugins_timezone) || return 1
  iso=$(TZ="$timezone" date -r "$epoch" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null) ||
    iso=$(TZ="$timezone" date -d "@$epoch" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null) ||
    iso=""
  [ -n "$iso" ] && iso="$(printf '%s:%s' "${iso%??}" "${iso#${iso%??}}")"
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

validate_route_name() {
  local label="$1" value="$2"
  if [ -z "$value" ] || ! [[ "$value" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo "ERROR: Invalid $label: $value (alphanumeric, _, ., - only)." >&2
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

# Validate a prompt_file path read from a task record before task-review reads
# it into a review packet. The stored path is untrusted: require the exact
# generated path for this task, reject lexical traversal and file symlinks, and
# verify that its canonical parent is the scheduler prompts directory.
trusted_recorded_prompt_file() {
  local id="$1" candidate="$2"
  local expected canonical_prompts canonical_parent

  [ -n "$candidate" ] || return 1
  case "$candidate" in
    /*) ;;
    *) return 1 ;;
  esac
  case "/$candidate/" in
    */../*|*/./*) return 1 ;;
  esac

  expected=$(prompt_file "$id") || return 1
  [ "$candidate" = "$expected" ] || return 1
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1

  canonical_prompts=$(absolute_existing_dir "$PROMPTS_DIR") || return 1
  canonical_parent=$(absolute_existing_dir "$(dirname "$candidate")") || return 1
  [ "$canonical_parent" = "$canonical_prompts" ] || return 1

  printf '%s\n' "$candidate"
}

current_pane_name() {
  if command -v tmux >/dev/null 2>&1 && [ -n "${TMUX_PANE:-}" ]; then
    tmux display-message -p -t "$TMUX_PANE" '#{@name}' 2>/dev/null || true
  fi
}

session_chat_root() {
  local candidate=""
  if [ -n "${SESSION_CHAT_ROOT_OVERRIDE:-}" ] && [ -d "$SESSION_CHAT_ROOT_OVERRIDE" ]; then
    candidate="$SESSION_CHAT_ROOT_OVERRIDE"
  elif [ -n "${SESSION_CHAT_PLUGIN_ROOT:-}" ] && [ -d "$SESSION_CHAT_PLUGIN_ROOT" ]; then
    candidate="$SESSION_CHAT_PLUGIN_ROOT"
  else
    local cache_base="${CODEX_HOME:-$HOME/.codex}/plugins/cache/girishattri-plugins/session-chat"
    if [ -d "$cache_base" ]; then
    local latest_version
    latest_version=$(find "$cache_base" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
    if [ -n "$latest_version" ] && [ -d "$cache_base/$latest_version" ]; then
        candidate="$cache_base/$latest_version"
      fi
    fi
  fi
  if [ -z "$candidate" ]; then
    local sibling="$PLUGIN_ROOT/../session-chat"
    [ -d "$sibling" ] && candidate="$sibling"
  fi
  if [ -z "$candidate" ]; then
    echo "ERROR: session-chat >= $SESSION_CHAT_MIN_VERSION is required but was not found." >&2
    return 1
  fi
  local actual
  actual=$(session_chat_version "$candidate")
  if ! semver_gte "$actual" "$SESSION_CHAT_MIN_VERSION"; then
    echo "ERROR: session-chat >= $SESSION_CHAT_MIN_VERSION is required; found $actual at $candidate." >&2
    return 1
  fi
  printf '%s\n' "$candidate"
}

session_chat_version() {
  local root="$1"
  jq -r '.version // "unknown"' "$root/.codex-plugin/plugin.json" 2>/dev/null || echo "unknown"
}

semver_gte() {
  local actual="${1%%+*}" minimum="${2%%+*}"
  actual="${actual%%-*}"
  minimum="${minimum%%-*}"
  local a1=0 a2=0 a3=0 m1=0 m2=0 m3=0
  IFS=. read -r a1 a2 a3 <<< "$actual"
  IFS=. read -r m1 m2 m3 <<< "$minimum"
  [[ "$a1" =~ ^[0-9]+$ && "$a2" =~ ^[0-9]+$ && "$a3" =~ ^[0-9]+$ ]] || return 1
  [[ "$m1" =~ ^[0-9]+$ && "$m2" =~ ^[0-9]+$ && "$m3" =~ ^[0-9]+$ ]] || return 1
  [ "$a1" -gt "$m1" ] ||
    { [ "$a1" -eq "$m1" ] && [ "$a2" -gt "$m2" ]; } ||
    { [ "$a1" -eq "$m1" ] && [ "$a2" -eq "$m2" ] && [ "$a3" -ge "$m3" ]; }
}

absolute_existing_dir() {
  local dir="$1"
  (cd "$dir" 2>/dev/null && pwd -P)
}

workspace_root() {
  local dir
  dir=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/workspace.sh" ] && grep -q 'SESSION_SCHEDULER_HOME' "$dir/workspace.sh" 2>/dev/null; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
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

# context snapshots live under SESSION_CONTEXT_HOME, which must match
# the same override honored by the knowledge context store's own get_contexts_dir(). Like
# SESSION_SCHEDULER_HOME it must be inherited at agent startup — the
# $session-scheduler:task-assign skill never exports it. Fail closed if it is
# not set rather than guessing a snapshot location.
resolve_contexts_dir() {
  if [ -z "${SESSION_CONTEXT_HOME:-}" ]; then
    echo "ERROR: SESSION_CONTEXT_HOME is not set (required to attach a --context snapshot)." >&2
    echo "It must be inherited from the environment this agent process started with;" >&2
    echo "relaunch the pane/session with the correct environment. (A human invoking the" >&2
    echo "script directly may export the variable in their own parent shell first.)" >&2
    return 1
  fi
  printf '%s\n' "$SESSION_CONTEXT_HOME"
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

# Compute attention flags for a task json file: OVERDUE (past eta_at while the
# task can still be acted on) and/or STALE (assigned/review with no update for
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
  # OVERDUE only makes sense while a task can still be acted on, so suppress it
  # for terminal/at-rest states: `done` (finished) and `blocked` (paused,
  # waiting on an external unblock — nobody is currently late). A blocked task
  # that resumes (-> assigned) with a past eta becomes OVERDUE again naturally.
  # This mirrors STALE, which likewise only applies to assigned/review.
  case "$status" in
    done|blocked) ;;
    *)
      if [ -n "$eta" ]; then
        eta_epoch=$(iso_to_epoch "$eta")
        if [ "$eta_epoch" -gt 0 ] && [ "$now" -gt "$eta_epoch" ]; then
          flags="OVERDUE"
        fi
      fi
      ;;
  esac
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
  stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null
}
