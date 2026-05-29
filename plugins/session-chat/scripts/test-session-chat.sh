#!/usr/bin/env bash
# test-session-chat.sh — Throwaway-tmux smoke tests for session-chat lib.sh.
# Runs in an isolated tmux server (-L socket) so it does not interfere with
# the user's main tmux. Cleans up on exit.
#
# Usage: bash test-session-chat.sh [-v]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SOCKET="session-chat-test-$$"
SESSION="sct"
OTHER_SESSION="sct-other"
VERBOSE=0
PASS=0
FAIL=0
FAILURES=()
TEST_MSGS_DIR="$(mktemp -d -t session-chat-test-msgs-XXXXXX)"

[ "${1:-}" = "-v" ] && VERBOSE=1

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$TEST_MSGS_DIR" 2>/dev/null || true
  rm -rf "${TMPDIR:-/tmp}/session-chat-locks" 2>/dev/null || true
}
trap cleanup EXIT

log()  { [ "$VERBOSE" -eq 1 ] && echo "[debug] $*" >&2; return 0; }
pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1: $2"); echo "  FAIL  $1 — $2"; }

# Run send-message.sh from inside a tmux pane. Returns the script's stdout+stderr.
# Each invocation runs in its own tmux pane (the "sender" pane) so $TMUX_PANE
# resolves correctly and lib.sh's send_text targets the recipient pane.
run_in_pane() {
  local sender_pane="$1"; shift
  local cmd="$*"
  local out
  out=$(tmux -L "$SOCKET" send-keys -t "$sender_pane" "$cmd" Enter 2>&1)
  echo "$out"
}

# Capture-pane helper
cap() {
  tmux -L "$SOCKET" capture-pane -t "$1" -p -S -200 2>/dev/null
}

# --- Setup ---
echo "=== session-chat tests (socket: $SOCKET) ==="
tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 200 -y 50
tmux -L "$SOCKET" split-window -t "$SESSION" -h
tmux -L "$SOCKET" split-window -t "$SESSION" -h
tmux -L "$SOCKET" new-session -d -s "$OTHER_SESSION" -x 120 -y 20

# Pane ids
PANES=$(tmux -L "$SOCKET" list-panes -t "$SESSION" -F '#{pane_id}')
read -r SENDER_PANE RECIPIENT_PANE EXTRA_PANE <<< "$(echo "$PANES" | tr '\n' ' ')"
OTHER_PANE=$(tmux -L "$SOCKET" list-panes -t "$OTHER_SESSION" -F '#{pane_id}' | sed -n '1p')
log "sender=$SENDER_PANE recipient=$RECIPIENT_PANE extra=$EXTRA_PANE"

# Name recipient and extra
tmux -L "$SOCKET" set-option -p -t "$RECIPIENT_PANE" @name "alpha"
tmux -L "$SOCKET" set-option -p -t "$EXTRA_PANE" @name "beta"
tmux -L "$SOCKET" set-option -p -t "$SENDER_PANE" @name "sender"
tmux -L "$SOCKET" set-option -p -t "$OTHER_PANE" @name "other-session"

run_script() {
  TMUX_PANE="$SENDER_PANE" \
  TMUX="$(tmux -L "$SOCKET" display-message -p -t "$SENDER_PANE" '#{socket_path},#{pid},0')" \
  bash "$HERE/list-panes.sh" "$@"
}

# Direct test driver: source lib.sh in subshell, override TMUX_PANE.
run_lib() {
  local sender="$1"; shift
  TMUX_PANE="$sender" \
  SESSION_CHAT_VERIFY_TIMEOUT_MS="${SESSION_CHAT_VERIFY_TIMEOUT_MS:-1000}" \
  SESSION_CHAT_SETTLE_MS=50 \
  TMUX="$(tmux -L "$SOCKET" display-message -p '#{socket_path}'),0,0" \
  bash -c "
    set -u
    source '$HERE/lib.sh'
    export MESSAGES_DIR='$TEST_MSGS_DIR'
    # Override tmux to use our socket
    tmux() { command tmux -L '$SOCKET' \"\$@\"; }
    export -f tmux
    $*
  "
}

# --- Test 1: /send happy path ---
out=$(run_script 2>&1)
if echo "$out" | grep -qF "sender" && echo "$out" | grep -qF "alpha" && ! echo "$out" | grep -qF "other-session"; then
  pass "panes_current_session"
else
  fail "panes_current_session" "expected current session only, got: $out"
fi

out=$(run_script all 2>&1)
if echo "$out" | grep -qF "other-session"; then
  pass "panes_all_sessions"
else
  fail "panes_all_sessions" "expected all sessions output to include other-session, got: $out"
fi

out=$(SESSION_CHAT_VERIFY_TIMEOUT_MS=1500 run_lib "$SENDER_PANE" "send_message alpha 'hello-from-test'" 2>&1)
if echo "$out" | grep -q ERROR; then
  fail "send_happy" "got error: $out"
elif cap "$RECIPIENT_PANE" | grep -qF 'hello-from-test'; then
  pass "send_happy"
else
  fail "send_happy" "marker not found in recipient pane; out=$out"
fi

# --- Test 2: /send newline guard ---
out=$(run_lib "$SENDER_PANE" "send_message alpha \$'line1\nline2'" 2>&1)
if echo "$out" | grep -q "contains newlines"; then pass "send_newline_guard"
else fail "send_newline_guard" "expected newline guard error, got: $out"; fi

# --- Test 3: /send length guard ---
out=$(run_lib "$SENDER_PANE" 'send_message alpha "$(printf %.0sx {1..1100})"' 2>&1)
if echo "$out" | grep -q ">1024"; then pass "send_length_guard"
else fail "send_length_guard" "expected length guard error, got: $out"; fi

# --- Test 4: /send unknown pane ---
out=$(run_lib "$SENDER_PANE" "send_message ghost 'nope'" 2>&1)
if echo "$out" | grep -q "No pane named 'ghost'"; then pass "send_unknown_pane"
else fail "send_unknown_pane" "expected unknown-pane error, got: $out"; fi

# --- Test 5: /dispatch happy path + file written ---
out=$(SESSION_CHAT_VERIFY_TIMEOUT_MS=1500 run_lib "$SENDER_PANE" "dispatch_message alpha \$'multi\nline\npayload with \$dollars and \`backticks\`'" 2>&1)
files=("$TEST_MSGS_DIR"/*.md)
if [ ${#files[@]} -ge 1 ] && grep -qF '$dollars' "${files[0]}" && cap "$RECIPIENT_PANE" | grep -q 'dispatch ('; then
  pass "dispatch_happy"
else
  fail "dispatch_happy" "file or marker missing; out=$out files=${files[*]}"
fi

# --- Test 6: duplicate-name detection ---
# Add another pane named 'alpha'
tmux -L "$SOCKET" split-window -t "$SESSION" -h
DUP_PANE=$(tmux -L "$SOCKET" list-panes -t "$SESSION" -F '#{pane_id}' | tail -1)
tmux -L "$SOCKET" set-option -p -t "$DUP_PANE" @name "alpha"
out=$(run_lib "$SENDER_PANE" "send_message alpha 'dupe-test'" 2>&1)
if echo "$out" | grep -q "Multiple panes named 'alpha'"; then pass "duplicate_name"
else fail "duplicate_name" "expected duplicate error, got: $out"; fi
# Restore: rename DUP_PANE
tmux -L "$SOCKET" set-option -p -t "$DUP_PANE" @name "gamma"

# --- Test 7: lock contention (two parallel sends to alpha both land) ---
(SESSION_CHAT_VERIFY_TIMEOUT_MS=1500 run_lib "$SENDER_PANE" "send_message alpha 'parallel-A'" >/dev/null 2>&1) &
(SESSION_CHAT_VERIFY_TIMEOUT_MS=1500 run_lib "$SENDER_PANE" "send_message alpha 'parallel-B'" >/dev/null 2>&1) &
wait
sleep 0.3
recipient_log=$(cap "$RECIPIENT_PANE")
if echo "$recipient_log" | grep -qF 'parallel-A' && echo "$recipient_log" | grep -qF 'parallel-B'; then
  pass "lock_contention"
else
  fail "lock_contention" "missing one of parallel-A/B in recipient"
fi

# --- Test 8: retry path triggers on tight timeout (should still succeed via retry) ---
# Use a tight timeout to force at least one retry under load
out=$(SESSION_CHAT_VERIFY_TIMEOUT_MS=200 SESSION_CHAT_SEND_RETRIES=3 run_lib "$SENDER_PANE" "send_message alpha 'retry-probe'" 2>&1)
if echo "$out" | grep -q ERROR; then
  fail "retry_eventual_success" "retries exhausted: $out"
elif cap "$RECIPIENT_PANE" | grep -qF 'retry-probe'; then
  pass "retry_eventual_success"
else
  fail "retry_eventual_success" "no marker on recipient"
fi

# --- Summary ---
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
