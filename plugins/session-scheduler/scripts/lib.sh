#!/usr/bin/env bash
# lib.sh — shared helpers for session-scheduler plugin.
# Storage: $SESSION_SCHEDULER_HOME/{tasks,prompts}/...  (same env var as the
#   codex side, so claude and codex panes launched with the same value share a
#   ledger).
# One JSON file per task. Atomic writes (tmp + mv).
# Requires: jq, bash 4+. Depends on session-chat lib.sh for /send.

# SESSION_SCHEDULER_HOME must already be present in this process's environment,
# inherited when the invoking agent/session started: the pane/session launcher
# (or a human's parent shell, for direct script use) establishes it BEFORE the
# agent starts. There is no cwd/git-root fallback and the /task-* commands never
# export it — scripts fail closed rather than guessing a ledger location.
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

# The ledger holds task JSON, executor prompts, and review packets — all of
# which can carry sensitive task content — so keep everything owner-only. umask
# 077 makes new files 0600 / new dirs 0700 (process-local: the /task-* commands
# invoke these scripts as subprocesses, so it never tightens the user's shell).
# Auto-context handoffs are additionally chmod 0400 (immutable) by task-assign.
umask 077

# A real, owner-owned, non-symlink directory.
_sched_dir_is_safe() {
  local d="$1"
  [ -L "$d" ] && return 1
  [ -d "$d" ] || return 1
  [ -O "$d" ] || return 1
  return 0
}

# Owner-only, symlink-safe ledger — FAILS CLOSED. Every /task-* entrypoint calls
# `ensure_dirs || exit 1`, so a non-zero return here aborts the operation rather
# than writing into a tampered tree. Guarantees, re-checked on EVERY call (a
# symlink can be planted after the first run):
#   - scheduler root / tasks / prompts are real, owner-owned, non-symlink dirs
#   - NO nested symlink, unowned entry, or special (non dir/regular) file exists
#   - legacy tree is migrated in place: dirs -> 0700, files -> 0600
# umask 077 keeps NEW files 0600 / dirs 0700; this migrates pre-existing ones.
ensure_dirs() {
  local d entry
  # Never create or write THROUGH a symlink planted at the root/tasks/prompts.
  for d in "$SCHEDULER_DIR" "$TASKS_DIR" "$PROMPTS_DIR"; do
    if [ -L "$d" ]; then
      echo "ERROR: refusing to use scheduler path '$d' — it is a symlink." >&2
      return 1
    fi
  done
  if ! mkdir -p "$TASKS_DIR" "$PROMPTS_DIR" 2>/dev/null; then
    echo "ERROR: could not create scheduler dirs under '$SCHEDULER_DIR'." >&2
    return 1
  fi
  for d in "$SCHEDULER_DIR" "$TASKS_DIR" "$PROMPTS_DIR"; do
    if ! _sched_dir_is_safe "$d"; then
      echo "ERROR: scheduler path '$d' is unsafe (symlink, not a directory, or not owned by you)." >&2
      return 1
    fi
    chmod 700 "$d" 2>/dev/null || { echo "ERROR: could not lock '$d' to 0700." >&2; return 1; }
  done
  # Vet + migrate every entry under tasks/ and prompts/. NUL-safe traversal with
  # an OBSERVED find status: a `< <(find ...)` process substitution hides a
  # traversal failure (e.g. an unreadable subdir) so the loop could vet a partial
  # tree and still succeed, and a pre-planted owner file MAY contain a newline in
  # its name. Capture `find -print0` to a temp file, check find's status, then
  # read NUL-delimited entries. Fail closed on any unsafe condition.
  local entry tmp_list find_rc
  tmp_list=$(mktemp 2>/dev/null) || { echo "ERROR: could not allocate a temp file for ledger traversal." >&2; return 1; }
  find "$TASKS_DIR" "$PROMPTS_DIR" -mindepth 1 -print0 > "$tmp_list" 2>/dev/null
  find_rc=$?
  if [ "$find_rc" -ne 0 ]; then
    rm -f "$tmp_list"
    echo "ERROR: could not fully traverse the ledger (find rc=$find_rc); refusing to operate on a partially-vetted tree." >&2
    return 1
  fi
  while IFS= read -r -d '' entry; do
    [ -n "$entry" ] || continue
    if [ -L "$entry" ]; then
      rm -f "$tmp_list"; echo "ERROR: refusing to operate — nested symlink in ledger: '$entry'." >&2; return 1
    fi
    if [ ! -O "$entry" ]; then
      rm -f "$tmp_list"; echo "ERROR: refusing to operate — entry not owned by you: '$entry'." >&2; return 1
    fi
    if [ -d "$entry" ]; then
      chmod 700 "$entry" 2>/dev/null || { rm -f "$tmp_list"; echo "ERROR: could not lock dir '$entry' to 0700." >&2; return 1; }
    elif [ -f "$entry" ]; then
      chmod 600 "$entry" 2>/dev/null || { rm -f "$tmp_list"; echo "ERROR: could not lock file '$entry' to 0600." >&2; return 1; }
    else
      rm -f "$tmp_list"; echo "ERROR: refusing to operate — special (non dir/regular) file in ledger: '$entry'." >&2; return 1
    fi
  done < "$tmp_list"
  rm -f "$tmp_list"
  return 0
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not installed. Install with: brew install jq" >&2
    return 1
  fi
}

# The scheduler's correctness contract depends on session-chat's durable inbox
# (a dispatch/ack to a busy pane is recovered next turn, not lost) plus the
# owner-only privacy/trust hardening that dispatched task + handoff files rely
# on. Coordinated floor with the Codex side is 0.13.0. Keep this constant, the
# plugin.json description, the SKILL prerequisites, and the doctor in sync.
SESSION_CHAT_MIN_VERSION="0.13.0"

# version_ge <a> <b> — true when semver <a> >= <b>. Plain x.y.z only (the
# marketplace versions have no pre-release suffixes); sort -V handles ordering.
version_ge() {
  [ "$1" = "$2" ] && return 0
  local lowest
  lowest=$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)
  [ "$lowest" = "$2" ]
}

# session_chat_version <root> — best-effort installed session-chat version.
# A cached install dir is named by its version; a source checkout carries it in
# the plugin manifest (claude or codex flavored). Empty output => undetectable.
session_chat_version() {
  local root="$1" base ver mf
  base=$(basename "$root")
  if [[ "$base" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "$base"
    return 0
  fi
  for mf in "$root/.claude-plugin/plugin.json" "$root/.codex-plugin/plugin.json"; do
    [ -f "$mf" ] || continue
    # Extract the "version": "x.y.z" value precisely — robust to single-line
    # JSON (where a naive grep|tr|cut would also swallow the "name" field).
    ver=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$mf" 2>/dev/null \
      | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    [ -n "$ver" ] && { printf '%s\n' "$ver"; return 0; }
  done
  return 1
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
# Returns non-zero on failure so callers that notify AFTER a state transition
# (task-done/task-block) can emit explicit partial-success guidance. Never
# attempts to self-escalate transport access from Bash.
session_chat_send() {
  local target="$1"
  local message="$2"
  local root
  if ! root=$(session_chat_root); then
    echo "WARN: session-chat not installed; skipping ack to '$target'." >&2
    return 1
  fi
  if ! bash "$root/scripts/send-message.sh" "$target" "$message" >/dev/null 2>&1; then
    echo "WARN: session-chat /send to '$target' failed (recipient busy or absent)." >&2
    return 1
  fi
}

session_chat_dispatch() {
  local target="$1"
  local prompt_file="$2"
  local root
  if ! root=$(session_chat_root); then
    echo "ERROR: session-chat not installed; cannot dispatch task. Install session-chat>=${SESSION_CHAT_MIN_VERSION}." >&2
    return 1
  fi
  # Enforce the durable-inbox floor: below it, a busy-pane dispatch is silently
  # lost rather than recovered, which breaks the ledger's assigned-means-queued
  # guarantee. Refuse rather than dispatch into a lossy transport. An explicit
  # SESSION_SCHEDULER_SKIP_VERSION_CHECK=1 escape hatch stays for odd installs
  # where the version can't be read but the operator knows it's current.
  local ver
  if [ "${SESSION_SCHEDULER_SKIP_VERSION_CHECK:-0}" != "1" ] && ver=$(session_chat_version "$root"); then
    if ! version_ge "$ver" "$SESSION_CHAT_MIN_VERSION"; then
      echo "ERROR: session-chat $ver is below the required >= ${SESSION_CHAT_MIN_VERSION}." >&2
      echo "  The scheduler needs 0.13.0+ so a dispatch/ack to a busy pane is recovered from the durable inbox, not lost." >&2
      echo "  Update session-chat, or set SESSION_SCHEDULER_SKIP_VERSION_CHECK=1 to override at your own risk." >&2
      return 1
    fi
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
  local raw
  raw=$(TZ=Asia/Kolkata date +%Y-%m-%dT%H:%M:%S%z) || return 1
  printf '%s:%s\n' "${raw%??}" "${raw#${raw%??}}"
}

epoch_now() {
  date +%s
}

# Convert an ISO-8601 timestamp (IST for new records; UTC for legacy records)
# -> epoch seconds. Tries BSD date first, then GNU.
# Echoes 0 on failure so callers can detect and skip time-based logic.
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

# Convert epoch seconds -> ISO-8601 IST. BSD (date -r) first, GNU (-d @) fallback.
# Echoes empty string on failure.
epoch_to_iso() {
  local epoch="$1" iso=""
  iso=$(TZ=Asia/Kolkata date -r "$epoch" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null) ||
    iso=$(TZ=Asia/Kolkata date -d "@$epoch" +%Y-%m-%dT%H:%M:%S%z 2>/dev/null) ||
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

# Pane names (assignee, reviewer) share the session-chat @name charset.
validate_pane_name() {
  local name="$1" what="${2:-pane}"
  if [ -z "$name" ] || ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: invalid $what name '$name' (alphanumeric, _, - only)." >&2
    return 1
  fi
}

# Workflow ids group related tasks (a plan→execute→review→push arc). Same
# charset so they slot into filenames/JSON without escaping.
validate_workflow_id() {
  local wf="$1"
  if [ -z "$wf" ] || ! [[ "$wf" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: invalid workflow id '$wf' (alphanumeric, _, - only)." >&2
    return 1
  fi
}

# Canonical absolute path of an existing directory (resolves symlinked/worktree
# components) so the value embedded in a dispatched prompt is the same physical
# ledger regardless of which checkout the executor resolves by default. Falls
# back to the input if the dir can't be entered.
abs_dir() {
  local d="$1" real
  real=$(cd "$d" 2>/dev/null && pwd -P) || real="$d"
  printf '%s\n' "$real"
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
# the same override honored by session-context's own get_contexts_dir(). Like
# SESSION_SCHEDULER_HOME it must be inherited at agent startup — never exported
# by a command. Fail closed if it is not set rather than guessing a location.
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
