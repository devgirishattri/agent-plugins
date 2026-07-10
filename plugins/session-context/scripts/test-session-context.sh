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
stub_mode=$(stat -f '%Lp' "$STUB0/scripts/send-message.sh" 2>/dev/null || stat -c '%a' "$STUB0/scripts/send-message.sh" 2>/dev/null)
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

# --- Test 4b: notification body lists BOTH provider forms + exact export ---
# Assert against the actual message the wrapper received (captured by the stub),
# using the namespaced Claude form /session-context:context-load.
sent_msg=$(cat "$STUB0/last-msg.txt" 2>/dev/null)
if printf '%s' "$sent_msg" | grep -qF "/session-context:context-load proj-1" \
   && printf '%s' "$sent_msg" | grep -qF '$session-context:context-load proj-1' \
   && printf '%s' "$sent_msg" | grep -qF "export SESSION_CONTEXT_HOME=$(printf '%q' "$STORE_ABS")"; then
  pass "share_message_dual_provider"
else
  fail "share_message_dual_provider" "sent=$sent_msg"
fi

# --- Test 4c: store path with space AND apostrophe -> %q export is copy-paste safe ---
WEIRD="$TMP/ctx dir's weird"
mkdir -p "$WEIRD"; printf '# weird store\n' > "$WEIRD/proj-2.md"
STUBW=$(make_stub delivered)
out=$(TMUX="fake,0,0" SESSION_CHAT_ROOT_OVERRIDE="$STUBW" SESSION_CONTEXT_HOME="$WEIRD" \
  bash "$HERE/share-context.sh" some-peer proj-2 2>&1)
sentw=$(cat "$STUBW/last-msg.txt" 2>/dev/null)
weird_abs=$(cd "$WEIRD" && pwd -P)
expected_q="export SESSION_CONTEXT_HOME=$(printf '%q' "$weird_abs")"
# Prove copy-paste safety: running the exact export line yields the real path.
safe=$(bash -c "$expected_q; printf '%s' \"\$SESSION_CONTEXT_HOME\"")
if printf '%s' "$sentw" | grep -qF "$expected_q" && [ "$safe" = "$weird_abs" ]; then
  pass "share_export_quoted_special_path"
else
  fail "share_export_quoted_special_path" "sent=$sentw expected_q=$expected_q safe=$safe"
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
tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 200 -y 50
tmux -L "$SOCKET" split-window -t "$SESSION" -h
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
sleep 0.3
recipient_cap=$(tmux -L "$SOCKET" capture-pane -t "$RECIPIENT_PANE" -p -S -200 2>/dev/null)
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
  printf x > "$S/.history/a.20200101T000000Z.md"; chmod 640 "$S/.history/a.20200101T000000Z.md"
  printf x > "$S/auto.md"; chmod 400 "$S/auto.md"
  chmod 755 "$S" "$S/.history"
  m() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }
  if harden_contexts_dir "$S"; then
    echo "RC0 STORE=$(m "$S") HIST=$(m "$S/.history") FILE=$(m "$S/a.md") HFILE=$(m "$S/.history/a.20200101T000000Z.md") AUTO=$(m "$S/auto.md")"
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
  harden_contexts_dir "$B/link" >/dev/null 2>&1 && echo ROOT_ACCEPT || echo ROOT_REJECT
  mkdir -p "$B/store"; ln -s /etc/hosts "$B/store/evil.md"
  harden_contexts_dir "$B/store" >/dev/null 2>&1 && echo NESTED_ACCEPT || echo NESTED_REJECT
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
printf '# v1\n' > "$RMHOME/.history/rmproj.20200101T000000Z.md"
printf '# v2\n' > "$RMHOME/.history/rmproj.20200102T000000Z.md"
printf '# other\n' > "$RMHOME/other.md"
printf '# ov1\n' > "$RMHOME/.history/other.20200101T000000Z.md"
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
   && [ -f "$RMHOME/other.md" ] && [ -f "$RMHOME/.history/other.20200101T000000Z.md" ] \
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
  before=$(stat -f '%Lp' "$S" 2>/dev/null || stat -c '%a' "$S" 2>/dev/null)
  harden_contexts_dir "$S" >/dev/null 2>&1 && echo ACCEPT || echo REJECT
  after=$(stat -f '%Lp' "$S" 2>/dev/null || stat -c '%a' "$S" 2>/dev/null)
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
printf '# v1' > "$ORPH/.history/gone.20200101T000000Z.md"
printf '# v2' > "$ORPH/.history/gone.20200102T000000Z.md"
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

# --- Summary ---
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
