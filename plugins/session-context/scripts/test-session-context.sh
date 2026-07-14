#!/usr/bin/env bash
# test-session-context.sh — hermetic tests for context sharing transport.
# Covers: hardened session-chat transport is preferred (delivered/queued/hard-fail
# return codes) and the builtin tmux fallback when session-chat is absent.
# Uses an isolated tmux server (-L socket) for the fallback path so it never
# touches the user's real tmux. Cleans up on exit.
#
# Usage: bash test-session-context.sh [-v]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SOCKET="session-context-test-$$"
SESSION="sctx"
PASS=0
FAIL=0
FAILURES=()
TMP="$(mktemp -d -t session-context-test-XXXXXX)"
export SESSION_CONTEXT_HOME="$TMP/contexts"
mkdir -p "$SESSION_CONTEXT_HOME"

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1: $2"); echo "  FAIL  $1 — $2"; }

echo "=== session-context tests (socket: $SOCKET) ==="

# A snapshot to share.
printf '# snapshot for ProjectA\nwork summary\n' > "$SESSION_CONTEXT_HOME/proj-1.md"

# --- session-chat transport stub (no tmux needed for these) -----------------
# Its send-message.sh echoes its args and exits with a code we control via
# STUB_RC so we can drive the delivered / queued / hard-fail branches.
# Model the REAL send-message.sh wrapper: it exits 0 for BOTH a live delivery
# AND a queued (busy) send — printing "Sent to …" or "Queued to …" respectively
# — and exits 1 only on a hard failure. The stub also captures the message it
# was handed to a file so tests can assert the packet body, and ships mode 0644
# (not +x) to prove share-context accepts a readable-not-executable entrypoint.
make_stub() {
  local mode="$1"                     # delivered | queued | fail
  local root="$TMP/sc-stub-$mode"
  mkdir -p "$root/scripts"
  local cap="$root/last-msg.txt"
  {
    echo '#!/usr/bin/env bash'
    case "$mode" in
      delivered) printf 'printf "%%s" "$2" > %q\necho "Sent to $1."\nexit 0\n' "$cap" ;;
      queued)    printf 'printf "%%s" "$2" > %q\necho "Queued to $1 — recipient was busy; it will arrive on their next turn."\nexit 0\n' "$cap" ;;
      fail)      printf 'echo "ERROR: This pane has no name." >&2\nexit 1\n' ;;
    esac
  } > "$root/scripts/send-message.sh"
  chmod 644 "$root/scripts/send-message.sh"
  printf '%s\n' "$root"
}

run_share() {
  # run_share <sc_root_override> <target> <snapshot>
  local override="$1"; shift
  TMUX="fake-socket,0,0" \
  SESSION_CHAT_ROOT_OVERRIDE="$override" \
  SESSION_CONTEXT_HOME="$SESSION_CONTEXT_HOME" \
  bash "$HERE/share-context.sh" "$@" 2>&1
}

# --- Test 1: hardened transport preferred + 0644 entrypoint selected (delivered) ---
STUB0=$(make_stub delivered)
stub_mode=$(stat -c '%a' "$STUB0/scripts/send-message.sh" 2>/dev/null || stat -f '%Lp' "$STUB0/scripts/send-message.sh" 2>/dev/null)
out=$(run_share "$STUB0" some-peer proj-1)
rc=$?
if [ "$rc" -eq 0 ] && [ "$stub_mode" = "644" ] && echo "$out" | grep -q "transport: session-chat (delivered live)"; then
  pass "prefers_session_chat_0644_delivered"
else
  fail "prefers_session_chat_0644_delivered" "rc=$rc mode=$stub_mode out=$out"
fi

# --- Test 2: busy recipient -> queued, classified from wrapper OUTPUT (rc still 0) ---
STUBQ=$(make_stub queued)
out=$(run_share "$STUBQ" some-peer proj-1)
rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "queued to recipient's durable inbox"; then
  pass "queued_classified_from_output"
else
  fail "queued_classified_from_output" "rc=$rc out=$out"
fi

# --- Test 3: hard failure (wrapper exits 1) surfaces as error ---
STUBF=$(make_stub fail)
out=$(run_share "$STUBF" some-peer proj-1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "session-chat could not notify"; then
  pass "session_chat_hard_fail_errors"
else
  fail "session_chat_hard_fail_errors" "rc=$rc out=$out"
fi

# --- Test 4: share message carries the canonical store path (same-store prereq) ---
STORE_ABS=$(cd "$SESSION_CONTEXT_HOME" && pwd -P)
out=$(run_share "$STUB0" some-peer proj-1)
if echo "$out" | grep -qF "store:     $STORE_ABS"; then
  pass "share_message_has_store_path"
else
  fail "share_message_has_store_path" "expected store $STORE_ABS in: $out"
fi

# --- Test 4b: notification body lists BOTH provider forms + provenance contract ---
# Assert against the actual message the wrapper received (captured by the stub),
# using the namespaced Claude form /session-context:context-load. The message
# must carry the raw canonical store as provenance with inherited/relaunch
# guidance and NO executable export instruction.
sent_msg=$(cat "$STUB0/last-msg.txt" 2>/dev/null)
if printf '%s' "$sent_msg" | grep -qF "/session-context:context-load proj-1" \
   && printf '%s' "$sent_msg" | grep -qF '$session-context:context-load proj-1' \
   && printf '%s' "$sent_msg" | grep -qF "store (provenance): $STORE_ABS" \
   && printf '%s' "$sent_msg" | grep -qF "inherited" \
   && printf '%s' "$sent_msg" | grep -qF "relaunch" \
   && ! printf '%s' "$sent_msg" | grep -qE 'export SESSION_CONTEXT_HOME='; then
  pass "share_message_dual_provider"
else
  fail "share_message_dual_provider" "sent=$sent_msg"
fi

# --- Test 4c: store path with space AND apostrophe -> raw provenance path intact ---
WEIRD="$TMP/ctx dir's weird"
mkdir -p "$WEIRD"; printf '# weird store\n' > "$WEIRD/proj-2.md"
STUBW=$(make_stub delivered)
out=$(TMUX="fake,0,0" SESSION_CHAT_ROOT_OVERRIDE="$STUBW" SESSION_CONTEXT_HOME="$WEIRD" \
  bash "$HERE/share-context.sh" some-peer proj-2 2>&1)
sentw=$(cat "$STUBW/last-msg.txt" 2>/dev/null)
weird_abs=$(cd "$WEIRD" && pwd -P)
if printf '%s' "$sentw" | grep -qF "store (provenance): $weird_abs" \
   && ! printf '%s' "$sentw" | grep -qE 'export SESSION_CONTEXT_HOME='; then
  pass "share_provenance_special_path"
else
  fail "share_provenance_special_path" "sent=$sentw expected=$weird_abs"
fi

# --- Test 5: missing snapshot is rejected before any transport ---
out=$(run_share "$STUB0" some-peer no-such-snap)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "No context snapshot found"; then
  pass "missing_snapshot_rejected"
else
  fail "missing_snapshot_rejected" "rc=$rc out=$out"
fi

# --- Test 6: builtin fallback path when session-chat is absent (real tmux) ---
# Point the override at a dir with no send-message.sh so session_chat_root
# resolves but the executable check fails, forcing the builtin transport.
# Recipient is a neutral `cat` sink, not a shell: a shell would EXECUTE the pasted
# notification and its command-not-found redraw can consume the line before
# capture-pane stabilizes on a loaded CI runner (the same render flake fixed in
# the session-chat suite). `cat` echoes stdin verbatim as stable pane output.
tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 200 -y 50
tmux -L "$SOCKET" split-window -t "$SESSION" -h "cat"
PANES=$(tmux -L "$SOCKET" list-panes -t "$SESSION" -F '#{pane_id}')
read -r SENDER_PANE RECIPIENT_PANE <<< "$(echo "$PANES" | tr '\n' ' ')"
tmux -L "$SOCKET" set-option -p -t "$SENDER_PANE" @name "sctx-sender"
tmux -L "$SOCKET" set-option -p -t "$RECIPIENT_PANE" @name "sctx-recipient"

NO_SC="$TMP/no-session-chat"
mkdir -p "$NO_SC/scripts"  # exists but has no send-message.sh

# TMUX is set explicitly (not inherited from the ambient env) so this passes
# ensure_tmux under `env -u TMUX`; the tmux() shim routes to the test socket.
fallback_out=$(
  TMUX="test-socket,0,0" \
  TMUX_PANE="$SENDER_PANE" \
  SESSION_CHAT_ROOT_OVERRIDE="$NO_SC" \
  SESSION_CONTEXT_HOME="$SESSION_CONTEXT_HOME" \
  bash -c '
    tmux() { command tmux -L "'"$SOCKET"'" "$@"; }
    export -f tmux
    bash "'"$HERE"'/share-context.sh" sctx-recipient proj-1 2>&1
  '
)
# Adaptive poll for the marker to render (replaces a fixed sleep that raced pane
# render on loaded CI runners); -J joins wrapped lines so a wrapped marker matches.
recipient_cap=""
fb_waited=0
while :; do
  recipient_cap=$(tmux -L "$SOCKET" capture-pane -J -t "$RECIPIENT_PANE" -p -S -200 2>/dev/null)
  echo "$recipient_cap" | grep -qF '[context:proj-1]' && break
  [ "$fb_waited" -ge 5000 ] && break
  sleep 0.05; fb_waited=$((fb_waited + 50))
done
if echo "$fallback_out" | grep -q "transport: session-context builtin" \
   && echo "$recipient_cap" | grep -qF '[context:proj-1]'; then
  pass "builtin_fallback_delivers"
else
  fail "builtin_fallback_delivers" "out=$fallback_out; cap=$recipient_cap"
fi

# --- Test 7: TMUX unset -> clean 'must run inside tmux' error, never a crash ---
# Guards the ${TMUX:-} runtime guard: under set -u an unguarded $TMUX read would
# abort with "unbound variable" instead of the intended graceful refusal.
unset_out=$(env -u TMUX -u TMUX_PANE SESSION_CONTEXT_HOME="$SESSION_CONTEXT_HOME" \
  bash "$HERE/share-context.sh" some-peer proj-1 2>&1)
urc=$?
if [ "$urc" -ne 0 ] && echo "$unset_out" | grep -q "must run inside tmux" \
   && ! echo "$unset_out" | grep -q "unbound variable"; then
  pass "unset_tmux_clean_error"
else
  fail "unset_tmux_clean_error" "urc=$urc out=$unset_out"
fi

# --- Test 8: store hardening migrates legacy modes + preserves 0400 auto ---
harden_out=$(
  source "$HERE/lib.sh"
  B=$(mktemp -d); S="$B/store"; mkdir -p "$S/.history"
  umask 022
  printf x > "$S/a.md"; chmod 644 "$S/a.md"
  printf x > "$S/.history/a.20200101-000000Z.md"; chmod 640 "$S/.history/a.20200101-000000Z.md"
  printf x > "$S/auto.md"; chmod 400 "$S/auto.md"
  chmod 755 "$S" "$S/.history"
  m() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
  if harden_existing_contexts_dir "$S"; then
    echo "RC0 STORE=$(m "$S") HIST=$(m "$S/.history") FILE=$(m "$S/a.md") HFILE=$(m "$S/.history/a.20200101-000000Z.md") AUTO=$(m "$S/auto.md")"
  fi
  rm -rf "$B"
)
if echo "$harden_out" | grep -q "RC0" && echo "$harden_out" | grep -q "STORE=700" \
   && echo "$harden_out" | grep -q "HIST=700" && echo "$harden_out" | grep -q "FILE=600" \
   && echo "$harden_out" | grep -q "HFILE=600" && echo "$harden_out" | grep -q "AUTO=400"; then
  pass "harden_migrates_and_preserves_auto"
else
  fail "harden_migrates_and_preserves_auto" "out=$harden_out"
fi

# --- Test 9: store hardening rejects root + nested symlinks (fail closed) ---
reject_out=$(
  source "$HERE/lib.sh"
  B=$(mktemp -d); mkdir -p "$B/real"; ln -s "$B/real" "$B/link"
  harden_existing_contexts_dir "$B/link" >/dev/null 2>&1 && echo ROOT_ACCEPT || echo ROOT_REJECT
  mkdir -p "$B/store"; ln -s /etc/hosts "$B/store/evil.md"
  harden_existing_contexts_dir "$B/store" >/dev/null 2>&1 && echo NESTED_ACCEPT || echo NESTED_REJECT
  rm -rf "$B"
)
if echo "$reject_out" | grep -q "ROOT_REJECT" && echo "$reject_out" | grep -q "NESTED_REJECT"; then
  pass "harden_rejects_symlinks"
else
  fail "harden_rejects_symlinks" "out=$reject_out"
fi

# --- Test 10: context removal is confirmation-gated ---
RMHOME="$TMP/rmstore"; mkdir -p "$RMHOME/.history"
printf '# snap\n' > "$RMHOME/rmproj.md"
printf '# v1\n' > "$RMHOME/.history/rmproj.20200101-000000Z.md"
printf '# v2\n' > "$RMHOME/.history/rmproj.20200102-000000Z.md"
printf '# other\n' > "$RMHOME/other.md"
printf '# ov1\n' > "$RMHOME/.history/other.20200101-000000Z.md"
out=$(SESSION_CONTEXT_HOME="$RMHOME" bash "$HERE/remove-context.sh" rmproj 2>&1); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "REFUSED" && [ -f "$RMHOME/rmproj.md" ]; then
  pass "remove_refuses_without_confirmed"
else
  fail "remove_refuses_without_confirmed" "rc=$rc out=$out"
fi

# --- Test 11: confirmed removal deletes snapshot + its history, preserves others ---
out=$(SESSION_CONTEXT_HOME="$RMHOME" bash "$HERE/remove-context.sh" rmproj --confirmed 2>&1); rc=$?
hist_left=$(ls "$RMHOME/.history/rmproj."*.md 2>/dev/null | wc -l | tr -d ' ')
if [ "$rc" -eq 0 ] && [ ! -f "$RMHOME/rmproj.md" ] && [ "$hist_left" = "0" ] \
   && [ -f "$RMHOME/other.md" ] && [ -f "$RMHOME/.history/other.20200101-000000Z.md" ] \
   && echo "$out" | grep -q "3 file(s) deleted"; then
  pass "remove_confirmed_deletes_snapshot_and_history"
else
  fail "remove_confirmed_deletes_snapshot_and_history" "rc=$rc hist_left=$hist_left out=$out"
fi

# --- Test 12: store-shape validation rejects an unexpected project tree, NO chmod ---
shape_out=$(
  source "$HERE/lib.sh"
  B=$(mktemp -d); S="$B/store"; mkdir -p "$S/src"
  printf 'code' > "$S/src/main.c"
  printf '# snap' > "$S/proj.md"
  chmod 755 "$S" "$S/src"
  before=$(stat -c '%a' "$S" 2>/dev/null || stat -f '%Lp' "$S" 2>/dev/null)
  harden_existing_contexts_dir "$S" >/dev/null 2>&1 && echo ACCEPT || echo REJECT
  after=$(stat -c '%a' "$S" 2>/dev/null || stat -f '%Lp' "$S" 2>/dev/null)
  echo "UNCHANGED=$([ "$before" = "$after" ] && echo yes || echo no)"
  rm -rf "$B"
)
if echo "$shape_out" | grep -q REJECT && echo "$shape_out" | grep -q "UNCHANGED=yes"; then
  pass "store_shape_reject_no_chmod"
else
  fail "store_shape_reject_no_chmod" "out=$shape_out"
fi

# --- Test 13: confirmed removal cleans ORPHANED history when snapshot is gone ---
ORPH="$TMP/orphstore"; mkdir -p "$ORPH/.history"
printf '# v1' > "$ORPH/.history/gone.20200101-000000Z.md"
printf '# v2' > "$ORPH/.history/gone.20200102-000000Z.md"
out=$(SESSION_CONTEXT_HOME="$ORPH" bash "$HERE/remove-context.sh" gone --confirmed 2>&1); rc=$?
left=$(ls "$ORPH/.history/gone."*.md 2>/dev/null | wc -l | tr -d ' ')
if [ "$rc" -eq 0 ] && [ "$left" = "0" ] && echo "$out" | grep -q "orphaned history"; then
  pass "remove_orphan_history"
else
  fail "remove_orphan_history" "rc=$rc left=$left out=$out"
fi

# --- Test 14: removal errors only when NEITHER snapshot nor history exists ---
out=$(SESSION_CONTEXT_HOME="$ORPH" bash "$HERE/remove-context.sh" totally-absent --confirmed 2>&1); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "No current or archived context snapshot"; then
  pass "remove_errors_when_nothing_exists"
else
  fail "remove_errors_when_nothing_exists" "rc=$rc out=$out"
fi

# --- Test 14b: remove rejects an unexpected extra operand (capability boundary) ---
out=$(SESSION_CONTEXT_HOME="$ORPH" bash "$HERE/remove-context.sh" rmproj extra --confirmed 2>&1); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "unexpected argument"; then
  pass "remove_rejects_extra_operand"
else
  fail "remove_rejects_extra_operand" "rc=$rc out=$out"
fi

# --- Test 15: concurrent first-use saves serialize — one safe store, all land ---
# Regression for the store-init race Tier B closed on the Claude side: parallel
# first-time saves each ran the whole-store harden sweep UNLOCKED and one
# spuriously failed. The writer lock now serializes harden + atomic write.
RACE_STORE="$TMP/race-contexts"
race_pids=()
for race_index in 1 2 3 4 5 6; do
  printf 'race %s\n' "$race_index" > "$TMP/race-$race_index.md"
  SESSION_CONTEXT_HOME="$RACE_STORE" \
    bash "$HERE/save-context.sh" "race$race_index" "$TMP/race-$race_index.md" \
      > "$TMP/race-$race_index.out" 2>&1 &
  race_pids+=("$!")
done
race_failed=0
for race_pid in "${race_pids[@]}"; do wait "$race_pid" || race_failed=1; done
race_present=0
for race_index in 1 2 3 4 5 6; do
  [ -f "$RACE_STORE/race$race_index.md" ] && race_present=$((race_present + 1))
done
race_mode=$(stat -c '%a' "$RACE_STORE" 2>/dev/null || stat -f '%Lp' "$RACE_STORE" 2>/dev/null)
race_temp=$(find "$RACE_STORE" -name '.session-context.tmp.*' -print -quit 2>/dev/null)
if [ "$race_failed" -eq 0 ] && [ "$race_present" -eq 6 ] && [ "$race_mode" = "700" ] && [ -z "$race_temp" ]; then
  pass "concurrent_store_saves"
else
  fail "concurrent_store_saves" "failed=$race_failed present=$race_present/6 mode=$race_mode temp=$race_temp"
fi

# --- Test 16: the writer lock serializes saves (event-gated, no wall-clock race) ---
# A save must hold the exclusive writer lock before it hardens/writes, so while
# another holder holds it the save BLOCKS rather than racing the holder's tree,
# then completes once released. The holder waits for a RELEASE marker instead of
# sleeping — it CANNOT release on its own, so a descheduled test process cannot
# race the observation window. Markers live OUTSIDE the store so tree validation
# ignores them.
LSTORE="$TMP/lock-serial"; mkdir -p "$LSTORE"
LS_ACQ="$TMP/ls-acquired"; LS_REL="$TMP/ls-release"; rm -f "$LS_ACQ" "$LS_REL"
(
  source "$HERE/lib.sh"
  acquire_context_store_lock "$LSTORE" >/dev/null 2>&1 || exit 1
  : > "$LS_ACQ"
  hw=0; while [ ! -e "$LS_REL" ] && [ "$hw" -lt 4000 ]; do sleep 0.05; hw=$((hw + 50)); done
  release_context_store_lock >/dev/null 2>&1
) &
lock_holder_pid=$!
lw=0; while [ ! -e "$LS_ACQ" ] && [ "$lw" -lt 3000 ]; do sleep 0.05; lw=$((lw + 50)); done
if [ ! -e "$LS_ACQ" ]; then
  fail "writer_lock_serializes_saves" "holder never acquired the writer lock"
else
  printf 'lock probe\n' > "$TMP/lock-probe.md"
  SESSION_CONTEXT_HOME="$LSTORE" bash "$HERE/save-context.sh" lockprobe "$TMP/lock-probe.md" \
    > "$TMP/lock-probe.out" 2>&1 &
  lock_save_pid=$!
  sleep 0.4   # let the save reach acquire; the holder cannot release until we signal
  if kill -0 "$lock_save_pid" 2>/dev/null && [ ! -f "$LSTORE/lockprobe.md" ]; then
    lock_blocked=1
  else
    lock_blocked=0
  fi
  : > "$LS_REL"   # signal the holder to release
  wait "$lock_holder_pid"; lock_holder_rc=$?
  wait "$lock_save_pid"; lock_save_rc=$?
  if [ "$lock_blocked" -eq 1 ] && [ "$lock_holder_rc" -eq 0 ] && [ "$lock_save_rc" -eq 0 ] \
     && [ -f "$LSTORE/lockprobe.md" ]; then
    pass "writer_lock_serializes_saves"
  else
    fail "writer_lock_serializes_saves" "blocked=$lock_blocked holder_rc=$lock_holder_rc save_rc=$lock_save_rc out=$(cat "$TMP/lock-probe.out" 2>/dev/null)"
  fi
fi

# --- Test 17: owner release waits for a transient generation claim ---
RELEASE_CLAIM_STORE="$TMP/release-claim-contexts"
mkdir -m 700 "$RELEASE_CLAIM_STORE"
if bash -c '
  source "$1"
  root="$2"
  acquire_context_store_lock "$root" || exit 1
  mkdir -m 700 "$root/.session-context.lock/.reclaim"
  (sleep 0.1; rmdir "$root/.session-context.lock/.reclaim") &
  dropper=$!
  release_context_store_lock || exit 1
  wait "$dropper" || exit 1
  [ ! -e "$root/.session-context.lock" ]
' _ "$HERE/lib.sh" "$RELEASE_CLAIM_STORE"; then
  pass "release_waits_for_transient_generation_claim"
else
  fail "release_waits_for_transient_generation_claim" "owner release failed during bounded claim contention"
fi

# --- Test 18: dead-lock recovery and generation turnover are both safe ---
STALE_STORE="$TMP/stale-contexts"
mkdir -m 700 "$STALE_STORE"
if bash -c '
  source "$1"
  root="$2"
  mkdir -m 700 "$root/.session-context.lock"
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
  printf "%s\n" "$dead_pid" > "$root/.session-context.lock/pid"
  chmod 600 "$root/.session-context.lock/pid"
  acquire_context_store_lock "$root" || exit 1
  [ "$(sed -n "1p" "$root/.session-context.lock/pid")" = "$$" ] || exit 1
  release_context_store_lock || exit 1
  [ ! -e "$root/.session-context.lock" ] || exit 1
' _ "$HERE/lib.sh" "$STALE_STORE"; then
  pass "dead_writer_lock_reclaimed"
else
  fail "dead_writer_lock_reclaimed" "dead generation was not reclaimed safely"
fi

ABA_STORE="$TMP/aba-contexts"
mkdir -m 700 "$ABA_STORE"
if bash -c '
  source "$1"
  root="$2"
  mkdir -m 700 "$root/.session-context.lock"
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
  printf "%s\n" "$dead_pid" > "$root/.session-context.lock/pid"
  chmod 600 "$root/.session-context.lock/pid"
  old_token=$(_context_lock_generation_token "$root") || exit 1

  rm -f "$root/.session-context.lock/pid"
  rmdir "$root/.session-context.lock"
  mkdir -m 700 "$root/.session-context.lock"
  printf "%s\n" "$$" > "$root/.session-context.lock/pid"
  chmod 600 "$root/.session-context.lock/pid"
  new_token=$(_context_lock_generation_token "$root") || exit 1
  [ "$new_token" != "$old_token" ] || exit 1

  if _context_quarantine_lock_generation "$root" "$old_token" dead; then
    exit 1
  else
    rc=$?
  fi
  [ "$rc" -eq 2 ] || exit 1
  [ "$(_context_lock_generation_token "$root")" = "$new_token" ] || exit 1
  [ ! -e "$root/.session-context.lock/.reclaim" ] || exit 1
  [ -z "$(find "${root}.session-context-stale."* -maxdepth 0 -print -quit 2>/dev/null)" ] || exit 1
' _ "$HERE/lib.sh" "$ABA_STORE"; then
  pass "stale_generation_cannot_reclaim_replacement"
else
  fail "stale_generation_cannot_reclaim_replacement" "replacement generation changed or was quarantined"
fi

# --- Test 19: the transient reclaim claim stays owner-only and empty ---
BAD_RECLAIM_STORE="$TMP/bad-reclaim-contexts"
mkdir -m 700 "$BAD_RECLAIM_STORE"
mkdir -m 700 "$BAD_RECLAIM_STORE/.session-context.lock"
printf '%s\n' "$$" > "$BAD_RECLAIM_STORE/.session-context.lock/pid"
chmod 600 "$BAD_RECLAIM_STORE/.session-context.lock/pid"
mkdir -m 755 "$BAD_RECLAIM_STORE/.session-context.lock/.reclaim"
bad_reclaim_out=$(SESSION_CONTEXT_HOME="$BAD_RECLAIM_STORE" bash "$HERE/list-contexts.sh" 2>&1); bad_reclaim_rc=$?
if [ "$bad_reclaim_rc" -ne 0 ] && echo "$bad_reclaim_out" | grep -q "reclaim claim must be mode 700"; then
  pass "loose_reclaim_claim_rejected"
else
  fail "loose_reclaim_claim_rejected" "rc=$bad_reclaim_rc out=$bad_reclaim_out"
fi

# --- Test 20: agent-facing docs carry the inherited-env contract, no executable export ---
doc_stale=""
for doc in "$HERE/../commands"/*.md "$HERE/../skills"/*/SKILL.md; do
  [ -f "$doc" ] || continue
  if grep -qE '^[[:space:]]*export SESSION_CONTEXT_HOME' "$doc" \
     || grep -qE '(^|[[:space:]])env[[:space:]]+SESSION_CONTEXT_HOME=' "$doc" \
     || grep -qE 'SESSION_CONTEXT_HOME=[^[:space:]]*[[:space:]]+bash([[:space:]]|$)' "$doc"; then
    doc_stale="$doc_stale $(basename "$doc")(executable-export)"
  fi
  grep -q "inherited" "$doc" || doc_stale="$doc_stale $(basename "$doc")(missing-inherited)"
done
grep -qF "on the first attempt" "$HERE/../commands/context-share.md" \
  || doc_stale="$doc_stale context-share(escalation)"
grep -qF "one literal Bash segment" "$HERE/../commands/context-share.md" \
  || doc_stale="$doc_stale context-share(literal-segment)"
grep -qF "point-in-time preview" "$HERE/../commands/context-remove.md" \
  || doc_stale="$doc_stale context-remove(point-in-time)"
grep -qF '^[A-Za-z0-9_-]+$' "$HERE/../commands/context-remove.md" \
  || doc_stale="$doc_stale context-remove(label-validation)"
grep -qF "writer lock" "$HERE/../commands/context-remove.md" \
  || doc_stale="$doc_stale context-remove(concurrency-caveat)"
grep -qF "merely changing directories does not switch stores" "$HERE/../commands/context-search.md" \
  || doc_stale="$doc_stale context-search(cross-project-load)"
if [ -z "$doc_stale" ]; then
  pass "docs_inherited_env_contract"
else
  fail "docs_inherited_env_contract" "stale/missing:$doc_stale"
fi

# --- Test 21: unset SESSION_CONTEXT_HOME fails closed with inherited/relaunch guidance ---
unset_out=$(env -u SESSION_CONTEXT_HOME bash "$HERE/list-contexts.sh" 2>&1); unset_rc=$?
if [ "$unset_rc" -ne 0 ] \
   && echo "$unset_out" | grep -q "inherited" \
   && echo "$unset_out" | grep -q "relaunch"; then
  pass "unset_home_fails_closed_with_relaunch_guidance"
else
  fail "unset_home_fails_closed_with_relaunch_guidance" "rc=$unset_rc out=$unset_out"
fi

# --- Summary ---
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
