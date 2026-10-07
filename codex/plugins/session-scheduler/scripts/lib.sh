#!/usr/bin/env bash
# lib.sh — Shared functions for session-scheduler plugin
# Source this file: source "$(dirname "$0")/lib.sh"
# Supported platforms: macOS, Linux

# --- Diagnostics (diag/1) ---
# Machine-readable fault lines for the ORDINARY paths of task-done.sh,
# task-block.sh and task-review.sh. Every other caller of this library (the
# other helpers, test code that sources it) keeps the exact pre-diagnostics
# output: the emitter is a no-op unless the running script is one of the three.
#
# Contract (registry: ../diagnostics/registry.json):
#   - one line on stderr, `DIAG ` + compact JSON, AFTER the existing human text;
#   - built only by an allowlisting jq serializer (--arg/--argjson, no string
#     interpolation); the jq-missing record is a fixed string;
#   - a diagnostic never changes an exit code or the human output, and a failed
#     emit is ignored;
#   - codes are assigned at the failing branch (typed), never parsed from text.
# Diagnostic state lives ONLY in the top-level helper process. Library functions
# that run inside $(...) never touch it: they report through stdout/rc and the
# helper maps that to a code. Library functions called directly (not in a
# command substitution) may append a code to SCHED_DIAG_CODES before they
# return non-zero; the first code is the primary fault, later ones are
# secondary (cleanup/unlock) faults of the same operation.
_SCHED_DIAG_HELPER=""
case "${0##*/}" in
  task-done.sh|task-block.sh|task-review.sh) _SCHED_DIAG_HELPER="${0##*/}" ;;
esac
_SCHED_DIAG_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
SCHED_DIAG_CODES=()
# 1 when the last ledger publication (the rename in task_write) failed in a way that
# does not prove it did not happen (see task_write). Typed input for state_committed.
SCHED_WRITE_UNCERTAIN=0

# Forget every code noted so far. Call before each independent operation.
sched_diag_reset() { SCHED_DIAG_CODES=(); SCHED_WRITE_UNCERTAIN=0; }

# state_committed for a failed transition write: false only when the failure is proven to
# precede publication; null when the publication is unconfirmed.
sched_commit_state() { if [ "${SCHED_WRITE_UNCERTAIN:-0}" = 1 ]; then echo null; else echo false; fi; }

# The human line for a failed transition. An unconfirmed publication must not claim that
# nothing changed.
sched_transition_failed() { # sched_transition_failed <id> <"marked done."|"marked blocked."|"moved to review.">
  if [ "${SCHED_WRITE_UNCERTAIN:-0}" = 1 ]; then
    echo "ERROR: task $1 result unconfirmed - the ledger write may have committed; inspect task-status before any retry." >&2
  else
    echo "ERROR: task $1 NOT $2" >&2
  fi
}

# Append <code> unless already present. Direct calls only.
_sched_diag_note() {
  [ -n "$_SCHED_DIAG_HELPER" ] || return 0
  local c
  for c in ${SCHED_DIAG_CODES[@]+"${SCHED_DIAG_CODES[@]}"}; do
    [ "$c" = "$1" ] && return 0
  done
  SCHED_DIAG_CODES+=("$1")
  return 0
}

# The emitting plugin's own version: scripts/../.claude-plugin/plugin.json (or
# the Codex manifest of the same tree). Empty when it cannot be read.
_sched_diag_version() {
  local mf ver
  for mf in "$_SCHED_DIAG_LIBDIR/../.claude-plugin/plugin.json" "$_SCHED_DIAG_LIBDIR/../.codex-plugin/plugin.json"; do
    [ -f "$mf" ] || continue
    ver=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$mf" 2>/dev/null \
      | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    [ -n "$ver" ] && { printf '%s' "$ver"; return 0; }
  done
  return 1
}

# Defaults for a code: subject, phase and outcome. A caller may override any.
_sched_diag_meta() {
  _DG_SUBJECT="transition"; _DG_PHASE="validate"; _DG_OUTCOME="refused"
  case "$1" in
    sched.store.unavailable) _DG_OUTCOME="failed" ;;
    sched.argv.*) _DG_PHASE="argv" ;;
    sched.lock.timeout|sched.lock.holder_unwritable) _DG_SUBJECT="lock"; _DG_PHASE="transition"; _DG_OUTCOME="failed" ;;
    sched.lock.unsafe) _DG_SUBJECT="lock"; _DG_PHASE="transition" ;;
    sched.lock.release_failed) _DG_SUBJECT="lock"; _DG_PHASE="cleanup"; _DG_OUTCOME="failed" ;;
    sched.contract.legacy_write_refused|sched.transition.illegal|sched.ledger.write_refused) _DG_PHASE="transition" ;;
    sched.ledger.write_failed) _DG_PHASE="transition"; _DG_OUTCOME="failed" ;;
    sched.duration.record_failed) _DG_SUBJECT="duration"; _DG_PHASE="transition"; _DG_OUTCOME="partial" ;;
    sched.review.*) _DG_SUBJECT="reviewer_request"; _DG_PHASE="notify"; _DG_OUTCOME="partial" ;;
    sched.notify.*) _DG_SUBJECT="assigner_ack"; _DG_PHASE="notify"; _DG_OUTCOME="partial" ;;
    sched.bookkeeping.*) _DG_SUBJECT="bookkeeping"; _DG_PHASE="notify"; _DG_OUTCOME="partial" ;;
    sched.note_file.option_malformed) _DG_SUBJECT="verdict_event"; _DG_PHASE="argv" ;;
    sched.note_file.*) _DG_SUBJECT="verdict_event" ;;
  esac
}

# sched_diag_emit [key=value ...]
# Keys: reason subject phase outcome committed(true|false|null) nfor nobs npers
#   task generation event request also(space-separated extra codes)
#   lib(0|1: merge SCHED_DIAG_CODES, default 1)
#   codes(space-separated codes captured earlier, used instead of the array).
# With lib=1 and no reason, the first noted code is the primary fault and the
# rest become `also`. Prints nothing when disabled, when there is no code, or
# when the serializer is unavailable; always returns 0.
sched_diag_emit() {
  [ -n "$_SCHED_DIAG_HELPER" ] || return 0
  local reason="" subject="" phase="" outcome="" committed="false" nfor="" nobs="" npers=""
  local task="" gen="" event="" request="" xalso="" lib=1 kv c libcodes="${SCHED_DIAG_CODES[*]-}"
  for kv in "$@"; do
    case "$kv" in
      reason=*) reason="${kv#reason=}" ;;
      subject=*) subject="${kv#subject=}" ;;
      phase=*) phase="${kv#phase=}" ;;
      outcome=*) outcome="${kv#outcome=}" ;;
      committed=*) committed="${kv#committed=}" ;;
      nfor=*) nfor="${kv#nfor=}" ;;
      nobs=*) nobs="${kv#nobs=}" ;;
      npers=*) npers="${kv#npers=}" ;;
      task=*) task="${kv#task=}" ;;
      generation=*) gen="${kv#generation=}" ;;
      event=*) event="${kv#event=}" ;;
      request=*) request="${kv#request=}" ;;
      also=*) xalso="${kv#also=}" ;;
      lib=*) lib="${kv#lib=}" ;;
      codes=*) libcodes="${kv#codes=}" ;;
    esac
  done
  local also=""
  if [ "$lib" = 1 ]; then
    for c in $libcodes; do
      if [ -z "$reason" ]; then reason="$c"; elif [ "$c" != "$reason" ]; then also="$also $c"; fi
    done
  fi
  for c in $xalso; do
    [ "$c" = "$reason" ] || also="$also $c"
  done
  [ -n "$reason" ] || return 0
  _sched_diag_meta "$reason"
  [ -n "$subject" ] || subject="$_DG_SUBJECT"
  [ -n "$phase" ] || phase="$_DG_PHASE"
  [ -n "$outcome" ] || outcome="$_DG_OUTCOME"
  case "$committed" in true|false|null) ;; *) committed="null" ;; esac
  local version line
  version=$(_sched_diag_version 2>/dev/null) || version=""
  line=$(jq -cn \
    --arg helper "$_SCHED_DIAG_HELPER" --arg version "$version" \
    --arg subject "$subject" --arg phase "$phase" --arg reason "$reason" --arg outcome "$outcome" \
    --argjson committed "$committed" \
    --arg nfor "$nfor" --arg nobs "$nobs" --arg npers "$npers" \
    --arg task "$task" --arg gen "$gen" --arg event "$event" --arg request "$request" \
    --arg also "$also" '
    def pick($set): if type == "string" and (. as $v | $set | index($v)) != null then . else null end;
    def idv($re; $max): if type == "string" and test($re) and length <= $max then . else null end;
    ($also | split(" ") | map(select(test("^[a-z]+(\\.[a-z_]+)+$")))) as $al
    | {schema: "diag/1", emitter: "scheduler", helper: ($helper | pick(["task-done.sh", "task-block.sh", "task-review.sh"])),
       version: ($version | idv("^[0-9]+\\.[0-9]+\\.[0-9]+$"; 32)),
       subject: ($subject | pick(["transition", "assigner_ack", "reviewer_request", "verdict_event", "duration", "lock", "bookkeeping", "admission"])),
       phase: ($phase | pick(["argv", "validate", "admission", "transition", "notify", "cleanup"])),
       reason: ($reason | idv("^[a-z]+(\\.[a-z_]+)+$"; 64)),
       outcome: ($outcome | pick(["refused", "failed", "partial"])),
       state_committed: $committed,
       notification: (($nfor | pick(["assigner_ack", "reviewer_request", "verdict_event"])) as $nf
         | if $nf == null then null else
           {for: $nf,
            observed: ($nobs | pick(["delivered", "queued", "inline-fallback", "failed"])),
            persisted: ($npers | pick(["pending", "delivered", "queued", "inline-fallback", "failed", "not-required", "unknown"]))} end),
       task: ($task | idv("^[A-Za-z0-9_-]+$"; 128)),
       generation: (if ($gen | test("^[0-9]{1,9}$")) then ($gen | tonumber) else null end),
       event: ($event | idv("^[a-f0-9]{8,16}$"; 16)),
       request: ($request | idv("^[a-f0-9]{8,16}$"; 16)),
       also: ($al[:4]), also_truncated: (($al | length) > 4)}' 2>/dev/null) || return 0
  case "$line" in
    ""|*$'\n'*) return 0 ;;
  esac
  printf 'DIAG %s\n' "$line" >&2 2>/dev/null || true
  return 0
}

# Emit a lock-release-only record when an operation SUCCEEDED but the lock
# could not be released (the only code left in the slot after a success).
sched_diag_residual() {
  [ "${#SCHED_DIAG_CODES[@]}" -gt 0 ] || return 0
  sched_diag_emit committed=true "$@"
}

# sched_diag_ack_report <committed> <task-id>
# After session_chat_ack + task_record_last_ack (SCHED_DIAG_CODES reset before
# the record call). Emits at most two independent operation records:
#   - assigner_ack: the ack ended failed or inline-fallback;
#   - bookkeeping: meta.last_ack could not be recorded (persisted unknown,
#     never an invented pending record).
# A delivered/queued ack with a recorded outcome emits nothing.
sched_diag_ack_report() {
  [ -n "$_SCHED_DIAG_HELPER" ] || return 0
  local committed="$1" id="$2" obs="${SESSION_CHAT_ACK_OBSERVED:-}" persisted reason
  case "${SESSION_CHAT_ACK_STATUS:-}" in
    failed|inline-fallback)
      persisted="${SESSION_CHAT_ACK_STATUS}"
      [ "${SCHED_LAST_ACK_RECORD:-failed}" = "ok" ] || persisted="unknown"
      reason="sched.notify.failed"
      [ "${SESSION_CHAT_ACK_STATUS}" = "inline-fallback" ] && reason="sched.notify.inline_fallback"
      sched_diag_emit reason="$reason" subject=assigner_ack committed="$committed" \
        nfor=assigner_ack nobs="$obs" npers="$persisted" task="$id" lib=0
      ;;
  esac
  if [ "${SCHED_LAST_ACK_RECORD:-failed}" = "ok" ]; then
    sched_diag_residual committed="$committed" task="$id"
  else
    sched_diag_emit reason=sched.bookkeeping.last_ack_failed subject=bookkeeping committed="$committed" \
      nfor=assigner_ack nobs="$obs" npers=unknown task="$id"
  fi
  return 0
}

# sched_diag_verdict_report <task-id> <event-id> <outcome> <record-state> <attempt>
# After verdict_notify_typed (outcome word, attempt yes|no) and verdict_record_outcome
# (record-state ok|failed|unconfirmed; SCHED_DIAG_CODES reset before it). One record for
# the verdict_event operation; its first fault wins and a failed outcome record is a
# secondary code. Delivered/queued with a recorded outcome emits nothing.
# observed is "failed" only when a transport script ran (attempt yes); a refusal before
# any transport reports null. persisted is the recorded state: "pending" when the outcome
# write provably did not publish, "unknown" when its publication is unconfirmed.
sched_diag_verdict_report() {
  [ -n "$_SCHED_DIAG_HELPER" ] || return 0
  local id="$1" ve="$2" outcome="$3" rec="$4" attempt="${5:-no}" persisted="pending" reason secondary="" obs
  [ "$rec" = "unconfirmed" ] && persisted="unknown"
  case "$outcome" in
    failed|inline-fallback)
      [ "$rec" = "ok" ] && persisted="$outcome"
      [ "$rec" = "ok" ] || secondary="sched.notify.record_failed"
      reason="sched.notify.failed"; obs="$outcome"
      if [ "$outcome" = "inline-fallback" ]; then reason="sched.notify.inline_fallback"
      elif [ "$attempt" != "yes" ]; then obs=""; fi
      sched_diag_emit reason="$reason" subject=verdict_event committed=true nfor=verdict_event \
        nobs="$obs" npers="$persisted" task="$id" event="$ve" also="$secondary"
      ;;
    delivered|queued)
      if [ "$rec" = "ok" ]; then
        sched_diag_residual task="$id" event="$ve"
      else
        sched_diag_emit reason=sched.notify.record_failed subject=verdict_event committed=true \
          nfor=verdict_event nobs="$outcome" npers="$persisted" task="$id" event="$ve"
      fi
      ;;
  esac
  return 0
}

# Fixed bootstrap records for the two faults that happen before jq can be
# trusted. No input is interpolated: helper and reason are matched against
# literal constants and the JSON text is fixed.
_sched_diag_bootstrap() {
  [ -n "$_SCHED_DIAG_HELPER" ] || return 0
  local h r
  case "$_SCHED_DIAG_HELPER" in
    task-done.sh) h='"task-done.sh"' ;;
    task-block.sh) h='"task-block.sh"' ;;
    task-review.sh) h='"task-review.sh"' ;;
    *) return 0 ;;
  esac
  case "$1" in
    sched.env.home_unset) r='"sched.env.home_unset"' ;;
    sched.env.jq_missing) r='"sched.env.jq_missing"' ;;
    *) return 0 ;;
  esac
  printf 'DIAG {"schema":"diag/1","emitter":"scheduler","helper":%s,"version":null,"subject":"transition","phase":"validate","reason":%s,"outcome":"refused","state_committed":false,"notification":null,"task":null,"generation":null,"event":null,"request":null,"also":[],"also_truncated":false}\n' "$h" "$r" >&2 2>/dev/null || true
  return 0
}

# Ledger records and assignment/review prompts contain private workflow data.
# Make every subsequently created file owner-only by default.
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
  if command -v jq >/dev/null 2>&1; then
    _sched_diag_note sched.env.home_unset; sched_diag_emit
  else
    _sched_diag_bootstrap sched.env.home_unset
  fi
  exit 1
fi

SCHEDULER_DIR="$SESSION_SCHEDULER_HOME"
TASKS_DIR="$SCHEDULER_DIR/tasks"
PROMPTS_DIR="$SCHEDULER_DIR/prompts"
HANDOFFS_DIR="$SCHEDULER_DIR/handoffs"
LOCKS_DIR="$SCHEDULER_DIR/locks"
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
    _sched_diag_note sched.store.unsafe
    return 1
  fi
  # Close an overly broad legacy directory before inspecting or creating
  # anything beneath it. This changes only an owner-owned directory.
  chmod 700 "$dir" 2>/dev/null || return 1
}

_ensure_dirs() {
  local dir uid unsafe
  agent_plugins_timezone >/dev/null || { _sched_diag_note sched.env.timezone_invalid; return 1; }

  # Test -L before -e so a dangling pre-planted link is rejected instead of
  # being followed by mkdir -p.
  if [ -L "$SCHEDULER_DIR" ]; then
    echo "ERROR: Refusing unsafe scheduler root: $SCHEDULER_DIR" >&2
    _sched_diag_note sched.store.unsafe
    return 1
  fi
  if [ ! -e "$SCHEDULER_DIR" ]; then
    mkdir -p "$SCHEDULER_DIR" || return 1
  fi
  _scheduler_safe_dir "$SCHEDULER_DIR" || return 1

  for dir in "$TASKS_DIR" "$PROMPTS_DIR" "$HANDOFFS_DIR" "$LOCKS_DIR"; do
    if [ -L "$dir" ]; then
      echo "ERROR: Refusing unsafe scheduler directory: $dir" >&2
    _sched_diag_note sched.store.unsafe
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
  unsafe=$(find "$TASKS_DIR" "$PROMPTS_DIR" "$HANDOFFS_DIR" -type l -print -quit 2>/dev/null) || {
    echo "ERROR: Could not inspect scheduler tree: $SCHEDULER_DIR" >&2
    return 1
  }
  if [ -n "$unsafe" ]; then
    echo "ERROR: Refusing scheduler tree containing a symlink: $unsafe" >&2
    _sched_diag_note sched.store.unsafe
    return 1
  fi
  unsafe=$(find "$TASKS_DIR" "$PROMPTS_DIR" "$HANDOFFS_DIR" ! -user "$uid" -print -quit 2>/dev/null) || {
    echo "ERROR: Could not inspect scheduler tree ownership: $SCHEDULER_DIR" >&2
    return 1
  }
  if [ -n "$unsafe" ]; then
    echo "ERROR: Refusing scheduler tree containing an unowned path: $unsafe" >&2
    _sched_diag_note sched.store.unsafe
    return 1
  fi
  unsafe=$(find "$TASKS_DIR" "$PROMPTS_DIR" "$HANDOFFS_DIR" ! -type d ! -type f -print -quit 2>/dev/null) || {
    echo "ERROR: Could not inspect scheduler tree types: $SCHEDULER_DIR" >&2
    return 1
  }
  if [ -n "$unsafe" ]; then
    echo "ERROR: Refusing scheduler tree containing a special file: $unsafe" >&2
    _sched_diag_note sched.store.unsafe
    return 1
  fi

  find "$TASKS_DIR" "$PROMPTS_DIR" "$HANDOFFS_DIR" -type d -exec chmod 700 {} + 2>/dev/null || return 1
  find "$TASKS_DIR" "$PROMPTS_DIR" "$HANDOFFS_DIR" -type f -exec chmod 600 {} + 2>/dev/null || return 1
}

ensure_dirs() {
  if _ensure_dirs; then return 0; fi
  [ "${#SCHED_DIAG_CODES[@]}" -gt 0 ] || _sched_diag_note sched.store.unavailable
  return 1
}

# Non-reentrant, cross-provider task transaction lock. Never hold over transport.
_scheduler_reclaim_lock() (
  # Keep every access on this directory generation, even if release renames it.
  local path="$1" expected="$2" result=1
  [ ! -L "$path" ] && cd -P "$path" 2>/dev/null || return 1
  mkdir reclaim 2>/dev/null || return 1
  if [ "$(cat pid 2>/dev/null)" = "$expected" ]; then
    printf '%s\n' "$$" > pid 2>/dev/null && result=0
  fi
  rmdir reclaim 2>/dev/null || true
  return "$result"
)

_scheduler_release_lock() {
  local path="$1" retired
  [ ! -L "$path" ] && [ ! -L "$path/pid" ] || return 1
  [ "$(cat "$path/pid" 2>/dev/null)" = "$$" ] || return 1
  retired=$(mktemp -d "$LOCKS_DIR/.release.XXXXXXXX") || return 1
  # The destination does not exist. Rename detaches pid and reclaim together;
  # no waiter can observe an ownerless directory at the acquisition path.
  if ! mv "$path" "$retired/lock"; then
    rmdir "$retired" 2>/dev/null || true
    return 1
  fi
  rm -rf "$retired"
}

acquire_task_lock() {
  local id="$1" path holder diagnostic start timeout
  validate_task_id "$id" || return 1
  path="$LOCKS_DIR/$id.lock"
  timeout="${SESSION_SCHEDULER_LOCK_TIMEOUT_SECS:-10}"
  [[ "$timeout" =~ ^[0-9]+$ ]] || { echo "ERROR: invalid lock timeout: $timeout" >&2; return 1; }
  start=$(now_epoch)
  while ! mkdir -m 700 "$path" 2>/dev/null; do
    if [ -L "$path" ] || [ ! -d "$path" ] || [ ! -O "$path" ]; then
      # The previous holder may have released between mkdir and inspection.
      [ ! -e "$path" ] && [ ! -L "$path" ] && continue
      echo "ERROR: unsafe task lock: $path" >&2; _sched_diag_note sched.lock.unsafe; return 1
    fi
    holder=""
    if [ -f "$path/pid" ] && [ ! -L "$path/pid" ] && [ -O "$path/pid" ]; then
      read -r holder < "$path/pid" || true
    fi
    if [[ "$holder" =~ ^[1-9][0-9]*$ ]]; then
      diagnostic=$(LC_ALL=C kill -0 "$holder" 2>&1)
      if [ $? -ne 0 ] && [[ "$diagnostic" == *"No such process"* ]]; then
        _scheduler_reclaim_lock "$path" "$holder" && return 0
      fi
    fi
    if [ $(( $(now_epoch) - start )) -ge "$timeout" ]; then
      echo "ERROR: timed out acquiring task lock: $path" >&2; _sched_diag_note sched.lock.timeout; return 1
    fi
    sleep 0.05
  done
  if ! printf '%s\n' "$$" > "$path/pid"; then
    rmdir "$path" 2>/dev/null || true
    _sched_diag_note sched.lock.holder_unwritable
    return 1
  fi
}

release_task_lock() {
  _scheduler_release_lock "$LOCKS_DIR/$1.lock" || { _sched_diag_note sched.lock.release_failed; return 1; }
}

lock_task_for_command() {
  acquire_task_lock "$1" || return 1
  SCHEDULER_LOCKED_TASK="$1"
  trap 'release_task_lock "$SCHEDULER_LOCKED_TASK" || true; _sched_diag_export' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

require_flag_value() {
  if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then
    echo "ERROR: $1 requires a value." >&2
    return 1
  fi
}

# Transactions run in a subshell as before. Only their typed diagnostic state
# crosses back to the caller; their normal stdout is empty.
_sched_diag_export() {
  [ "${_SCHED_DIAG_CAPTURE:-0}" = 1 ] || return 0
  local code
  for code in ${SCHED_DIAG_CODES[@]+"${SCHED_DIAG_CODES[@]}"}; do printf 'code:%s\n' "$code"; done
  printf 'uncertain:%s\n' "$SCHED_WRITE_UNCERTAIN"
}

_sched_diag_collect() {
  local result rc line
  result=$(
    _SCHED_DIAG_CAPTURE=1
    trap '_sched_diag_export' EXIT
    "$@"
  ); rc=$?
  while IFS= read -r line; do
    case "$line" in
      code:sched.*) _sched_diag_note "${line#code:}" ;;
      uncertain:1) SCHED_WRITE_UNCERTAIN=1 ;;
    esac
  done <<< "$result"
  return "$rc"
}

_task_jq_update() {
  local file="$1" id
  shift
  id=$(basename "$file" .json)
  lock_task_for_command "$id" || exit 1
  [ -f "$file" ] || { echo "ERROR: Task not found: $id" >&2; exit 1; }
  if jq -e 'has("contract")' "$file" >/dev/null; then
    echo "ERROR: task has a verification contract; use task-contract.sh" >&2
    _sched_diag_note sched.contract.legacy_write_refused
    exit 1
  fi
  local updated
  updated=$(jq "$@" "$file") || { _sched_diag_note sched.ledger.write_failed; return 1; }
  write_json_atomic "$file" <<< "$updated"
}

task_jq_update() {
  if [ -n "$_SCHED_DIAG_HELPER" ]; then
    _sched_diag_collect _task_jq_update "$@"
  else
    ( _task_jq_update "$@" )
  fi
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required for session-scheduler." >&2
    _sched_diag_bootstrap sched.env.jq_missing
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
  local hex epoch
  command -v od >/dev/null 2>&1 || return 1
  # od's own exit status is checked in a plain assignment BEFORE any pipe, so a
  # failing od can never be hidden by tr (no dependence on pipefail).
  hex=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null) || return 1
  hex=$(printf '%s' "$hex" | tr -d ' \n')
  [[ "$hex" =~ ^[a-f0-9]{8}$ ]] || return 1
  epoch=$(date +%s 2>/dev/null) || return 1
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  printf 'task-%s-%s' "$epoch" "$hex"
}

validate_task_id() {
  local id="$1"
  if [ -z "$id" ] || [ "$id" = . ] || [ "$id" = .. ] || ! [[ "$id" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo "ERROR: Invalid task id: $id" >&2
    if [ -z "$id" ]; then _sched_diag_note sched.argv.task_id_missing; else _sched_diag_note sched.argv.task_id_invalid; fi
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

# Context snapshot names are owned by the knowledge context store. Scheduler
# attachments must use the same canonical snake_case contract so every
# generated handoff can be loaded by either provider.
SESSION_SCHEDULER_CANONICAL_NAME_REGEX='^[a-z0-9]+(_[a-z0-9]+)*$'

validate_context_name() {
  local name="$1"
  if [ -z "$name" ]; then
    echo "ERROR: context snapshot name required." >&2
    return 1
  fi
  if ! [[ "$name" =~ $SESSION_SCHEDULER_CANONICAL_NAME_REGEX ]]; then
    echo "ERROR: Invalid context name '$name' — context snapshot names must be canonical snake_case: lowercase letters/digits separated by single underscores (regex: $SESSION_SCHEDULER_CANONICAL_NAME_REGEX)." >&2
    echo "  No hyphens, uppercase, leading/trailing underscores, or repeated underscores." >&2
    return 1
  fi
}

# Generate the entropy-only nonce used in automatic context filenames. Never
# derive context names from task ids, clocks, or formatted dates: knowledge
# treats filenames as opaque canonical names and keeps dates in metadata.
generate_context_nonce() {
  local nonce=""
  if command -v od >/dev/null 2>&1 && [ -r /dev/urandom ]; then
    nonce=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  fi
  if ! [[ "$nonce" =~ ^[0-9a-f]{32}$ ]] && command -v openssl >/dev/null 2>&1; then
    nonce=$(openssl rand -hex 16 2>/dev/null)
  fi
  if [[ "$nonce" =~ ^[0-9a-f]{32}$ ]]; then
    printf '%s\n' "$nonce"
    return 0
  fi
  echo "ERROR: Could not obtain 16 bytes of OS randomness for an auto context." >&2
  return 1
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

# Compact environment and transport rules for assignment and review packets.
packet_contract_block() {
  cat <<EOF
Shared scheduler home (provenance): $1
Environment contract (the path above is provenance, not a command):
- Use only the values your process inherited at launch. If they are absent or
  differ, stop and ask for a relaunch; never derive another ledger.
- Run each scheduler helper as ONE literal Bash segment:
  bash "<installed session-scheduler plugin root>/scripts/<helper>.sh" ...
  No export, env or variable prefixes, chaining, pipes, redirection, or
  command/process substitution.

Transport contract:
- Helpers update the ledger first, then notify through session-chat/tmux.
- In a sandbox, request scoped approval for the exact helper
  on the first attempt; never work around it (bash -c, wrappers, env,
  exports, broad provider-home access). Approval grants transport only; role, recipient,
  argument, confirmation and lifecycle rules still apply.
- If notification fails after a transition, check task-status first:
  never rerun task-done or task-block on a done/blocked task, and never
  use --force to repair a notification. Report the partial success; send a
  separate session-chat message only when authorized.
- task-review may retry dispatch only while the task is in review with no
  recorded successful reviewer dispatch; never duplicate a delivered packet.
EOF
}

# Deliver a lifecycle acknowledgement to the task assigner. The durable
# dispatch file is authoritative transport; the legacy one-line send is kept
# only as a fallback when the file cannot be written or dispatched.
#
# Results are returned in SESSION_CHAT_ACK_STATUS and SESSION_CHAT_ACK_FILE so
# callers can record the best-effort outcome after their transition is durable.
# shellcheck disable=SC2034  # the globals are read by the sourcing task-* scripts
session_chat_ack() {
  local target="$1" id="$2" event="$3" first_line="$4"
  local ack_file chat_root dispatch_rc dispatch_out

  SESSION_CHAT_ACK_STATUS="failed"
  SESSION_CHAT_ACK_FILE=""
  SESSION_CHAT_ACK_OBSERVED=""

  case "$event" in
    done|blocked|review) ;;
    *) return 1 ;;
  esac

  ack_file="$PROMPTS_DIR/${id}-ack-${event}.md"
  if {
    printf '%s\n\n' "$first_line"
    printf 'Ack only: the ledger is updated; no dispatch action needed. Check status:\n'
    printf '  Claude: /session-scheduler:task-status %s\n' "$id"
    printf '  Codex:  $session-scheduler:task-status %s\n' "$id"
  } > "$ack_file"; then
    chmod 600 "$ack_file" 2>/dev/null || true
    SESSION_CHAT_ACK_FILE="$ack_file"
  fi

  chat_root=$(session_chat_root 2>/dev/null || true)
  if [ -n "$SESSION_CHAT_ACK_FILE" ] && [ -n "$chat_root" ]; then
    dispatch_out=$(bash "$chat_root/scripts/dispatch-to-session.sh" "$target" "$SESSION_CHAT_ACK_FILE" 2>/dev/null)
    dispatch_rc=$?
    SESSION_CHAT_ACK_OBSERVED="failed"
    if [ "$dispatch_rc" -eq 0 ] || [ "$dispatch_rc" -eq 3 ]; then
      SESSION_CHAT_ACK_STATUS="dispatched"
      SESSION_CHAT_ACK_OBSERVED="delivered"
      if [ "$dispatch_rc" = 3 ] || printf '%s\n' "$dispatch_out" | grep -q '^Queued dispatch to '; then
        SESSION_CHAT_ACK_OBSERVED="queued"
      fi
      return 0
    fi
  fi

  if [ -n "$chat_root" ]; then SESSION_CHAT_ACK_OBSERVED="failed"; fi
  if [ -n "$chat_root" ] \
    && bash "$chat_root/scripts/send-message.sh" "$target" "$first_line" >/dev/null 2>&1; then
    SESSION_CHAT_ACK_STATUS="inline-fallback"
    SESSION_CHAT_ACK_OBSERVED="inline-fallback"
    echo "WARN: durable ack dispatch to '$target' failed; ack delivered inline instead." >&2
    return 0
  fi

  return 1
}

record_last_ack() {
  local file="$1" event="$2" target="$3" status="$4" ack_file="$5"
  local now
  now=$(now_iso) || return 1
  task_jq_update "$file" \
    --arg event "$event" \
    --arg target "$target" \
    --arg status "$status" \
    --arg now "$now" \
    --arg ack_file "$ack_file" \
    '(.meta //= {})
     | .meta.last_ack = {
         event:$event,
         target:$target,
         status:$status,
         at:$now,
         file:(if $ack_file == "" then null else $ack_file end)
       }'
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
  # The caller holds the task lock across creation or read-modify-write.
  local file="$1" mode="${2:-}"
  local tmp
  SCHED_WRITE_UNCERTAIN=0
  tmp=$(mktemp "${file}.tmp.XXXXXX") || { _sched_diag_note sched.ledger.write_failed; return 1; }
  cat > "$tmp" || {
    rm -f "$tmp"
    _sched_diag_note sched.ledger.write_failed
    return 1
  }
  if ! jq -s -e 'length == 1 and (.[0] | type == "object")' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    echo "ERROR: refusing invalid task JSON: $file" >&2
    _sched_diag_note sched.ledger.write_refused
    return 1
  fi
  if [ "$mode" = "create" ] && { [ -e "$file" ] || [ -L "$file" ]; }; then
    rm -f "$tmp"
    echo "ERROR: task ID collision: $file already exists; it was left unchanged." >&2
    return 1
  fi
  if ! mv "$tmp" "$file"; then
    if [ -e "$tmp" ]; then rm -f "$tmp"; else SCHED_WRITE_UNCERTAIN=1; fi
    _sched_diag_note sched.ledger.write_failed
    return 1
  fi
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
      if [ "$dstatus" = "done" ] && jq -e 'has("contract")' "$dfile" >/dev/null; then
        bash "$(dirname "${BASH_SOURCE[0]}")/task-contract.sh" inspect "$dep" >/dev/null || dstatus=closed-unadmitted
      fi
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
  if jq -e 'has("contract")' "$file" >/dev/null; then
    local contract_state_value
    contract_state_value=$(contract_state "$(basename "$file" .json)") || true
    flags="CONTRACT:${contract_state_value:-invalid}"
  fi
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
          flags="${flags:+$flags,}OVERDUE"
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

# --- Verdict events (Tier 1.2b-min) ---
# A reviewer verdict given as --note-file is ONE event, recorded in
# meta.verdict_events[<event id>] by the same atomic ledger write as the
# semantic transition (done|blocked). The verdict body lives in an exclusive
# artifact prompts/<id>-verdict-<event id>.md bound by SHA-256. Notification
# bookkeeping lives on the event (notification.state), never in history.
# Scope: only the --note-file forms create events; inline notes keep the
# lifecycle ack path (meta.last_ack) unchanged.

# jq fragment appended to the status-flip filter. $ve is null (no event) or
# {event_id, artifact, sha}. route_to, request id and generation are read from
# the current task JSON inside the lock, never from caller-side snapshots.
# shellcheck disable=SC2016  # jq program text, not shell
VERDICT_EVENT_FILTER='(if $ve == null then . else
     (.assigner // "") as $a
     | ((.meta | objects | .review_request_msg_id) // null) as $r
     | (if $a == "" or $a == "?" then null else $a end) as $route
     | .meta = ((.meta | if type == "object" then . else {} end)
         | .verdict_events = ((.verdict_events // {}) + {($ve.event_id): {
             schema: 1,
             event_id: $ve.event_id,
             transition: $status,
             actor: $actor,
             route_to: $route,
             request_msg_id: (if ($r | type) == "string" and ($r | test("^[a-f0-9]{8,16}$")) then $r else null end),
             generation: ((.contract.generation // null)),
             artifact: $ve.artifact,
             artifact_sha256: $ve.sha,
             created_at: $ts,
             notification: (if $route != null and $route != $actor then {state: "pending"} else {state: "not-required"} end)
           }}))
   end)'

# Upper bound for a --note-file verdict body (env-only tunable, read per call).
verdict_note_max_bytes() {
  local v="${SESSION_SCHEDULER_NOTE_MAX_BYTES:-65536}"
  [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 1 ] || v=65536
  printf '%s\n' "$v"
}

# 16 random hex chars from /dev/urandom via od and nothing else; prints nothing
# and returns non-zero on any failure (same fail-closed style as generate_task_id).
generate_verdict_event_id() {
  local hex
  command -v od >/dev/null 2>&1 || return 1
  hex=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null) || return 1
  hex=$(printf '%s' "$hex" | tr -d ' \n')
  [[ "$hex" =~ ^[a-f0-9]{16}$ ]] || return 1
  printf '%s' "$hex"
}

verdict_artifact_path() { prompt_file "${1}-verdict-${2}"; }
verdict_notice_path() { prompt_file "${1}-verdict-${2}-notice"; }

# Exact artifact names a task owns, from its recorded events (read before the
# task file is removed). One path per line: the verdict and its notice.
task_verdict_artifacts() {
  local id="$1" ve
  [ -f "$(task_file "$id")" ] || return 0
  while IFS= read -r ve; do
    [[ "$ve" =~ ^[a-f0-9]{16}$ ]] || continue
    verdict_artifact_path "$id" "$ve"
    verdict_notice_path "$id" "$ve"
  done < <(jq -r '((.meta | objects | .verdict_events) // {}) | keys[]' "$(task_file "$id")" 2>/dev/null)
}

# verdict_note_prepare <task-id> <note-file> [<inline-summary>]
# Validates the note file BEFORE any transition and copies it to the exclusive
# artifact. Sets VERDICT_EVENT, VERDICT_ARTIFACT, VERDICT_SHA, VERDICT_NOTE
# (the bounded history note), VERDICT_IDENT and VERDICT_SRC. On any refusal it
# prints a reason, leaves no artifact, and returns 1.
# shellcheck disable=SC2034  # VERDICT_* are read by the sourcing task-* scripts
verdict_note_prepare() {
  local id="$1" file="$2" summary="${3:-}"
  local root helper out rc tag ident sum size max pout prc event artifact
  VERDICT_EVENT=""; VERDICT_ARTIFACT=""; VERDICT_SHA=""; VERDICT_NOTE=""; VERDICT_IDENT=""; VERDICT_SRC="$file"
  # Diagnostics: every refusal below notes ONE typed code (direct call, this
  # function never runs inside $(...)). The checker is a subprocess: its status
  # and output are mapped here, never its text. For a contracted task this
  # preflight is the contract route; the helper emits nothing for it.
  if [ -z "$file" ]; then
    echo "ERROR: --note-file requires a path." >&2
    _sched_diag_note sched.note_file.option_malformed
    return 1
  fi
  if ! root=$(session_chat_root); then
    echo "ERROR: --note-file needs session-chat (own-draft-check.sh); no session-chat install was found. Nothing was read or changed." >&2
    _sched_diag_note sched.note_file.checker_unavailable
    return 1
  fi
  helper="$root/scripts/own-draft-check.sh"
  if [ ! -f "$helper" ]; then
    echo "ERROR: --note-file needs a newer session-chat: the installed copy has no scripts/own-draft-check.sh (the own-draft read check)." >&2
    echo "  Update session-chat, or give the verdict inline. The note file was not read and the task was not changed." >&2
    _sched_diag_note sched.note_file.checker_unavailable
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: --note-file needs python3 and verdict-file.py to validate raw bytes; nothing was read or changed." >&2
    _sched_diag_note sched.note_file.python_missing
    return 1
  fi
  if [ ! -f "$SCHEDULER_SCRIPTS_DIR/verdict-file.py" ]; then
    echo "ERROR: --note-file needs python3 and verdict-file.py to validate raw bytes; nothing was read or changed." >&2
    _sched_diag_note sched.note_file.validator_missing
    return 1
  fi
  max=$(verdict_note_max_bytes)
  # The limit goes to the checker so an oversize draft is refused on its size
  # alone, before any content is read or hashed (exit 3).
  out=$(bash "$helper" --max-bytes "$max" "$file"); rc=$?
  if [ "$rc" = "3" ]; then
    echo "ERROR: --note-file refused: the draft is larger than the limit of $max bytes (SESSION_SCHEDULER_NOTE_MAX_BYTES). It was not hashed or copied, and the task was not changed." >&2
    _sched_diag_note sched.note_file.too_large
    return 1
  fi
  if [ "$rc" = "4" ]; then
    echo "ERROR: --note-file refused: the draft changed while it was being checked. It was read but not copied, and the task was not changed." >&2
    _sched_diag_note sched.note_file.changed_during_check
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    # Any other nonzero status (1, 2, 127, a signal, ...) is an unclassified
    # checker failure. The status is never read as proof of "not an own draft".
    echo "ERROR: --note-file refused: '$file' is not an eligible own draft of this pane (the check exited $rc). The task was not changed." >&2
    _sched_diag_note sched.note_file.check_failed
    return 1
  fi
  # Strict parse: exactly one line OK<TAB>dev:inode<TAB>sha256<TAB>size.
  if [[ "$out" == *$'\n'* ]]; then
    echo "ERROR: --note-file refused: the draft check printed more than one line." >&2
    _sched_diag_note sched.note_file.check_malformed
    return 1
  fi
  local IFS=$'\t' extra=""
  read -r tag ident sum size extra <<< "$out"
  IFS=$' \t\n'
  if [ "$tag" != "OK" ] || [ -n "$extra" ] || ! [[ "$ident" =~ ^[0-9]+:[0-9]+$ ]] \
     || ! [[ "$sum" =~ ^[a-f0-9]{64}$ ]] || ! [[ "$size" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --note-file refused: the draft check returned malformed output." >&2
    _sched_diag_note sched.note_file.check_malformed
    return 1
  fi
  if [ "$size" -gt "$max" ]; then
    echo "ERROR: --note-file refused: the file is $size bytes; the limit is $max (SESSION_SCHEDULER_NOTE_MAX_BYTES)." >&2
    _sched_diag_note sched.note_file.too_large
    return 1
  fi
  if ! event=$(generate_verdict_event_id); then
    echo "ERROR: could not generate a verdict event id (no usable /dev/urandom via od); the draft was checked but not copied, and the task was not changed." >&2
    _sched_diag_note sched.note_file.event_id_failed
    return 1
  fi
  artifact=$(verdict_artifact_path "$id" "$event")
  pout=$(python3 -I "$SCHEDULER_SCRIPTS_DIR/verdict-file.py" prepare --src "$file" --ident "$ident" \
    --sha "$sum" --size "$size" --max-bytes "$max" --dest "$artifact" --summary="$summary"); prc=$?
  if [ "$prc" -ne 0 ]; then
    echo "  --note-file refused; the task was not changed." >&2
    _sched_diag_note sched.note_file.prepare_failed
    return 1
  fi
  VERDICT_NOTE=$(printf '%s' "$pout" | jq -r 'select(.sha256 == "'"$sum"'") | .note') || VERDICT_NOTE=""
  if [ -z "$VERDICT_NOTE" ] || [ ! -f "$artifact" ]; then
    rm -f "$artifact" 2>/dev/null
    echo "ERROR: --note-file refused: could not verify the verdict artifact; the task was not changed." >&2
    _sched_diag_note sched.note_file.prepare_failed
    return 1
  fi
  VERDICT_EVENT="$event"; VERDICT_ARTIFACT="$artifact"; VERDICT_SHA="$sum"; VERDICT_IDENT="$ident"
  return 0
}

# verdict_split_args <args after the task id...>
# Recognises --note-file <path> only as a LEADING option (before the note
# words, alongside --force / --generation N), so a note that merely mentions
# the flag is never reinterpreted. Sets NOTE_FILE_SET (0|1), NOTE_FILE, LEAD_ARGS
# (the other leading options, in order) and NOTE_WORDS (everything after them).
# Returns 1 with a message on a malformed --note-file.
# shellcheck disable=SC2034  # read by the sourcing task-done/task-block scripts
verdict_split_args() {
  NOTE_FILE=""; NOTE_FILE_SET=0; LEAD_ARGS=(); NOTE_WORDS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --note-file)
        if [ "$NOTE_FILE_SET" = 1 ] || [ $# -lt 2 ] || [ -z "$2" ]; then
          echo "ERROR: --note-file takes exactly one path and may be given once." >&2
          _sched_diag_note sched.note_file.option_malformed
          return 1
        fi
        NOTE_FILE="$2"; NOTE_FILE_SET=1; shift 2 ;;
      --force) LEAD_ARGS+=("$1"); shift ;;
      --generation)
        [ $# -ge 2 ] || break
        LEAD_ARGS+=("$1" "$2"); shift 2 ;;
      *) break ;;
    esac
  done
  NOTE_WORDS=("$@")
  return 0
}

# --generation belongs to the contracted form only. With --note-file on an
# uncontracted task it is refused here (never taken as note text).
# shellcheck disable=SC2034  # returned to task-done/task-block
verdict_refuse_generation_without_contract() {
  local a seen=0
  SCHED_DIAG_GENERATION=""
  for a in ${LEAD_ARGS[@]+"${LEAD_ARGS[@]}"}; do
    if [ "$seen" = 1 ]; then
      SCHED_DIAG_GENERATION="$a"
      break
    fi
    if [ "$a" = "--generation" ]; then
      echo "ERROR: --generation applies only to a task with a verification contract; task $1 has none. Use: $1 --note-file <own draft>. Nothing was read or changed." >&2
      _sched_diag_note sched.argv.generation_without_contract
      seen=1
    fi
  done
  [ "$seen" = 1 ] && return 1
  return 0
}

# verdict_contract_route <done|block> <task-id>  (uses the verdict_split_args globals)
# --note-file on a contracted task: validate and copy the draft first, then hand
# the transition to the engine with the event id and digest. Never returns.
verdict_contract_route() {
  local op="$1" id="$2" gen="" summary="" rc out
  if [ "${#LEAD_ARGS[@]}" -ne 2 ] || [ "${LEAD_ARGS[0]}" != "--generation" ] || ! [[ "${LEAD_ARGS[1]}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: a contracted task takes: $id --generation <N> --note-file <draft> (no --force)." >&2
    exit 2
  fi
  gen="${LEAD_ARGS[1]}"
  summary="${NOTE_WORDS[*]+"${NOTE_WORDS[*]}"}"
  if [ ! -f "$SCHEDULER_SCRIPTS_DIR/task-contract.sh" ]; then
    echo "ERROR: task $id has a verification contract but task-contract.sh is not installed; refusing the legacy $op path." >&2
    exit 2
  fi
  verdict_note_prepare "$id" "$NOTE_FILE" "$summary" || exit 1
  out=$(bash "$SCHEDULER_SCRIPTS_DIR/task-contract.sh" route "$op" "$id" --generation "$gen" "$VERDICT_NOTE" \
    --verdict-event "$VERDICT_EVENT" --verdict-sha "$VERDICT_SHA"); rc=$?
  [ -n "$out" ] && printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then
    verdict_discard_unreferenced "$id" "$VERDICT_EVENT"
    exit "$rc"
  fi
  verdict_consume_draft "$NOTE_FILE" "$VERDICT_IDENT" "$VERDICT_SHA"
  exit 0
}

# Compact JSON for append_history_update's optional 6th argument.
verdict_event_arg() {
  jq -cn --arg e "$VERDICT_EVENT" --arg a "$VERDICT_ARTIFACT" --arg s "$VERDICT_SHA" '{event_id: $e, artifact: $a, sha: $s}'
}

# Remove the artifact of a transition that did not commit. Kept whenever the
# ledger records the event (or cannot be read): an unreferenced artifact is the
# only kind that is safe to delete.
verdict_discard_unreferenced() {
  local id="$1" ve="$2" artifact
  [ -n "$ve" ] || return 0
  artifact=$(verdict_artifact_path "$id" "$ve")
  if jq -e --arg ve "$ve" '((.meta | objects | .verdict_events) // {}) | has($ve) | not' "$(task_file "$id")" >/dev/null 2>&1; then
    rm -f "$artifact" 2>/dev/null
  fi
  return 0
}

# verdict_notify <task-id> <event-id>
# ONE notification to the recorded route. Prints exactly one outcome word on
# stdout: delivered | queued | inline-fallback | failed. Everything else goes
# to stderr. A queued dispatch is a durable success and is never resent; the
# bounded inline fallback runs only after a HARD dispatch failure and can in
# rare cases duplicate a pointer. Never writes the ledger.
verdict_notify() {
  local id="$1" ve="$2" ev to artifact sha line notice dc dout limit pointer footer vf sent attempted=no
  _vn_out() { [ "${_SCHED_NOTIFY_TYPED:-0}" = 1 ] && echo "attempt:$attempted"; echo "$1"; }
  vf="$SCHEDULER_SCRIPTS_DIR/verdict-file.py"
  ev=$(jq -c --arg ve "$ve" '((.meta | objects | .verdict_events) // {})[$ve] // empty' "$(task_file "$id")" 2>/dev/null)
  to=$(printf '%s' "$ev" | jq -r '.route_to // empty' 2>/dev/null)
  artifact=$(printf '%s' "$ev" | jq -r '.artifact // empty' 2>/dev/null)
  sha=$(printf '%s' "$ev" | jq -r '.artifact_sha256 // empty' 2>/dev/null)
  if [ -z "$to" ] || ! validate_route_name "verdict route" "$to" 2>/dev/null \
     || [ "$artifact" != "$(verdict_artifact_path "$id" "$ve")" ] || ! [[ "$sha" =~ ^[a-f0-9]{64}$ ]]; then
    echo "WARN: verdict event $ve has no usable route or artifact record; no notification was sent." >&2
    _vn_out failed; return 0
  fi
  if ! line=$(python3 -I "$vf" excerpt --path "$artifact" --sha "$sha"); then
    echo "WARN: verdict artifact $artifact failed verification; no notification was sent." >&2
    _vn_out failed; return 0
  fi
  notice=$(verdict_notice_path "$id" "$ve")
  footer="Ack only: the ledger is updated; no dispatch action needed. Check status:
  Claude: /session-scheduler:task-status ${id}
  Codex:  \$session-scheduler:task-status ${id}"
  # Exclusive create (O_EXCL via noclobber): an existing file, symlink or
  # directory at this path is refused and left untouched. Only a file this call
  # created is ever removed.
  if ! ( set -o noclobber; : > "$notice" ) 2>/dev/null; then
    echo "WARN: the verdict notice path already exists and was left untouched ($notice); no notification was sent." >&2
    _vn_out failed; return 0
  fi
  if ! ( printf '[task:%s] [event:%s] %s\n\n' "$id" "$ve" "$line"
         python3 -I "$vf" show --path "$artifact" --sha "$sha" || exit 1
         printf '\n\n%s\n' "$footer"
       ) > "$notice" 2>/dev/null; then
    rm -f "$notice" 2>/dev/null
    echo "WARN: could not compose the verdict notification; no notification was sent." >&2
    _vn_out failed; return 0
  fi
  chmod 600 "$notice" 2>/dev/null || true
  dout=$(session_chat_dispatch "$to" "$notice"); dc=$?
  if [ "$dc" = "$SESSION_CHAT_DISPATCH_NOT_INVOKED" ]; then dc=1; else attempted=yes; fi
  if [ "$dc" = "3" ] || { [ "$dc" = "0" ] && printf '%s\n' "$dout" | grep -q '^Queued dispatch to '; }; then
    _vn_out queued; return 0
  fi
  if [ "$dc" = "0" ]; then
    _vn_out delivered; return 0
  fi
  # Hard dispatch failure only: bounded inline pointer to the recorded verdict.
  limit="${SESSION_CHAT_SEND_MAX_LEN:-1024}"
  [[ "$limit" =~ ^[0-9]+$ ]] && [ "$limit" -ge 1 ] || limit=1024
  if pointer=$(python3 -I "$vf" pointer --task "$id" --event "$ve" --line "$line" --max-bytes "$limit"); then
    # session_chat_send reports through SESSION_CHAT_SEND_ATTEMPTED (a direct call here)
    # whether it reached the send script; no discovery is repeated.
    session_chat_send "$to" "$pointer"; sent=$?
    [ "${SESSION_CHAT_SEND_ATTEMPTED:-0}" = 1 ] && attempted=yes
    if [ "$sent" = 0 ]; then
      echo "WARN: durable verdict dispatch to '$to' failed; a bounded pointer was sent inline (a duplicate pointer is possible)." >&2
      _vn_out inline-fallback; return 0
    fi
  fi
  _vn_out failed; return 0
}

# shellcheck disable=SC2034  # returned to task-done/task-block
verdict_notify_typed() {
  local raw
  raw=$(_SCHED_NOTIFY_TYPED=1 verdict_notify "$1" "$2")
  VERDICT_OUTCOME="${raw##*$'\n'}"
  VERDICT_ATTEMPT=no
  case "$raw" in "attempt:yes"*) VERDICT_ATTEMPT=yes ;; esac
}

# verdict_record_outcome <task-id> <event-id> <state>
# Re-takes the task lock and records the notification outcome ON THAT EVENT
# only (no history entry, no status change). A missing event is left missing.
verdict_record_outcome() {
  local id="$1" ve="$2" state="$3"
  task_jq_update "$(task_file "$id")" \
    'if ((.meta | objects | .verdict_events) // {}) | has($ve)
     then .meta.verdict_events[$ve].notification = {state: $s, at: $t}
     else . end' \
    --arg ve "$ve" --arg s "$state" --arg t "$(now_iso)"
}

# verdict_consume_draft <file> <dev:inode> <sha256>
# After the event is committed, ask session-chat (subprocess) to remove the
# reviewer's draft if it is still the same eligible own draft. A kept or
# failed cleanup never undoes the verdict.
verdict_consume_draft() {
  local file="$1" ident="$2" sum="$3" root helper
  if ! root=$(session_chat_root) || [ ! -f "$root/scripts/own-draft-check.sh" ]; then
    echo "NOTE: kept draft (session-chat cleanup helper unavailable): $file"
    return 0
  fi
  helper="$root/scripts/own-draft-check.sh"
  bash "$helper" --consume "$file" "$ident" "$sum" || echo "NOTE: kept draft (cleanup helper failed): $file"
  return 0
}

# Transport wrappers keep the provider-specific root/version resolution.
SESSION_CHAT_DISPATCH_NOT_INVOKED=125
session_chat_dispatch() {
  local root
  root=$(session_chat_root) || return "$SESSION_CHAT_DISPATCH_NOT_INVOKED"
  bash "$root/scripts/dispatch-to-session.sh" "$1" "$2"
}

session_chat_send() {
  local root
  SESSION_CHAT_SEND_ATTEMPTED=0
  root=$(session_chat_root) || return 1
  SESSION_CHAT_SEND_ATTEMPTED=1
  bash "$root/scripts/send-message.sh" "$1" "$2" >/dev/null 2>&1
}

# Update status + history. Enforces legal transitions unless
# SESSION_SCHEDULER_FORCE=1 (then the history note records "forced").
# Sets started_at the first time status becomes assigned.
_append_history_update() {
  local file="$1"
  local status="$2"
  local event="$3"
  local actor="$4"
  local note="$5"
  local verdict_json="${6:-null}"
  lock_task_for_command "$(basename "$file" .json)" || exit 1
  if jq -e 'has("contract")' "$file" >/dev/null; then
    echo "ERROR: task has a verification contract; use task-contract.sh" >&2
    _sched_diag_note sched.contract.legacy_write_refused
    return 1
  fi
  local current
  current=$(jq -r '.status // ""' "$file" 2>/dev/null)
  if ! transition_allowed "$current" "$status"; then
    if scheduler_force_enabled; then
      note="${note:+$note }(forced)"
    else
      echo "ERROR: Illegal status transition '$current' -> '$status'." >&2
      echo "Current status: $current; legal next: $(legal_targets "$current")" >&2
      echo "Override with --force or SESSION_SCHEDULER_FORCE=1." >&2
      _sched_diag_note sched.transition.illegal
      return 1
    fi
  fi
  local now
  now=$(now_iso)
  local updated
  updated=$(jq \
    --arg status "$status" \
    --arg now "$now" \
    --arg event "$event" \
    --arg actor "$actor" \
    --arg note "$note" \
    --arg ts "$now" \
    --argjson ve "$verdict_json" \
    '.status=$status
     | .updated_at=$now
     | (if $status == "assigned" and ((.started_at // null) == null)
        then .started_at=$now else . end)
     | .history += [{ts:$now,event:$event,actor:$actor,note:$note}]
     | '"$VERDICT_EVENT_FILTER" \
    "$file") || { _sched_diag_note sched.ledger.write_failed; return 1; }
  write_json_atomic "$file" <<< "$updated"
}

append_history_update() {
  if [ -n "$_SCHED_DIAG_HELPER" ]; then
    _sched_diag_collect _append_history_update "$@"
  else
    ( _append_history_update "$@" )
  fi
}

file_mtime() {
  local file="$1"
  stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null
}

# Contract admissions are required independently of legacy --force.
contract_dependencies() {
  local file dep dfile
  file=$(task_file "$1") || return 1
  [ -f "$file" ] || return 1
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    dfile=$(task_file "$dep" 2>/dev/null) || continue
    if [ -f "$dfile" ] && jq -e 'has("contract")' "$dfile" >/dev/null; then
      if ! contract_state "$dep" >/dev/null; then
        echo "ERROR: dependency $dep lacks current contract admission" >&2
        return 1
      fi
    fi
  done < <(jq -r '(.depends_on // [])[]' "$file")
}

SCHEDULER_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

task_has_contract() {
  local file
  file=$(task_file "$1" 2>/dev/null) || return 1
  [ -f "$file" ] && jq -e 'type == "object" and has("contract")' "$file" >/dev/null 2>&1
}

# Usage: contract_route_if_needed <assign|review|done|block> <id> <original args...>
# Returns only when the task is not contracted (or the id is unusable, which
# the caller's own validation then reports). Otherwise it never returns.
contract_route_if_needed() {
  local op="$1" id="$2"
  shift 2
  validate_task_id "$id" >/dev/null 2>&1 || return 0
  task_has_contract "$id" || return 0
  if [ ! -f "$SCHEDULER_SCRIPTS_DIR/task-contract.sh" ]; then
    echo "ERROR: task $id has a verification contract but task-contract.sh is not installed; refusing the legacy $op path." >&2
    exit 2
  fi
  exec bash "$SCHEDULER_SCRIPTS_DIR/task-contract.sh" route "$op" "$@"
}

# Under-lock guard for legacy writers. Usage: contract_legacy_guard <id> <current-json>
contract_legacy_guard() {
  if printf '%s' "$2" | jq -e 'type == "object" and has("contract")' >/dev/null 2>&1; then
    echo "ERROR: task $1 has a verification contract; use task-contract.sh" >&2
    return 1
  fi
  return 0
}

# Admission state of a contracted task. Prints admitted|closed-unadmitted|
# active|invalid and returns the engine's exit code (0 admitted, 1 not
# admitted, 2 invalid/unavailable). A missing engine is invalid, never admitted.
contract_state() {
  local id="$1" out rc state
  if [ ! -f "$SCHEDULER_SCRIPTS_DIR/task-contract.sh" ]; then
    echo "invalid"; return 2
  fi
  out=$(bash "$SCHEDULER_SCRIPTS_DIR/task-contract.sh" inspect "$id" 2>/dev/null); rc=$?
  state=$(printf '%s' "$out" | jq -r 'if type == "object" then (.state // "invalid") else "invalid" end' 2>/dev/null)
  case "$rc:$state" in
    0:admitted) echo "admitted"; return 0 ;;
    1:closed-unadmitted|1:active) echo "$state"; return 1 ;;
    *) echo "invalid"; return 2 ;;
  esac
}
