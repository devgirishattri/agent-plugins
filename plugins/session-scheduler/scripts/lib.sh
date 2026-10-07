#!/usr/bin/env bash
# lib.sh — shared helpers for session-scheduler plugin.
# Storage: $SESSION_SCHEDULER_HOME/{tasks,prompts}/...  (same env var as the
#   codex side, so claude and codex panes launched with the same value share a
#   ledger).
# One JSON file per task. Atomic writes (tmp + mv).
# Requires: jq, bash 3.2+ (macOS stock bash runs the suite green; nothing here
#   uses bash 4 syntax). Depends on session-chat lib.sh for /send.

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
  if command -v jq >/dev/null 2>&1; then
    _sched_diag_note sched.env.home_unset
    sched_diag_emit
  else
    _sched_diag_bootstrap sched.env.home_unset
  fi
  exit 1
fi

SCHEDULER_DIR="$SESSION_SCHEDULER_HOME"
TASKS_DIR="$SCHEDULER_DIR/tasks"
PROMPTS_DIR="$SCHEDULER_DIR/prompts"
# Auto handoffs (--context auto) are scheduler-owned artifacts, one per-task
# subdirectory: handoffs/<id>/<nonce>.md. They never touch the knowledge context
# store. tasks-clean sweeps them with the task.
HANDOFFS_DIR="$SCHEDULER_DIR/handoffs"
# Per-task mutation locks: locks/<id>.lock/ (mkdir-atomic, pid inside). Kept
# OUTSIDE the vetted tasks/ and prompts/ subtrees because ensure_dirs fails
# closed on entries that vanish mid-traversal — exactly what a transient lock
# directory does. Both providers use this identical path, so cross-provider
# exclusion on one ledger is real.
LOCKS_DIR="$SCHEDULER_DIR/locks"

# The ledger holds task JSON, executor prompts, review packets, and handoffs —
# all of which can carry sensitive task content — so keep everything owner-only.
# umask 077 makes new files 0600 / new dirs 0700 (process-local: the /task-*
# commands invoke these scripts as subprocesses, so it never tightens the user's
# shell). Nothing is 0400: handoffs are "never overwritten" by unique naming,
# not by file mode.
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
  agent_plugins_timezone >/dev/null || { _sched_diag_note sched.env.timezone_invalid; return 1; }
  # Never create or write THROUGH a symlink planted at the root/tasks/prompts.
  for d in "$SCHEDULER_DIR" "$TASKS_DIR" "$PROMPTS_DIR" "$HANDOFFS_DIR" "$LOCKS_DIR"; do
    if [ -L "$d" ]; then
      echo "ERROR: refusing to use scheduler path '$d' — it is a symlink." >&2
      _sched_diag_note sched.store.unsafe
      return 1
    fi
  done
  if ! mkdir -p "$TASKS_DIR" "$PROMPTS_DIR" "$HANDOFFS_DIR" "$LOCKS_DIR" 2>/dev/null; then
    echo "ERROR: could not create scheduler dirs under '$SCHEDULER_DIR'." >&2
    _sched_diag_note sched.store.unavailable
    return 1
  fi
  for d in "$SCHEDULER_DIR" "$TASKS_DIR" "$PROMPTS_DIR" "$HANDOFFS_DIR" "$LOCKS_DIR"; do
    if ! _sched_dir_is_safe "$d"; then
      echo "ERROR: scheduler path '$d' is unsafe (symlink, not a directory, or not owned by you)." >&2
      _sched_diag_note sched.store.unsafe
      return 1
    fi
    chmod 700 "$d" 2>/dev/null || { echo "ERROR: could not lock '$d' to 0700." >&2; _sched_diag_note sched.store.unavailable; return 1; }
  done
  # Vet + migrate every entry under tasks/, prompts/, and handoffs/ (locks/ is
  # deliberately NOT traversed: its entries are transient). NUL-safe traversal with
  # an OBSERVED find status: a `< <(find ...)` process substitution hides a
  # traversal failure (e.g. an unreadable subdir) so the loop could vet a partial
  # tree and still succeed, and a pre-planted owner file MAY contain a newline in
  # its name. Capture `find -print0` to a temp file, check find's status, then
  # read NUL-delimited entries. Fail closed on any unsafe condition.
  local entry tmp_list find_rc
  tmp_list=$(mktemp 2>/dev/null) || { echo "ERROR: could not allocate a temp file for ledger traversal." >&2; _sched_diag_note sched.store.unavailable; return 1; }
  find "$TASKS_DIR" "$PROMPTS_DIR" "$HANDOFFS_DIR" -mindepth 1 -print0 > "$tmp_list" 2>/dev/null
  find_rc=$?
  if [ "$find_rc" -ne 0 ]; then
    rm -f "$tmp_list"
    echo "ERROR: could not fully traverse the ledger (find rc=$find_rc); refusing to operate on a partially-vetted tree." >&2
    _sched_diag_note sched.store.unavailable
    return 1
  fi
  while IFS= read -r -d '' entry; do
    [ -n "$entry" ] || continue
    if [ -L "$entry" ]; then
      rm -f "$tmp_list"; echo "ERROR: refusing to operate — nested symlink in ledger: '$entry'." >&2; _sched_diag_note sched.store.unsafe; return 1
    fi
    if [ ! -O "$entry" ]; then
      rm -f "$tmp_list"; echo "ERROR: refusing to operate — entry not owned by you: '$entry'." >&2; _sched_diag_note sched.store.unsafe; return 1
    fi
    if [ -d "$entry" ]; then
      chmod 700 "$entry" 2>/dev/null || { rm -f "$tmp_list"; echo "ERROR: could not lock dir '$entry' to 0700." >&2; _sched_diag_note sched.store.unavailable; return 1; }
    elif [ -f "$entry" ]; then
      chmod 600 "$entry" 2>/dev/null || { rm -f "$tmp_list"; echo "ERROR: could not lock file '$entry' to 0600." >&2; _sched_diag_note sched.store.unavailable; return 1; }
    else
      rm -f "$tmp_list"; echo "ERROR: refusing to operate — special (non dir/regular) file in ledger: '$entry'." >&2; _sched_diag_note sched.store.unsafe; return 1
    fi
  done < "$tmp_list"
  rm -f "$tmp_list"
  return 0
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not installed. Install with: brew install jq" >&2
    _sched_diag_bootstrap sched.env.jq_missing
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
# SESSION_CHAT_SEND_ATTEMPTED (typed, direct calls only) is 1 once the send script is
# about to run; it stays 0 when no session-chat install exists.
session_chat_send() {
  local target="$1"
  local message="$2"
  local root
  SESSION_CHAT_SEND_ATTEMPTED=0
  if ! root=$(session_chat_root); then
    echo "WARN: session-chat not installed; skipping ack to '$target'." >&2
    return 1
  fi
  SESSION_CHAT_SEND_ATTEMPTED=1
  if ! bash "$root/scripts/send-message.sh" "$target" "$message" >/dev/null 2>&1; then
    echo "WARN: session-chat /send to '$target' failed (recipient busy or absent)." >&2
    return 1
  fi
}

# session_chat_dispatch_ready: 0 when a dispatch can be attempted (a session-chat
# install at or above the durable-inbox floor), else 1 with the usual ERROR text. It is
# the typed answer to "was any transport attempted": a refusal here means the dispatch
# script was never run. Sets _SC_ROOT for session_chat_dispatch.
session_chat_dispatch_ready() {
  _SC_ROOT=""
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
  _SC_ROOT="$root"
  return 0
}

# session_chat_dispatch <target> <prompt-file>: the readiness check and, in the SAME call,
# the invocation of the dispatch script (the public helper protocol, used by task-assign).
# The install is resolved once. Typed result: return status 125 means "refused before any
# invocation" (no install, or below the durable-inbox floor); any other status comes from
# the invoked script. Callers inside a command substitution read the attempt from this
# status, never from an earlier or later check.
SESSION_CHAT_DISPATCH_NOT_INVOKED=125
session_chat_dispatch() {
  session_chat_dispatch_ready || return "$SESSION_CHAT_DISPATCH_NOT_INVOKED"
  bash "$_SC_ROOT/scripts/dispatch-to-session.sh" "$1" "$2"
}

# packet_contract_block <scheduler-home-abs>: the environment and transport
# rules every assignment and review packet carries. Kept compact because it is
# repeated in every packet; each rule here is load-bearing, so shorten wording,
# never drop a rule.
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

# session_chat_ack <target> <id> <event> <first-line>
# Durable delivery ladder for a lifecycle ack (done/blocked/review
# notification to the assigner): write an ack file -> durable dispatch (the
# same file-backed transport task-assign uses, queued to the recipient's
# inbox when busy) -> inline /send as a last-resort fallback. Every rung is
# best-effort — the caller's ledger transition has ALREADY landed by the time
# this runs, so this never aborts the caller and always returns 0. Outcome is
# reported via two globals (not local — the caller reads them right after
# the call) for recording on the ledger's meta.last_ack:
#   SESSION_CHAT_ACK_STATUS  dispatched | inline-fallback | failed
#   SESSION_CHAT_ACK_FILE    the written ack file, or empty when the file
#                             write itself failed (caller records JSON null)
# A third global is typed diagnostic input only (never recorded):
#   SESSION_CHAT_ACK_OBSERVED  delivered | queued | inline-fallback | failed,
#                             or empty when no transport was attempted (no
#                             session-chat install at all)
# shellcheck disable=SC2034  # these globals are read by the sourcing task-* scripts
session_chat_ack() {
  local target="$1" id="$2" event="$3" first_line="$4"
  local ack_file dc dack attempted=0
  SESSION_CHAT_ACK_STATUS="failed"
  SESSION_CHAT_ACK_FILE=""
  SESSION_CHAT_ACK_OBSERVED=""
  ack_file=$(prompt_path "${id}-ack-${event}")
  if cat > "$ack_file" <<EOF
${first_line}

Ack only: the ledger is updated; no dispatch action needed. Check status:
  Claude: /session-scheduler:task-status ${id}
  Codex:  \$session-scheduler:task-status ${id}
EOF
  then
    chmod 600 "$ack_file" 2>/dev/null || true
    SESSION_CHAT_ACK_FILE="$ack_file"
    # Same durable transport task-assign uses for the outbound leg; exit 0 =
    # delivered. Tolerate 3 (queued) defensively, though the current
    # dispatch-to-session.sh already normalizes a queued send to rc 0.
    dack=$(session_chat_dispatch "$target" "$ack_file" 2>/dev/null)
    dc=$?
    if [ "$dc" = "$SESSION_CHAT_DISPATCH_NOT_INVOKED" ]; then dc=1; else attempted=1; fi
    case "$dc" in
      0|3)
        SESSION_CHAT_ACK_STATUS="dispatched"
        if [ "$dc" = "3" ] || printf '%s\n' "$dack" | grep -q '^Queued dispatch to '; then
          SESSION_CHAT_ACK_OBSERVED="queued"
        else
          SESSION_CHAT_ACK_OBSERVED="delivered"
        fi
        return 0 ;;
    esac
  else
    rm -f "$ack_file" 2>/dev/null
  fi

  if session_chat_send "$target" "$first_line"; then
    SESSION_CHAT_ACK_STATUS="inline-fallback"
    SESSION_CHAT_ACK_OBSERVED="inline-fallback"
    echo "WARN: durable ack dispatch to '$target' failed; ack delivered inline instead." >&2
  elif [ "$attempted" = 1 ] || [ "${SESSION_CHAT_SEND_ATTEMPTED:-0}" = 1 ]; then
    # observed failed only when a transport script actually ran and failed
    SESSION_CHAT_ACK_OBSERVED="failed"
  fi
  return 0
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

# Generate a task id: task-<epoch>-<8 hex>, the hex from /dev/urandom via od
# and nothing else. There is deliberately no PID/RANDOM fallback: a guessable id
# is not acceptable for a ledger key. A missing od/urandom, a short read or
# malformed output prints NOTHING and returns non-zero, and task-new then fails
# closed. Ids from before this format (bare 8 hex) remain valid everywhere
# (validate_task_id only checks the charset).
generate_task_id() {
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

iso_now() {
  local raw timezone
  timezone=$(agent_plugins_timezone) || return 1
  raw=$(TZ="$timezone" date +%Y-%m-%dT%H:%M:%S%z) || return 1
  printf '%s:%s\n' "${raw%??}" "${raw#${raw%??}}"
}

epoch_now() {
  date +%s
}

# Convert an ISO-8601 timestamp (configured timezone for new records; UTC for legacy records)
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

task_path() {
  printf '%s/%s.json\n' "$TASKS_DIR" "$1"
}

prompt_path() {
  printf '%s/%s.md\n' "$PROMPTS_DIR" "$1"
}

# Per-task handoff directory: handoffs/<id>/ holds one <nonce>.md per
# assignment that used --context auto.
handoff_dir() {
  printf '%s/%s\n' "$HANDOFFS_DIR" "$1"
}

# Every derived artifact a task can own besides tasks/<id>.json, by EXACT name
# (never an <id>-* glob: ids may contain hyphens, so a glob for task "a" would
# also match task "a-b"'s files). tasks-clean removes exactly this set.
task_prompt_artifacts() {
  local id="$1" suffix
  prompt_path "$id"
  for suffix in review ack-done ack-blocked ack-review; do
    prompt_path "${id}-${suffix}"
  done
}

task_exists() {
  [ -f "$(task_path "$1")" ]
}

# --- Per-task mutation lock ---
# Ledger writes are atomic per file (tmp + mv), but a status transition is a
# read-modify-write: two actors updating the SAME task concurrently (an
# orchestrator reassigning while a reviewer marks done) could otherwise lose
# one update. mkdir is the atomic acquire; the holder pid lives inside so a
# lock abandoned by a dead process is reclaimed, while a live holder (kill -0
# succeeds, or fails with EPERM) is respected. Non-reentrant: a caller that
# already holds the lock must use the *_unlocked mutators.
task_lock_path() {
  printf '%s/%s.lock\n' "$LOCKS_DIR" "$1"
}

_sched_pid_alive() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  if kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  # EPERM => alive but not ours; ESRCH => dead. ps distinguishes them.
  ps -p "$pid" >/dev/null 2>&1
}

# Stale-lock takeover and release helpers. Bodies are IDENTICAL to the Codex
# scheduler lib (byte-for-byte), so both providers share one lock protocol on
# a shared ledger directory.
#
# _scheduler_reclaim_lock <lock-path> <expected-dead-pid> -> 0 only on a
# successful takeover. It is a subshell anchored with `cd -P` to the lock
# directory's real inode: the release path renames the whole directory away,
# so a waiter that is mid-reclaim keeps operating on the OLD generation (its
# marker, its pid file) and can never create, read, or remove anything in a
# NEW generation that appears at the same path. `$$` inside the subshell is
# still the caller's pid, so the recorded holder is correct.
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

# _scheduler_release_lock <lock-path>: ONE atomic rename of the whole lock
# directory into a private retirement directory, then deletion of that copy.
# The pid file stays in place until the rename, so no waiter ever observes
# the canonical path as a directory without a holder. The old two-step
# release (rm pid; rmdir) left exactly that window: a waiter's transient
# reclaim marker made the rmdir fail silently and stranded an ownerless lock
# that every later waiter waited on until timeout (CI run 35104849303,
# task_lock_serializes_and_reclaims).
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

task_lock() {
  local id="$1" lock deadline holder timeout
  lock=$(task_lock_path "$id")
  timeout="${SESSION_SCHEDULER_LOCK_TIMEOUT_SECS:-10}"
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=10
  deadline=$(( $(epoch_now) + timeout ))
  while :; do
    if mkdir "$lock" 2>/dev/null; then
      if ! printf '%s\n' "$$" > "$lock/pid" 2>/dev/null; then
        rmdir "$lock" 2>/dev/null
        echo "ERROR: could not record holder pid in $lock." >&2
        _sched_diag_note sched.lock.holder_unwritable
        return 1
      fi
      return 0
    fi
    if [ -L "$lock" ] || { [ -e "$lock" ] && { [ ! -d "$lock" ] || [ ! -O "$lock" ]; }; }; then
      # The holder may have released between the stat calls above; retry
      # rather than reporting a vanished lock as unsafe.
      [ ! -e "$lock" ] && [ ! -L "$lock" ] && continue
      echo "ERROR: unsafe task lock (symlink, not a directory, or not owned by you): $lock" >&2
      _sched_diag_note sched.lock.unsafe
      return 1
    fi
    holder=$(cat "$lock/pid" 2>/dev/null)
    if [[ "$holder" =~ ^[0-9]+$ ]] && ! _sched_pid_alive "$holder"; then
      # Stale reclaim (same protocol as the Codex side): take over in place
      # through _scheduler_reclaim_lock, which is anchored to the lock's inode
      # so a concurrent rename-release can never make it touch a newer lock.
      _scheduler_reclaim_lock "$lock" "$holder" && return 0
    fi
    if [ "$(epoch_now)" -ge "$deadline" ]; then
      echo "ERROR: could not lock task $id within ${timeout}s (held by pid ${holder:-unknown}; lock: $lock)." >&2
      [ -z "$holder" ] && echo "  The lock has no holder pid (interrupted acquire/reclaim); remove '$lock' by hand once no helper is running." >&2
      _sched_diag_note sched.lock.timeout
      return 1
    fi
    sleep 0.05
  done
}

# Release only a lock THIS process holds (pid file == $$), so a caller that
# timed out, or a stale-reclaim loser, can never release someone else's lock.
task_unlock() {
  local rc
  _scheduler_release_lock "$(task_lock_path "$1")"; rc=$?
  [ "$rc" -eq 0 ] || _sched_diag_note sched.lock.release_failed
  return "$rc"
}

# Read a task field via jq. Usage: task_get <id> <jq-expr>
task_get() {
  local id="$1"
  local expr="$2"
  jq -r "$expr" "$(task_path "$id")" 2>/dev/null
}

# Atomic write of JSON content to a task file (stage, then rename). Returns non-zero on any
# write/mv failure so callers can refuse to claim success on a corrupted
# ledger. A non-zero return after the rename step does NOT prove the rename did not
# happen (the mv process can fail after renaming): SCHED_WRITE_UNCERTAIN=1 marks that case
# and callers must then report "unconfirmed" instead of "not committed". The content must be exactly one JSON object: callers build it with
# `updated=$(... | jq ...)` under `set -uo pipefail` without errexit, so a
# failed jq leaves it empty or partial and must never replace the task file.
#
# With a third argument of "create" the task is created WITHOUT replacing:
# under the per-task lock (task_lock, the same mkdir lock every mutator uses,
# with its stale-holder recovery) the JSON is written and validated in a private
# 0600 staging file beside the target, the target name is checked to be absent in
# ANY form (file, symlink, directory, other), and only then is the staging file
# renamed over it (mv in the same directory: atomic, link count stays 1). The
# final path therefore never exists empty or partial, and a collision is refused
# with the existing entry untouched. The guarantee is no-replace among
# cooperating scheduler writers (they all take this lock); it is not a defence
# against an unrelated writer of the same UID that ignores the lock.
# Staging names are <tasks-dir>/<id>.json.tmp.<6 random chars>. A crash between
# staging and the rename can leave one behind; it is not a *.json ledger entry
# and nothing reads it. No sweep removes it: delete it by hand only after
# confirming no process holds the lock for that id (<locks-dir>/<id>.lock).
# Updates (no third argument) keep the tmp + mv replace.
task_write() {
  local id="$1"
  local json="$2"
  local mode="${3:-}"
  local target
  target=$(task_path "$id")
  if ! printf '%s' "$json" | jq -s -e 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1; then
    echo "ERROR: refusing to write non-object ledger content for $id; $target left unchanged." >&2
    _sched_diag_note sched.ledger.write_refused
    return 1
  fi
  if [ "$mode" = "create" ]; then
    local ctmp rc=1
    task_lock "$id" || return 1
    if ! ctmp=$(mktemp "${target}.tmp.XXXXXX" 2>/dev/null); then
      echo "ERROR: failed to stage new ledger file for $id beside $target" >&2
    elif ! printf '%s\n' "$json" > "$ctmp" \
         || ! jq -e 'type == "object"' "$ctmp" >/dev/null 2>&1; then
      rm -f "$ctmp" 2>/dev/null
      echo "ERROR: failed to write and validate the new ledger file for $id at $ctmp" >&2
    elif [ -e "$target" ] || [ -L "$target" ]; then
      rm -f "$ctmp" 2>/dev/null
      echo "ERROR: refusing to create task $id: $target already exists; it was left unchanged." >&2
    elif ! mv "$ctmp" "$target" 2>/dev/null; then
      rm -f "$ctmp" 2>/dev/null
      echo "ERROR: could not publish new ledger file for $id at $target." >&2
    else
      rc=0
    fi
    task_unlock "$id"
    return "$rc"
  fi
  local tmp="${target}.tmp.$$"
  SCHED_WRITE_UNCERTAIN=0
  if ! printf '%s\n' "$json" > "$tmp"; then
    rm -f "$tmp" 2>/dev/null
    echo "ERROR: failed to stage ledger write for $id at $tmp" >&2
    _sched_diag_note sched.ledger.write_failed
    return 1
  fi
  if ! mv "$tmp" "$target"; then
    # A failed mv proves "not published" only while the staged name still exists: the
    # publication is a rename, so a missing staged file means the rename may have
    # happened before the failure was reported. Then the result is unconfirmed.
    if [ -e "$tmp" ]; then
      rm -f "$tmp" 2>/dev/null
      echo "ERROR: failed to commit ledger write for $id at $target" >&2
    else
      SCHED_WRITE_UNCERTAIN=1
      echo "ERROR: the ledger write for $id at $target could not be confirmed (the staged file is gone; the rename may have happened)." >&2
    fi
    _sched_diag_note sched.ledger.write_failed
    return 1
  fi
  return 0
}

# Record the outcome of a lifecycle ack attempt (best-effort visibility only —
# the ledger transition itself already landed and must never be blocked or
# retried because of this). Usage:
#   task_record_last_ack <id> <event> <target> <status> <file>
# <file> may be empty — recorded as JSON null — when the ack file write
# itself failed.
#
# Always returns 0 (a transition that already landed is never undone). The
# typed result is SCHED_LAST_ACK_RECORD = ok | failed, read by the caller.
# shellcheck disable=SC2034  # SCHED_LAST_ACK_RECORD is read by the sourcing task-* scripts
task_record_last_ack() {
  local id="$1" event="$2" target="$3" status="$4" file="$5"
  local current updated
  SCHED_LAST_ACK_RECORD="failed"
  task_lock "$id" || return 0
  current=$(cat "$(task_path "$id")") || { task_unlock "$id"; return 0; }
  updated=$(printf '%s' "$current" | jq \
    --arg event "$event" \
    --arg target "$target" \
    --arg status "$status" \
    --arg ts "$(iso_now)" \
    --arg file "$file" \
    '.meta.last_ack = {
       event: $event,
       target: $target,
       status: $status,
       at: $ts,
       file: (if $file == "" then null else $file end)
     }') || { task_unlock "$id"; return 0; }
  task_write "$id" "$updated" && SCHED_LAST_ACK_RECORD="ok"
  task_unlock "$id"
  return 0
}

# --- Verification contracts (opt-in, 0.7.0) ---
# A task with a root `contract` object is owned by task-contract.sh. Legacy
# writers never mutate it: the early route hands the whole command to the
# engine, and the under-lock guard below refuses any legacy write that races an
# attach. Neither honors --force or SESSION_SCHEDULER_FORCE.
SCHEDULER_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

task_has_contract() {
  local file
  file=$(task_path "$1")
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
    _sched_diag_note sched.contract.legacy_write_refused
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

# Contracted dependencies of <id> that are not admitted, one "dep (state)" per
# line. Enforced even with --force: a contracted task's done status alone is
# closure, not acceptance.
unadmitted_contract_deps() {
  local id="$1" dep deps state
  deps=$(task_get "$id" '(.depends_on // [])[]')
  [ -z "$deps" ] && return 0
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    validate_task_id "$dep" >/dev/null 2>&1 || continue
    task_has_contract "$dep" || continue
    state=$(contract_state "$dep") && continue
    printf '%s (%s)\n' "$dep" "$state"
  done <<< "$deps"
}

# Locked generic read-modify-write. Usage: task_update <id> <jq-filter> [jq args...]
# Applies the filter to the current task JSON under the per-task lock and
# writes the result atomically. Returns non-zero on lock, jq, or write failure.
task_update() {
  local id="$1" filter="$2"
  shift 2
  local current updated rc
  task_lock "$id" || return 1
  current=$(cat "$(task_path "$id")") || { task_unlock "$id"; return 1; }
  contract_legacy_guard "$id" "$current" || { task_unlock "$id"; return 1; }
  updated=$(printf '%s' "$current" | jq "$@" "$filter") || { task_unlock "$id"; return 1; }
  task_write "$id" "$updated"; rc=$?
  task_unlock "$id"
  return $rc
}

# Append a history entry. Usage: task_append_history <id> <event> <actor> <note>
task_append_history() {
  local id="$1" event="$2" actor="$3" note="$4"
  task_update "$id" \
    '.updated_at = $ts
     | .history += [{ts: $ts, event: $event, actor: $actor, note: $note}]' \
    --arg ts "$(iso_now)" \
    --arg event "$event" \
    --arg actor "$actor" \
    --arg note "$note"
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

verdict_artifact_path() { prompt_path "${1}-verdict-${2}"; }
verdict_notice_path() { prompt_path "${1}-verdict-${2}-notice"; }

# Exact artifact names a task owns, from its recorded events (read before the
# task file is removed). One path per line: the verdict and its notice.
task_verdict_artifacts() {
  local id="$1" ve
  task_exists "$id" || return 0
  while IFS= read -r ve; do
    [[ "$ve" =~ ^[a-f0-9]{16}$ ]] || continue
    verdict_artifact_path "$id" "$ve"
    verdict_notice_path "$id" "$ve"
  done < <(jq -r '((.meta | objects | .verdict_events) // {}) | keys[]' "$(task_path "$id")" 2>/dev/null)
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
# SCHED_DIAG_GENERATION carries the offered number (diagnostic input only).
# shellcheck disable=SC2034  # read by the sourcing task-done/task-block scripts
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

# Compact JSON for task_set_status's optional 5th argument.
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
  if jq -e --arg ve "$ve" '((.meta | objects | .verdict_events) // {}) | has($ve) | not' "$(task_path "$id")" >/dev/null 2>&1; then
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
# Typed side channel (private; the outcome vocabulary is unchanged): when the caller sets
# _SCHED_NOTIFY_TYPED=1 for the call, a line "attempt:yes" or "attempt:no" precedes the
# outcome word. "yes" means a dispatch or send script was actually run; "no" means every
# step was refused before any transport (route/artifact/notice/compose preflight, or a
# session-chat install that was missing or below the durable-inbox floor). Other callers
# (the contract engine) leave it unset and see the single word as before.
verdict_notify() {
  local id="$1" ve="$2" ev to artifact sha line notice dc dout limit pointer footer vf sent attempted=no
  _vn_out() { [ "${_SCHED_NOTIFY_TYPED:-0}" = 1 ] && echo "attempt:$attempted"; echo "$1"; }
  vf="$SCHEDULER_SCRIPTS_DIR/verdict-file.py"
  ev=$(jq -c --arg ve "$ve" '((.meta | objects | .verdict_events) // {})[$ve] // empty' "$(task_path "$id")" 2>/dev/null)
  to=$(printf '%s' "$ev" | jq -r '.route_to // empty' 2>/dev/null)
  artifact=$(printf '%s' "$ev" | jq -r '.artifact // empty' 2>/dev/null)
  sha=$(printf '%s' "$ev" | jq -r '.artifact_sha256 // empty' 2>/dev/null)
  if [ -z "$to" ] || ! validate_pane_name "$to" "verdict route" 2>/dev/null \
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

# verdict_notify_typed <task-id> <event-id>
# Direct-call wrapper for the three helpers: runs verdict_notify with the typed channel
# and sets VERDICT_OUTCOME (the outcome word, unchanged) and VERDICT_ATTEMPT (yes|no).
# shellcheck disable=SC2034  # read by the sourcing task-done/task-block scripts
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
  task_update "$id" \
    'if ((.meta | objects | .verdict_events) // {}) | has($ve)
     then .meta.verdict_events[$ve].notification = {state: $s, at: $t}
     else . end' \
    --arg ve "$ve" --arg s "$state" --arg t "$(iso_now)"
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
# Runs under the per-task lock; the transition check happens INSIDE the lock so
# it is evaluated against the state that will actually be replaced.
task_set_status() {
  local id="$1" rc
  task_lock "$id" || return 1
  task_set_status_unlocked "$@"; rc=$?
  task_unlock "$id"
  return $rc
}

# Caller MUST already hold task_lock <id>. Used by task-assign to fold its
# metadata update and status flip into one locked mutation.
task_set_status_unlocked() {
  local id="$1" status="$2" actor="$3" note="${4:-}"
  # Optional 5th argument: compact JSON {event_id, artifact, sha} of a verdict
  # event. It is recorded in the SAME atomic ledger write as the transition
  # (see verdict_event_filter); absent or empty means no event.
  local verdict_json="${5:-null}"
  local current_status
  contract_legacy_guard "$id" "$(cat "$(task_path "$id")")" || return 1
  current_status=$(task_get "$id" '.status')
  if ! transition_allowed "$current_status" "$status"; then
    if scheduler_force_enabled; then
      note="${note:+$note }(forced)"
    else
      echo "ERROR: illegal status transition '$current_status' -> '$status' for task $id." >&2
      echo "  current status: $current_status; legal next: $(legal_targets "$current_status")" >&2
      echo "  Override with --force (or SESSION_SCHEDULER_FORCE=1)." >&2
      _sched_diag_note sched.transition.illegal
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
    --argjson ve "$verdict_json" \
    '.status = $status
     | .updated_at = $ts
     | (if $status == "assigned" and ((.started_at // null) == null)
        then .started_at = $ts else . end)
     | .history += [{ts: $ts, event: $status, actor: $actor, note: $note}]
     | '"$VERDICT_EVENT_FILTER")
  task_write "$id" "$updated"
}

# Set assignee (used by task-assign).
task_set_assignee() {
  local id="$1" assignee="$2" prompt_file="$3"
  task_update "$id" '.assignee = $assignee | .prompt_file = $prompt_file' \
    --arg assignee "$assignee" \
    --arg prompt_file "$prompt_file"
}

validate_task_id() {
  local id="$1"
  if [ -z "$id" ]; then
    echo "ERROR: task id required." >&2
    _sched_diag_note sched.argv.task_id_missing
    return 1
  fi
  if ! [[ "$id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: invalid task id '$id' (alphanumeric, _, - only)." >&2
    _sched_diag_note sched.argv.task_id_invalid
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

# Context snapshot names are owned by the knowledge context store, not by this
# plugin: it only accepts canonical snake_case slugs (lowercase alphanumerics
# joined by single underscores) and rejects anything else in the store — so a
# name the scheduler attaches must satisfy the same contract or the executor
# could never load it. Kept byte-identical to knowledge's
# KNOWLEDGE_CANONICAL_NAME_REGEX.
SESSION_SCHEDULER_CANONICAL_NAME_REGEX='^[a-z0-9]+(_[a-z0-9]+)*$'

validate_context_name() {
  local name="$1"
  if [ -z "$name" ]; then
    echo "ERROR: context snapshot name required." >&2
    return 1
  fi
  if ! [[ "$name" =~ $SESSION_SCHEDULER_CANONICAL_NAME_REGEX ]]; then
    echo "ERROR: invalid context name '$name' — context snapshot names must be canonical snake_case: lowercase letters/digits separated by single underscores (regex: $SESSION_SCHEDULER_CANONICAL_NAME_REGEX)." >&2
    echo "  No hyphens, uppercase, leading/trailing underscores, or repeated underscores." >&2
    return 1
  fi
}

# Unique component for an auto-handoff snapshot name. Knowledge's naming
# contract keeps dates/datetimes in metadata, never in a current snapshot
# filename — and a task id can itself carry a date or epoch stamp — so this is
# pure OS entropy: never a task id, a timestamp, or anything derived from
# either. 16 bytes rendered as 32 lowercase hex digits, from /dev/urandom or
# openssl only — no weaker fallback; fails closed if neither is available. Task
# association lives in the handoff body and the ledger's meta.context, not in
# the filename.
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
  # No weaker source: a predictable nonce would make the "immutable, unique
  # handoff" guarantee a lie, so fail closed instead.
  echo "ERROR: could not obtain 16 bytes of OS randomness for an auto context." >&2
  return 1
}

# context snapshots live under SESSION_CONTEXT_HOME, which must match
# the same override honored by the knowledge context store's own get_contexts_dir(). Like
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

# Compute attention flags for a task json file: OVERDUE (past eta_at while the
# task can still be acted on) and/or STALE (assigned/review with no update for
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
  # Contracted tasks carry their admission state; a done without admission is
  # CONTRACT:closed-unadmitted, never a clean completion.
  if jq -e 'has("contract")' "$file" >/dev/null 2>&1; then
    local cid cstate
    cid=$(jq -r '.id // ""' "$file" 2>/dev/null)
    if validate_task_id "$cid" >/dev/null 2>&1 && [ "$(task_path "$cid")" = "$file" ]; then
      cstate=$(contract_state "$cid")
    else
      cstate="invalid"
    fi
    flags="${flags:+$flags,}CONTRACT:$cstate"
  fi
  printf '%s\n' "${flags:--}"
}
