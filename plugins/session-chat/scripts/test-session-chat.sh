#!/usr/bin/env bash
# test-session-chat.sh — Throwaway-tmux smoke tests for session-chat lib.sh.
# Runs in an isolated tmux server (-L socket) so it does not interfere with
# the user's main tmux. Cleans up on exit.
#
# Usage: bash test-session-chat.sh [-v]
set -uo pipefail

# A workspace-exported mailbox override must not redirect baseline fixtures
# into the real project mailbox, and a workspace-exported self-name escape
# hatch must not short-circuit the self-name resolution that several baseline
# tests (real-tmux @name paths, and the sandbox-denial self-name tests) rely
# on. Per-test uses of these vars (e.g. test 26, and the custom-mailbox tests
# near the end) set them explicitly per invocation, so they are unaffected by
# this top-level unset.
unset SESSION_CHAT_TARGET_MESSAGES_DIR
unset SESSION_CHAT_PANE_NAME

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
  rm -rf "${TMPDIR:-/tmp}"/session-chat-locks* 2>/dev/null || true
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
  tmux -L "$SOCKET" capture-pane -J -t "$1" -p -S -200 2>/dev/null
}

# Poll capture-pane until NEEDLE renders in the pane, or TIMEOUT_MS elapses.
# On a loaded CI runner there is a lag between send-keys landing and the pasted
# text showing up in capture-pane, so a single immediate cap races the render.
# Prints the final capture; returns 0 on match, 1 on timeout.
#   cap_wait PANE NEEDLE [TIMEOUT_MS]
cap_wait() {
  local pane="$1" needle="$2" timeout_ms="${3:-3000}"
  local waited=0 out
  while :; do
    out=$(cap "$pane")
    if printf '%s' "$out" | grep -qF "$needle"; then
      printf '%s\n' "$out"; return 0
    fi
    [ "$waited" -ge "$timeout_ms" ] && { printf '%s\n' "$out"; return 1; }
    sleep 0.05; waited=$((waited + 50))
  done
}

# --- Setup ---
echo "=== session-chat tests (socket: $SOCKET) ==="
# Baseline live-send tests assert rendered pane text after Enter. Use neutral
# cat sinks so the message is echoed as stable output instead of being executed
# and redrawn by an interactive shell on slow/headless runners.
tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 200 -y 50 "cat"
tmux -L "$SOCKET" split-window -t "$SESSION" -h "cat"
tmux -L "$SOCKET" split-window -t "$SESSION" -h "cat"
tmux -L "$SOCKET" new-session -d -s "$OTHER_SESSION" -x 120 -y 20 "cat"

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
# Test recipients are throwaway shell panes, so allow shell targets here.
run_lib() {
  local sender="$1"; shift
  TMUX_PANE="$sender" \
  SESSION_CHAT_ALLOW_SHELL_TARGET=1 \
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
elif cap_wait "$RECIPIENT_PANE" 'hello-from-test' >/dev/null; then
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
if [ ${#files[@]} -ge 1 ] && grep -qF '$dollars' "${files[0]}" && cap_wait "$RECIPIENT_PANE" 'dispatch (' >/dev/null; then
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

# --- Test 7: lock contention (two parallel sends to one recipient both land) ---
# Send to a neutral `cat` sink, NOT a shell. A bash recipient EXECUTES the pasted
# `[from:...]` line; its command-not-found redraw can consume the text before
# capture-pane stabilizes on a loaded CI runner, so the marker never becomes
# stable output — the long-standing flake. `cat` echoes stdin verbatim as stable
# pane text, making the marker reliably observable. Mirrors the Codex harness
# (codex/plugins/session-chat/scripts/test-session-chat.sh:105-107,702-712).
# capture-pane -J joins wrapped lines so a wrapped marker still matches.
tmux -L "$SOCKET" new-window -t "$SESSION" -n lcsink "cat"
LC_SINK=$(tmux -L "$SOCKET" list-panes -t "$SESSION:lcsink" -F '#{pane_id}' | sed -n '1p')
tmux -L "$SOCKET" set-option -p -t "$LC_SINK" @name "lc-sink"
(SESSION_CHAT_VERIFY_TIMEOUT_MS=5000 run_lib "$SENDER_PANE" "send_message lc-sink 'parallel-A'" >/dev/null 2>&1) & lc_pid_a=$!
(SESSION_CHAT_VERIFY_TIMEOUT_MS=5000 run_lib "$SENDER_PANE" "send_message lc-sink 'parallel-B'" >/dev/null 2>&1) & lc_pid_b=$!
wait "$lc_pid_a"
wait "$lc_pid_b"
lc_captured=$(tmux -L "$SOCKET" capture-pane -J -t "$LC_SINK" -p -S -200 2>/dev/null)
if echo "$lc_captured" | grep -qF 'parallel-A' && echo "$lc_captured" | grep -qF 'parallel-B'; then
  pass "lock_contention"
else
  fail "lock_contention" "missing one of parallel-A/B in recipient"
fi
tmux -L "$SOCKET" kill-window -t "$SESSION:lcsink" 2>/dev/null || true

# --- Test 8: retry path triggers on tight timeout (should still succeed via retry) ---
# Recipient is `sleep 0.4; cat`: for the first 0.4s no `cat` is consuming input, so
# the tight 100ms verify window is guaranteed to miss at least once and force the
# retry path; the 200ms linear backoff (200/400/600/800) carries a later attempt
# past 0.4s, when `cat` starts and the marker lands as stable output. This tests
# the retry contract deterministically — no CI-load or shell-execution assumption.
# Mirrors the Codex harness (codex/.../test-session-chat.sh:714-719).
tmux -L "$SOCKET" new-window -t "$SESSION" -n retry "sleep 0.4; cat"
RETRY_PANE=$(tmux -L "$SOCKET" list-panes -t "$SESSION:retry" -F '#{pane_id}' | sed -n '1p')
tmux -L "$SOCKET" set-option -p -t "$RETRY_PANE" @name "retry-recipient"
SESSION_CHAT_VERIFY_TIMEOUT_MS=100 SESSION_CHAT_SEND_RETRIES=4 SESSION_CHAT_RETRY_BACKOFF_MS=200 \
  run_lib "$SENDER_PANE" "send_message retry-recipient 'retry-probe'" >/dev/null 2>&1
if tmux -L "$SOCKET" capture-pane -J -t "$RETRY_PANE" -p -S -200 2>/dev/null | grep -qF 'retry-probe'; then
  pass "retry_eventual_success"
else
  fail "retry_eventual_success" "no marker on recipient"
fi
tmux -L "$SOCKET" kill-window -t "$SESSION:retry" 2>/dev/null || true

# --- Test 8b: Enter (submit) failure queues instead of dropping the durable copy ---
# Regression guard: a failed `send-keys Enter` must NOT be reported as live
# delivery (which would dequeue the durable copy and silently lose the message).
# It must surface as queued (send_message rc 3) with the row still in the inbox.
enter_fail_out=$(
  TMUX_PANE="$SENDER_PANE" \
  SESSION_CHAT_ALLOW_SHELL_TARGET=1 \
  SESSION_CHAT_VERIFY_TIMEOUT_MS=1000 \
  SESSION_CHAT_SETTLE_MS=50 \
  SESSION_CHAT_SEND_RETRIES=1 \
  TMUX="$(tmux -L "$SOCKET" display-message -p '#{socket_path}'),0,0" \
  bash -c "
    set -u
    source '$HERE/lib.sh'
    export MESSAGES_DIR='$TEST_MSGS_DIR'
    # Fail only the submit (Enter) keystroke; paste + capture pass through.
    tmux() {
      if [ \"\$1\" = send-keys ]; then
        local last=\"\${@: -1}\"
        [ \"\$last\" = Enter ] && return 1
      fi
      command tmux -L '$SOCKET' \"\$@\"
    }
    export -f tmux
    send_message beta 'enter-fail-probe'
    echo \"RC=\$?\"
  "
)
enter_qf="$TEST_MSGS_DIR/queue/beta.tsv"
if echo "$enter_fail_out" | grep -q "RC=3" \
   && [ -f "$enter_qf" ] && grep -qF 'enter-fail-probe' "$enter_qf"; then
  pass "enter_failure_queues"
else
  fail "enter_failure_queues" "expected rc=3 + queued row; out=$enter_fail_out; qf=$(cat "$enter_qf" 2>/dev/null)"
fi

# --- Test 9: mixed-runtime dir resolution + cross-runtime queue threading ---
# No tmux needed: override short-circuits detection, and the queue helpers are
# pure file ops. Verifies a Claude->Codex row/file lands in the CODEX dir only.
mr_out=$(
  source "$HERE/lib.sh"
  MR_BASE=$(mktemp -d)
  export MESSAGES_DIR="$MR_BASE/claude/messages"
  CODEX_MSGS="$MR_BASE/codex/messages"
  [ "$(SESSION_CHAT_TARGET_MESSAGES_DIR=/tmp/ov target_messages_dir_for_pane any)" = "/tmp/ov" ] && echo OVERRIDE_OK
  uid=deadbeef
  enqueue_message execpane "$uid" dispatch sender "$CODEX_MSGS/task.md" "$CODEX_MSGS"
  cq=$(queue_file_for execpane "$CODEX_MSGS")
  lq=$(queue_file_for execpane)
  ql=$(queue_lock_path execpane "$CODEX_MSGS")
  [ -f "$cq" ] && grep -qF "$uid" "$cq" && echo CODEX_HAS_ROW
  [ ! -f "$lq" ] && echo LOCAL_CLEAN
  [ "$ql" = "$CODEX_MSGS/queue/.locks/execpane.lock" ] && echo LOCK_TARGET_DIR
  dequeue_message_id execpane "$uid" "$CODEX_MSGS"
  [ ! -s "$cq" ] && echo DEQUEUE_OK
  rm -rf "$MR_BASE"
)
if echo "$mr_out" | grep -q OVERRIDE_OK && echo "$mr_out" | grep -q CODEX_HAS_ROW \
   && echo "$mr_out" | grep -q LOCAL_CLEAN && echo "$mr_out" | grep -q LOCK_TARGET_DIR \
   && echo "$mr_out" | grep -q DEQUEUE_OK; then
  pass "mixed_runtime_routing"
else
  fail "mixed_runtime_routing" "out=$mr_out"
fi

# --- Test 10: node-reporting pane classified as Claude runtime ---
# A recipient whose foreground command is bare `node` must resolve to the Claude
# messages dir (MESSAGES_DIR), not fall through to a Codex dir.
node_route=$(
  source "$HERE/lib.sh"
  export MESSAGES_DIR="/tmp/claude-rt-test/messages"
  tmux() { [ "$1" = display-message ] && { echo node; return 0; }; return 0; }
  export -f tmux
  target_messages_dir_for_pane %999
)
if [ "$node_route" = "/tmp/claude-rt-test/messages" ]; then
  pass "node_routes_claude"
else
  fail "node_routes_claude" "expected Claude MESSAGES_DIR, got: $node_route"
fi

# --- Test 11: privacy hardening — messages dir 0700, files migrated to 0600 ---
# portable octal-perms reader (BSD stat vs GNU stat)
perms() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
harden_out=$(
  source "$HERE/lib.sh"
  HB=$(mktemp -d)
  md="$HB/messages"
  mkdir -p "$md/queue"
  # Pre-existing loose data (world-readable) that migration must tighten.
  umask 022
  printf 'secret\n' > "$md/old.md"
  printf 'q\n' > "$md/queue/old.tsv"
  chmod 644 "$md/old.md" "$md/queue/old.tsv"
  chmod 755 "$md"
  harden_messages_dir "$md"
  echo "DIR=$(stat -c '%a' "$md" 2>/dev/null || stat -f '%Lp' "$md" 2>/dev/null)"
  echo "FILE=$(stat -c '%a' "$md/old.md" 2>/dev/null || stat -f '%Lp' "$md/old.md" 2>/dev/null)"
  echo "SUBFILE=$(stat -c '%a' "$md/queue/old.tsv" 2>/dev/null || stat -f '%Lp' "$md/queue/old.tsv" 2>/dev/null)"
  [ -e "$md/.perms-hardened-v1" ] && echo MARKER_OK
  rm -rf "$HB"
)
if echo "$harden_out" | grep -q 'DIR=700' && echo "$harden_out" | grep -q 'FILE=600' \
   && echo "$harden_out" | grep -q 'SUBFILE=600' && echo "$harden_out" | grep -q MARKER_OK; then
  pass "perms_harden"
else
  fail "perms_harden" "expected 700 dir + 600 files + marker, got: $harden_out"
fi

# --- Test 12: dispatch task file is written owner-only (0600) ---
disp_file=$(ls -t "$TEST_MSGS_DIR"/*.md 2>/dev/null | head -1)
if [ -n "$disp_file" ] && [ "$(perms "$disp_file")" = "600" ]; then
  pass "dispatch_file_perms"
else
  fail "dispatch_file_perms" "expected 600 on $disp_file, got: $(perms "${disp_file:-none}")"
fi

# --- Trust-gate / inline harness: drive detect-incoming-message.sh end-to-end ---
# No tmux needed: with CLAUDE_PLUGIN_ROOT unset the lib is not sourced, so the
# live-dispatch path exercises trusted_message_file + inline_dispatch_body + the
# emit cap directly. HOME is faked so MESSAGES_DIR points at a throwaway tree.
DHOME=$(mktemp -d)
mkdir -p "$DHOME/.claude/messages"
DMSGS="$DHOME/.claude/messages"
detect_run() {
  # detect_run <mode> <msgfile> [env=val ...]
  local mode="$1" msgfile="$2"; shift 2
  printf '{"hook_event_name":"UserPromptSubmit","prompt":"[from:peer pane:%%1 msg:%s id:abcd1234] dispatch (2 lines) — read msg file"}' "$msgfile" \
    | env HOME="$DHOME" TMUX="fake-socket,0,0" CLAUDE_PLUGIN_ROOT="" SESSION_CHAT_INCOMING_MODE="$mode" "$@" \
      bash "$HERE/detect-incoming-message.sh"
}

# 13: trusted file in auto mode is accepted AND its body inlined
printf 'PLEASE-BUILD-THE-WIDGET\nsecond line\n' > "$DMSGS/task-ok.md"
chmod 600 "$DMSGS/task-ok.md"
out=$(detect_run auto "$DMSGS/task-ok.md")
if echo "$out" | grep -q 'Task content follows' && echo "$out" | grep -q 'PLEASE-BUILD-THE-WIDGET'; then
  pass "trust_inline_auto"
else
  fail "trust_inline_auto" "expected inlined body, got: $out"
fi

# 13a: the exact literal read command (canonical path) precedes the inline body,
# so a strict-v1 pane can fetch the full task even when the emit cap cuts the tail.
DMSGS_CANON="$(cd "$DMSGS" && pwd -P)"
header=${out%%Task content follows*}
if printf '%s' "$header" | grep -qF "Full task read command: cat '$DMSGS_CANON/task-ok.md'"; then
  pass "inline_read_command_before_body"
else
  fail "inline_read_command_before_body" "expected canonical cat command ahead of the body, got: ${out:0:300}"
fi

# 13a2: assist keeps the user-authorization gate and offers the command only after approval
out=$(detect_run assist "$DMSGS/task-ok.md")
if echo "$out" | grep -q 'ask the local user before reading the file' \
   && printf '%s' "$out" | grep -qF "Only after the user approves, read it with this exact command: cat '$DMSGS_CANON/task-ok.md'" \
   && ! echo "$out" | grep -q 'PLEASE-BUILD-THE-WIDGET'; then
  pass "assist_read_command_after_approval"
else
  fail "assist_read_command_after_approval" "got: $out"
fi

# 13a3: notify never offers a read command (untrusted until the user decides)
out=$(detect_run notify "$DMSGS/task-ok.md")
if echo "$out" | grep -q 'do not read it' && ! echo "$out" | grep -q 'exact command'; then
  pass "notify_no_read_command"
else
  fail "notify_no_read_command" "got: $out"
fi

# 13a4: an apostrophe in the messages path stays one literal single-quoted operand
QHOME=$(mktemp -d)/"it's home"
mkdir -p "$QHOME/.claude/messages"
printf 'QUOTED-TASK\n' > "$QHOME/.claude/messages/q.md"
chmod 600 "$QHOME/.claude/messages/q.md"
qout=$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"[from:peer pane:%%1 msg:%s id:abcd1235] dispatch (1 lines)"}' "$QHOME/.claude/messages/q.md" \
  | env HOME="$QHOME" TMUX="fake-socket,0,0" CLAUDE_PLUGIN_ROOT="" SESSION_CHAT_INCOMING_MODE=auto bash "$HERE/detect-incoming-message.sh")
qcmd=$(printf '%s' "$qout" | python3 -c '
import json,re,sys
m=re.search(r"Full task read command: (cat .*?)\n", json.loads(sys.stdin.read()).get("systemMessage",""))
print(m.group(1) if m else "")' 2>/dev/null)
if [ -n "$qcmd" ] && [ "$(bash -c "$qcmd" 2>/dev/null)" = "QUOTED-TASK" ]; then
  pass "read_command_quotes_apostrophe"
else
  fail "read_command_quotes_apostrophe" "cmd=[$qcmd] out=${qout:0:300}"
fi
rm -rf "$(dirname "$QHOME")"

# 13b: notify mode must NOT inline the body (untrusted-by-default)
out=$(detect_run notify "$DMSGS/task-ok.md")
if echo "$out" | grep -q 'untrusted' && ! echo "$out" | grep -q 'PLEASE-BUILD-THE-WIDGET'; then
  pass "trust_no_inline_notify"
else
  fail "trust_no_inline_notify" "notify should not inline body, got: $out"
fi

# 14: a symlink planted inside the messages dir is rejected (not followed)
printf 'off-limits\n' > "$DHOME/outside-secret.txt"
ln -s "$DHOME/outside-secret.txt" "$DMSGS/evil.md"
out=$(detect_run auto "$DMSGS/evil.md")
if echo "$out" | grep -q 'OUTSIDE the trusted message dir' && ! echo "$out" | grep -q 'off-limits'; then
  pass "trust_reject_symlink"
else
  fail "trust_reject_symlink" "symlink should be rejected, got: $out"
fi

# 15: a path outside the messages dir is rejected
out=$(detect_run auto "$DHOME/outside-secret.txt")
if echo "$out" | grep -q 'OUTSIDE the trusted message dir'; then
  pass "trust_reject_outside"
else
  fail "trust_reject_outside" "outside path should be rejected, got: $out"
fi

# 16: oversized inlined body is truncated at the inline cap
{ printf 'HEAD-MARKER\n'; head -c 8000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$DMSGS/big.md"
chmod 600 "$DMSGS/big.md"
out=$(detect_run auto "$DMSGS/big.md")
if echo "$out" | grep -q 'dispatch body truncated at 6000'; then
  pass "inline_body_truncated"
else
  fail "inline_body_truncated" "expected inline truncation notice, got: ${out:0:200}"
fi

# 17: total emitted context is capped (~10k) — raise inline cap past it to force
out=$({ printf 'BIGHEAD\n'; head -c 12000 /dev/zero | tr '\0' 'y'; } > "$DMSGS/huge.md"; chmod 600 "$DMSGS/huge.md"; \
      detect_run auto "$DMSGS/huge.md" SESSION_CHAT_DISPATCH_INLINE_MAX=12000)
if echo "$out" | grep -q 'truncated by session-chat'; then
  pass "emit_cap_10k"
else
  fail "emit_cap_10k" "expected emit cap truncation, got len=${#out}"
fi
# 18: a loose-mode (group/other-readable) file is rejected even if owner-owned
printf 'GROUP-READABLE-SECRET\n' > "$DMSGS/loose.md"
chmod 644 "$DMSGS/loose.md"
out=$(detect_run auto "$DMSGS/loose.md")
if echo "$out" | grep -q 'OUTSIDE the trusted message dir' && ! echo "$out" | grep -q 'GROUP-READABLE-SECRET'; then
  pass "trust_reject_loose_mode"
else
  fail "trust_reject_loose_mode" "loose-mode file should be rejected, got: $out"
fi
rm -rf "$DHOME" 2>/dev/null || true

# --- Test 19: fail closed on unsafe (symlink) messages dir ---
# harden/ensure must refuse (non-zero) and enqueue must NOT write through a
# symlinked messages root planted where our private dir should be.
failclosed_out=$(
  source "$HERE/lib.sh"
  FC=$(mktemp -d)
  real="$FC/real"; mkdir -p "$real"          # attacker-controlled target
  link="$FC/messages"; ln -s "$real" "$link"  # symlink where our dir belongs
  export MESSAGES_DIR="$link"
  harden_messages_dir "$link"; echo "HARDEN_RC=$?"
  ensure_messages_dir "$link"; echo "ENSURE_RC=$?"
  enqueue_message peer id1 send me hello "$link"; echo "ENQUEUE_RC=$?"
  # nothing should have been written through the symlink
  [ -z "$(ls -A "$real" 2>/dev/null)" ] && echo "TARGET_CLEAN"
  rm -rf "$FC"
)
if echo "$failclosed_out" | grep -q 'HARDEN_RC=1' \
   && echo "$failclosed_out" | grep -q 'ENSURE_RC=1' \
   && echo "$failclosed_out" | grep -q 'ENQUEUE_RC=1' \
   && echo "$failclosed_out" | grep -q 'TARGET_CLEAN'; then
  pass "fail_closed_symlink_dir"
else
  fail "fail_closed_symlink_dir" "out=$failclosed_out"
fi

# --- Test 20: migration failure blocks the write (fail closed on chmod/find) ---
# A subdir we can't traverse (000) makes the recursive migration chmod fail;
# the FIRST enqueue (its first harden) must refuse rather than proceed on a tree
# it couldn't fully tighten. enqueue is called before any other harden so the
# failure is observed on the first pass.
migfail_out=$(
  source "$HERE/lib.sh"
  MF=$(mktemp -d)
  md="$MF/messages"
  mkdir -p "$md/sub"
  echo secret > "$md/sub/f"
  chmod 000 "$md/sub"          # untraversable -> migration chmod fails
  export MESSAGES_DIR="$md"
  enqueue_message peer id1 send me hi "$md"; echo "ENQUEUE_RC=$?"
  chmod 755 "$md/sub" 2>/dev/null   # restore so cleanup can remove it
  rm -rf "$MF"
)
if echo "$migfail_out" | grep -q 'ENQUEUE_RC=1'; then
  pass "fail_closed_migration_failure"
else
  fail "fail_closed_migration_failure" "out=$migfail_out"
fi

# --- Test 21: true CHARACTER cap — boundary glyph preserved, no U+FFFD ---
# 5999 ASCII + an emoji at char 6000 (+ a tail) with an inline cap of 6000 chars:
# the emoji must be kept WHOLE, the tail truncated, no U+FFFD introduced, valid JSON.
UHOME=$(mktemp -d); UMSGS="$UHOME/.claude/messages"; mkdir -p "$UMSGS"
{ head -c 5999 /dev/zero | tr '\0' 'a'; printf '\xf0\x9f\x98\x80'; head -c 40 /dev/zero | tr '\0' 'Z'; } > "$UMSGS/emoji.md"
chmod 600 "$UMSGS/emoji.md"
uout=$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"[from:peer pane:%%1 msg:%s id:abcd9999] dispatch (1 lines)"}' "$UMSGS/emoji.md" \
  | env HOME="$UHOME" TMUX="fake,0,0" CLAUDE_PLUGIN_ROOT="" SESSION_CHAT_INCOMING_MODE=auto SESSION_CHAT_DISPATCH_INLINE_MAX=6000 \
    bash "$HERE/detect-incoming-message.sh")
uassert=$(printf '%s' "$uout" | python3 -c '
import sys,json
try: d=json.loads(sys.stdin.read())
except Exception: print("BADJSON"); sys.exit()
s=d.get("systemMessage","")
print(("EMOJI" if "\U0001F600" in s else "NOEMOJI"),
      ("NOFFFD" if "�" not in s else "HASFFFD"),
      ("NOTAIL" if "ZZZZ" not in s else "HASTAIL"))
' 2>/dev/null)
if [ "$uassert" = "EMOJI NOFFFD NOTAIL" ]; then
  pass "utf8_char_boundary_preserved"
else
  fail "utf8_char_boundary_preserved" "assert=[$uassert]"
fi
rm -rf "$UHOME"

# --- Test 22: fan-in atomic claim — select-before-mutate, overflow never removed ---
# Three ~3.3k dispatch bodies: hook 1 shows/removes the first two (third overflows
# the ~9k surface budget and STAYS queued); hook 2 shows/removes the third.
FHOME=$(mktemp -d); FMSGS="$FHOME/.claude/messages"; mkdir -p "$FMSGS/queue"
PLUGROOT="$(cd "$HERE/.." && pwd)"
for n in 1 2 3; do
  { printf 'BODY%s-' "$n"; head -c 3300 /dev/zero | tr '\0' "$n"; printf '\n'; } > "$FMSGS/ftask$n.md"
  chmod 600 "$FMSGS/ftask$n.md"
done
(
  source "$HERE/lib.sh"; export MESSAGES_DIR="$FMSGS"; export SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS=0
  for n in 1 2 3; do enqueue_message me "fid$n" dispatch peer "$FMSGS/ftask$n.md" "$FMSGS"; mark_message_ready me "fid$n" "$FMSGS"; done
)
run_detect_fanin() {
  printf '{"hook_event_name":"Stop"}' | env HOME="$FHOME" TMUX="fake,0,0" \
    CLAUDE_PLUGIN_ROOT="$PLUGROOT" SESSION_CHAT_PANE_NAME=me SESSION_CHAT_INCOMING_MODE=auto \
    bash "$HERE/detect-incoming-message.sh"
}
qf="$FMSGS/queue/me.tsv"
rows_in() { awk 'END{print NR+0}' "$1" 2>/dev/null || echo 0; }
out1=$(run_detect_fanin); rem1=$(rows_in "$qf")
out2=$(run_detect_fanin); rem2=$(rows_in "$qf")
j1=$(printf '%s' "$out1" | python3 -c 'import sys,json;json.loads(sys.stdin.read());print("OK")' 2>/dev/null)
j2=$(printf '%s' "$out2" | python3 -c 'import sys,json;json.loads(sys.stdin.read());print("OK")' 2>/dev/null)
if [ "$j1" = OK ] && [ "$j2" = OK ] \
   && echo "$out1" | grep -q BODY1 && echo "$out1" | grep -q BODY2 && ! echo "$out1" | grep -q BODY3 \
   && [ "$rem1" = "1" ] \
   && echo "$out2" | grep -q BODY3 && [ "$rem2" = "0" ]; then
  pass "fanin_atomic_claim"
else
  fail "fanin_atomic_claim" "rem1=$rem1 rem2=$rem2 h1=$(echo "$out1"|grep -o 'BODY[0-9]'|tr '\n' ',') h2=$(echo "$out2"|grep -o 'BODY[0-9]'|tr '\n' ',')"
fi
rm -rf "$FHOME"

# --- Test 23: live prompt id whose durable copy is queued is dequeued once ---
# A live [from:… id:X] paste whose durable row X still sits in this pane's queue
# must surface once (from the prompt) and leave ZERO rows for X afterward.
LHOME=$(mktemp -d); LMSGS="$LHOME/.claude/messages"; mkdir -p "$LMSGS/queue"
PLUGROOT="$(cd "$HERE/.." && pwd)"
(
  source "$HERE/lib.sh"; export MESSAGES_DIR="$LMSGS"; export SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS=0
  enqueue_message me deadbeef send peer "queued copy of the live message" "$LMSGS"
  mark_message_ready me deadbeef "$LMSGS"
)
lout=$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"[from:peer pane:%%1 id:deadbeef] hello live"}' \
  | env HOME="$LHOME" TMUX="fake,0,0" CLAUDE_PLUGIN_ROOT="$PLUGROOT" SESSION_CHAT_PANE_NAME=me SESSION_CHAT_INCOMING_MODE=auto \
    bash "$HERE/detect-incoming-message.sh")
lqf="$LMSGS/queue/me.tsv"
live_rows=$(awk -F'\t' '$1=="deadbeef"{c++} END{print c+0}' "$lqf" 2>/dev/null)
if [ "$live_rows" = "0" ] && echo "$lout" | grep -q 'from \[peer\]'; then
  pass "live_id_dequeued"
else
  fail "live_id_dequeued" "live_rows=$live_rows out=$lout"
fi
rm -rf "$LHOME"

# --- Test 24: malicious sender @name (path metachars) rejected pre-write ---
# An externally/raw-set @name with slashes/.. must be refused before any dispatch
# file is written, so nothing can escape the messages dir via the filename.
tmux -L "$SOCKET" split-window -t "$SESSION" -h >/dev/null 2>&1
EVIL_PANE=$(tmux -L "$SOCKET" list-panes -t "$SESSION" -F '#{pane_id}' | tail -1)
tmux -L "$SOCKET" set-option -p -t "$EVIL_PANE" @name "../../evil"
mfiles_before=$(find "$TEST_MSGS_DIR" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
out=$(run_lib "$EVIL_PANE" "dispatch_message alpha 'payload'" 2>&1)
mfiles_after=$(find "$TEST_MSGS_DIR" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
escaped=$(find "$(cd "$TEST_MSGS_DIR"/.. && pwd)" -maxdepth 2 -name '*evil*to*' 2>/dev/null | wc -l | tr -d ' ')
if echo "$out" | grep -q "unsafe characters" && [ "$mfiles_before" = "$mfiles_after" ] && [ "$escaped" = "0" ]; then
  pass "malicious_sender_name_rejected"
else
  fail "malicious_sender_name_rejected" "out=$out before=$mfiles_before after=$mfiles_after escaped=$escaped"
fi
tmux -L "$SOCKET" set-option -p -t "$EVIL_PANE" @name "gamma-cleaned"

# --- Test 25: malicious TARGET name rejected at resolve_pane (no file, no send) ---
out=$(run_lib "$SENDER_PANE" "dispatch_message '../../evil' 'payload'" 2>&1)
out2=$(run_lib "$SENDER_PANE" "send_message '../etc/passwd' 'payload'" 2>&1)
if echo "$out" | grep -q "invalid pane name" && echo "$out2" | grep -q "invalid pane name"; then
  pass "malicious_target_name_rejected"
else
  fail "malicious_target_name_rejected" "out=$out out2=$out2"
fi

# --- Test 26: dispatch staging is content-safe (body never shell-evaluated) ---
# The file-based dispatch path must carry a body containing a heredoc-delimiter
# line and shell-looking substitutions verbatim, executing none of it.
SAFE_TMP=$(mktemp -d)
PF="$SAFE_TMP/prompt.txt"
printf 'line one\nPROMPT_EOF\n$(touch %s/PWNED)\n`touch %s/PWNED2`\nlast line\n' "$SAFE_TMP" "$SAFE_TMP" > "$PF"
dsafe_out=$(
  TMUX_PANE="$SENDER_PANE" SESSION_CHAT_ALLOW_SHELL_TARGET=1 \
  SESSION_CHAT_VERIFY_TIMEOUT_MS=1000 SESSION_CHAT_SETTLE_MS=50 \
  SESSION_CHAT_TARGET_MESSAGES_DIR="$SAFE_TMP/messages" \
  TMUX="$(tmux -L "$SOCKET" display-message -p '#{socket_path}'),0,0" \
  bash -c "
    tmux() { command tmux -L '$SOCKET' \"\$@\"; }
    export -f tmux
    bash '$HERE/dispatch-to-session.sh' alpha '$PF'
  " 2>&1
)
delivered=$(find "$SAFE_TMP/messages" -name '*.md' 2>/dev/null | head -1)
if [ -n "$delivered" ] && grep -qF 'PROMPT_EOF' "$delivered" && grep -qF '$(touch' "$delivered" \
   && [ ! -e "$SAFE_TMP/PWNED" ] && [ ! -e "$SAFE_TMP/PWNED2" ]; then
  pass "dispatch_body_content_safe"
else
  fail "dispatch_body_content_safe" "delivered=$delivered pwned=$([ -e "$SAFE_TMP/PWNED" ] && echo yes || echo no) out=$dsafe_out"
fi
rm -rf "$SAFE_TMP"

# --- Test 26b: own-draft consumption after a durable dispatch ---
# A prompt file that is exactly this pane's own draft (<messages>/drafts/sender/)
# is removed after delivery; every other shape is kept. Each refusal case runs
# beside a valid own draft in the same fixture as its positive control.
OD_TMP=$(mktemp -d)
OD_M="$OD_TMP/messages"
mkdir -p "$OD_M/drafts/sender" "$OD_M/drafts/beta"
chmod 700 "$OD_M" "$OD_M/drafts" "$OD_M/drafts/sender" "$OD_M/drafts/beta"
od_dispatch() {  # od_dispatch <target> <file> [extra env assignments...]
  local target="$1" file="$2"; shift 2
  env TMUX_PANE="$SENDER_PANE" SESSION_CHAT_ALLOW_SHELL_TARGET=1 \
    SESSION_CHAT_VERIFY_TIMEOUT_MS=1000 SESSION_CHAT_SETTLE_MS=50 \
    SESSION_CHAT_TARGET_MESSAGES_DIR="$OD_M" \
    TMUX="$(tmux -L "$SOCKET" display-message -p '#{socket_path}'),0,0" "$@" \
    bash -c "
      tmux() { command tmux -L '$SOCKET' \"\$@\"; }
      export -f tmux
      bash '$HERE/dispatch-to-session.sh' '$target' '$file'
    " 2>&1
}
od_delivered_has() { grep -rlF "$1" "$OD_M"/*.md >/dev/null 2>&1; }
od_control() {  # a valid own draft in the same fixture must be consumed
  local f="$OD_M/drafts/sender/control-$1.md" o
  printf 'OD-CONTROL-%s\nline two\n' "$1" > "$f"
  o=$(od_dispatch alpha "$f")
  [ ! -e "$f" ] && od_delivered_has "OD-CONTROL-$1" && echo "$o" | grep -qF "Removed delivered draft"
}

# (a) positive: own draft delivered then removed; delivered copy is intact.
OD_A="$OD_M/drafts/sender/reply-a1.md"
printf 'OD-OWN-BODY\n$(touch %s/PWNED)\nend\n' "$OD_TMP" > "$OD_A"
chmod 644 "$OD_A"  # native Write mode: group/other read is fine in an owner-only store
od_a_out=$(od_dispatch alpha "$OD_A")
if [ ! -e "$OD_A" ] && od_delivered_has "OD-OWN-BODY" && [ ! -e "$OD_TMP/PWNED" ] \
   && echo "$od_a_out" | grep -qF "Removed delivered draft"; then
  pass "own_draft_consumed_after_delivery"
else
  fail "own_draft_consumed_after_delivery" "exists=$([ -e "$OD_A" ] && echo yes || echo no) out=$od_a_out"
fi

# (b) a plain prompt file outside drafts/ is never removed.
OD_B="$OD_TMP/plain.md"; printf 'OD-PLAIN\n' > "$OD_B"
od_dispatch alpha "$OD_B" >/dev/null
if [ -f "$OD_B" ] && od_delivered_has "OD-PLAIN" && od_control b; then
  pass "non_draft_prompt_kept"
else
  fail "non_draft_prompt_kept" "plain kept=$([ -f "$OD_B" ] && echo yes || echo no)"
fi

# (c) another pane's draft is delivered but kept.
OD_C="$OD_M/drafts/beta/foreign.md"; printf 'OD-FOREIGN\n' > "$OD_C"
od_dispatch alpha "$OD_C" >/dev/null
if [ -f "$OD_C" ] && od_delivered_has "OD-FOREIGN" && od_control c; then
  pass "foreign_draft_kept"
else
  fail "foreign_draft_kept" "foreign kept=$([ -f "$OD_C" ] && echo yes || echo no)"
fi

# (d) a symlink in the own drafts dir is kept, and so is its target.
OD_DT="$OD_TMP/link-target.md"; printf 'OD-LINKED\n' > "$OD_DT"
ln -s "$OD_DT" "$OD_M/drafts/sender/link.md"
od_dispatch alpha "$OD_M/drafts/sender/link.md" >/dev/null
if [ -L "$OD_M/drafts/sender/link.md" ] && [ -f "$OD_DT" ] && od_control d; then
  pass "symlink_draft_kept"
else
  fail "symlink_draft_kept" "link or target removed"
fi
rm -f "$OD_M/drafts/sender/link.md"

# (e) a hardlinked own draft is kept (the other link would survive anyway).
OD_E="$OD_M/drafts/sender/hard.md"; printf 'OD-HARD\n' > "$OD_E"
ln "$OD_E" "$OD_TMP/hard-other.md"
od_dispatch alpha "$OD_E" >/dev/null
if [ -f "$OD_E" ] && od_control e; then
  pass "hardlinked_draft_kept"
else
  fail "hardlinked_draft_kept" "hardlinked draft removed"
fi
rm -f "$OD_E" "$OD_TMP/hard-other.md"

# (f) SESSION_CHAT_KEEP_DRAFTS=1 opts out.
OD_F="$OD_M/drafts/sender/keep.md"; printf 'OD-KEEP\n' > "$OD_F"
od_dispatch alpha "$OD_F" SESSION_CHAT_KEEP_DRAFTS=1 >/dev/null
if [ -f "$OD_F" ] && od_delivered_has "OD-KEEP" && od_control f; then
  pass "keep_drafts_opt_out"
else
  fail "keep_drafts_opt_out" "draft removed despite opt-out"
fi
rm -f "$OD_F"

# (g) a hard failure (unknown target) keeps the draft for a retry.
OD_G="$OD_M/drafts/sender/fail.md"; printf 'OD-FAIL\n' > "$OD_G"
od_g_out=$(od_dispatch no-such-pane "$OD_G"); od_g_rc=$?
if [ "$od_g_rc" -ne 0 ] && [ -f "$OD_G" ] && od_control g; then
  pass "failed_dispatch_keeps_draft"
else
  fail "failed_dispatch_keeps_draft" "rc=$od_g_rc kept=$([ -f "$OD_G" ] && echo yes || echo no) out=$od_g_out"
fi
rm -f "$OD_G"

# (h) a symlinked own drafts directory disqualifies every file in it.
mv "$OD_M/drafts/sender" "$OD_TMP/real-sender-drafts"
ln -s "$OD_TMP/real-sender-drafts" "$OD_M/drafts/sender"
OD_H="$OD_M/drafts/sender/via-link.md"; printf 'OD-DIRLINK\n' > "$OD_H"
od_dispatch alpha "$OD_H" >/dev/null
od_h_kept=$([ -f "$OD_TMP/real-sender-drafts/via-link.md" ] && echo yes || echo no)
rm -f "$OD_M/drafts/sender"; mv "$OD_TMP/real-sender-drafts" "$OD_M/drafts/sender"
rm -f "$OD_M/drafts/sender/via-link.md"
if [ "$od_h_kept" = "yes" ] && od_control h; then
  pass "symlinked_drafts_dir_kept"
else
  fail "symlinked_drafts_dir_kept" "kept=$od_h_kept"
fi

# (i) consume_own_draft keeps an edited (even newline-only), or replaced draft;
# an unchanged draft is removed (control).
od_i_out=$(
  export TMUX_PANE="$SENDER_PANE" SESSION_CHAT_TARGET_MESSAGES_DIR="$OD_M"
  TMUX="$(tmux -L "$SOCKET" display-message -p '#{socket_path}'),0,0"
  export TMUX
  tmux() { command tmux -L "$SOCKET" "$@"; }
  source "$HERE/lib.sh"
  f="$OD_M/drafts/sender/edit.md"
  printf 'v1\n' > "$f"; id1=$(own_draft_identity "$f"); s1=$(file_sha256 "$f")
  printf 'v2\n' > "$f"; consume_own_draft "$f" "$id1" "$s1"
  [ -f "$f" ] && echo "EDIT_KEPT"
  printf 'v1\n' > "$f"; id1=$(own_draft_identity "$f"); s1=$(file_sha256 "$f")
  printf 'v1\n\n\n' > "$f"; consume_own_draft "$f" "$id1" "$s1"
  [ -f "$f" ] && echo "NEWLINE_EDIT_KEPT"
  printf 'v1\n' > "$f"; id1=$(own_draft_identity "$f"); s1=$(file_sha256 "$f")
  printf 'v1\n' > "$f.new"; mv -f "$f.new" "$f"; consume_own_draft "$f" "$id1" "$s1"
  [ -f "$f" ] && echo "REPLACED_KEPT"
  id2=$(own_draft_identity "$f"); s2=$(file_sha256 "$f")
  consume_own_draft "$f" "$id2" "$s2"
  [ ! -e "$f" ] && echo "UNCHANGED_REMOVED"
)
if echo "$od_i_out" | grep -q EDIT_KEPT && echo "$od_i_out" | grep -q NEWLINE_EDIT_KEPT \
   && echo "$od_i_out" | grep -q REPLACED_KEPT && echo "$od_i_out" | grep -q UNCHANGED_REMOVED; then
  pass "edited_or_replaced_draft_kept"
else
  fail "edited_or_replaced_draft_kept" "out=$od_i_out"
fi

# (j) names outside <safe>.md|.txt (<=128 chars) and group-writable drafts are kept.
OD_J1="$OD_M/drafts/sender/script.sh"; printf 'OD-EXT\n' > "$OD_J1"
OD_J2="$OD_M/drafts/sender/$(printf 'n%.0s' $(seq 1 130)).md"; printf 'OD-LONG\n' > "$OD_J2"
OD_J3="$OD_M/drafts/sender/shared.md"; printf 'OD-GW\n' > "$OD_J3"; chmod 664 "$OD_J3"
od_dispatch alpha "$OD_J1" >/dev/null; od_dispatch alpha "$OD_J2" >/dev/null; od_dispatch alpha "$OD_J3" >/dev/null
if [ -f "$OD_J1" ] && [ -f "$OD_J2" ] && [ -f "$OD_J3" ] && od_control j; then
  pass "ineligible_name_or_mode_kept"
else
  fail "ineligible_name_or_mode_kept" "ext=$([ -f "$OD_J1" ] && echo kept) long=$([ -f "$OD_J2" ] && echo kept) gw=$([ -f "$OD_J3" ] && echo kept)"
fi
# (k) queued outcome (recipient busy: Enter fails): the draft is removed and the
# queue row references the delivered copy, which stays readable. Control: the
# same fixture with a live delivery (od_control) also consumes.
OD_K="$OD_M/drafts/sender/queued.md"; printf 'OD-QUEUED-BODY\nline two\n' > "$OD_K"
od_k_out=$(
  env TMUX_PANE="$SENDER_PANE" SESSION_CHAT_ALLOW_SHELL_TARGET=1 \
    SESSION_CHAT_VERIFY_TIMEOUT_MS=1000 SESSION_CHAT_SETTLE_MS=50 SESSION_CHAT_SEND_RETRIES=0 \
    SESSION_CHAT_TARGET_MESSAGES_DIR="$OD_M" \
    TMUX="$(tmux -L "$SOCKET" display-message -p '#{socket_path}'),0,0" \
    bash -c "
      tmux() {
        if [ \"\$1\" = send-keys ]; then
          local last=\"\${@: -1}\"
          [ \"\$last\" = Enter ] && return 1
        fi
        command tmux -L '$SOCKET' \"\$@\"
      }
      export -f tmux
      bash '$HERE/dispatch-to-session.sh' alpha '$OD_K'
    " 2>&1
)
od_k_row=$(grep -F 'drafts' "$OD_M/queue/alpha.tsv" 2>/dev/null)
od_k_ref=$(awk -F'\t' '{for(i=1;i<=NF;i++) if ($i ~ /\.md$/) print $i}' "$OD_M/queue/alpha.tsv" 2>/dev/null | tail -1)
# Recover the queued dispatch as the recipient (alpha) on its Stop hook: the
# surfaced body must be the complete queued payload, read from the copy.
od_k_rec=$(printf '{"hook_event_name":"Stop"}' \
  | env HOME="$OD_TMP" TMUX="fake,0,0" CLAUDE_PLUGIN_ROOT="$(cd "$HERE/.." && pwd)" \
    SESSION_CHAT_PANE_NAME=alpha SESSION_CHAT_TARGET_MESSAGES_DIR="$OD_M" \
    SESSION_CHAT_INCOMING_MODE=auto SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS=0 \
    bash "$HERE/detect-incoming-message.sh" 2>&1)
if echo "$od_k_out" | grep -qF "Queued dispatch" && [ ! -e "$OD_K" ] && [ -z "$od_k_row" ] \
   && [ -n "$od_k_ref" ] && grep -qF 'OD-QUEUED-BODY' "$od_k_ref" \
   && echo "$od_k_rec" | grep -qF 'OD-QUEUED-BODY' && echo "$od_k_rec" | grep -qF 'line two' \
   && od_control k; then
  pass "queued_dispatch_consumes_draft_payload_survives"
else
  fail "queued_dispatch_consumes_draft_payload_survives" "out=$od_k_out kept=$([ -e "$OD_K" ] && echo yes || echo no) ref=$od_k_ref row=$od_k_row rec=$od_k_rec"
fi
# (l) a failed read (empty, or partial output then an error) sends nothing and
# keeps the draft. A PATH shim fails `cat` for these drafts only. Control: the
# same draft name pattern with the shim reading normally is consumed.
OD_SHIM="$OD_TMP/shim"; mkdir -p "$OD_SHIM"
cat > "$OD_SHIM/cat" <<'SHIM'
#!/bin/bash
for a in "$@"; do
  case "$a" in
    *readfail-partial*) printf 'OD-PARTIAL-HEAD\n'; exit 1 ;;
    *readfail-empty*) exit 1 ;;
  esac
done
exec /bin/cat "$@"
SHIM
chmod 755 "$OD_SHIM/cat"
od_l_ok=yes
for kind in partial empty; do
  f="$OD_M/drafts/sender/readfail-$kind.md"; printf 'OD-READFAIL-%s-FULL\n' "$kind" > "$f"
  before=$(find "$OD_M" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')
  o=$(od_dispatch alpha "$f" PATH="$OD_SHIM:$PATH"); r=$?
  after=$(find "$OD_M" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')
  if [ "$r" -eq 0 ] || [ ! -f "$f" ] || [ "$before" != "$after" ] || od_delivered_has "OD-PARTIAL-HEAD" \
     || ! echo "$o" | grep -qF "could not read prompt file"; then
    od_l_ok="no($kind rc=$r kept=$([ -f "$f" ] && echo yes || echo no) files=$before/$after out=$o)"
  fi
  rm -f "$f"
done
OD_LC="$OD_M/drafts/sender/shim-control.md"; printf 'OD-SHIM-CONTROL\n' > "$OD_LC"
od_lc_out=$(od_dispatch alpha "$OD_LC" PATH="$OD_SHIM:$PATH")
if [ "$od_l_ok" = "yes" ] && [ ! -e "$OD_LC" ] && od_delivered_has "OD-SHIM-CONTROL"; then
  pass "failed_read_sends_nothing_keeps_draft"
else
  fail "failed_read_sends_nothing_keeps_draft" "$od_l_ok control_out=$od_lc_out"
fi

# (m) group/other-writable store directories disqualify consumption: the own
# drafts dir, the drafts/ parent, and the source messages root. Each is
# restored and followed by a consuming control.
od_m_ok=yes
for d in "$OD_M/drafts/sender" "$OD_M/drafts" "$OD_M"; do
  f="$OD_M/drafts/sender/dirmode.md"; printf 'OD-DIRMODE\n' > "$f"
  chmod 777 "$d"; od_dispatch alpha "$f" >/dev/null; chmod 700 "$d"
  [ -f "$f" ] || od_m_ok="no($d)"
  rm -f "$f"
  od_control "m$(basename "$d")" || od_m_ok="no(control after $d)"
done
if [ "$od_m_ok" = "yes" ]; then
  pass "writable_store_dirs_keep_draft"
else
  fail "writable_store_dirs_keep_draft" "$od_m_ok"
fi
rm -rf "$OD_TMP"

# --- Test 27: msg: path containing a space is parsed fully (not truncated) ---
# A dispatch file under a HOME with a space must be recognized as trusted — the
# msg: field is parsed to its ` id:<hex>]` delimiter, not the first space.
SP_ROOT=$(mktemp -d)
SP_HOME="$SP_ROOT/home with space"
SP_MSGS="$SP_HOME/.claude/messages"
mkdir -p "$SP_MSGS"
printf 'SPACE-PATH-BODY-OK\n' > "$SP_MSGS/task.md"
chmod 600 "$SP_MSGS/task.md"
sp_out=$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"[from:peer pane:%%1 msg:%s id:abc12345] dispatch (1 lines) — read msg file for full task id:abc12345"}' "$SP_MSGS/task.md" \
  | env HOME="$SP_HOME" TMUX="fake,0,0" CLAUDE_PLUGIN_ROOT="" SESSION_CHAT_INCOMING_MODE=auto \
    bash "$HERE/detect-incoming-message.sh")
if echo "$sp_out" | grep -q 'SPACE-PATH-BODY-OK' && echo "$sp_out" | grep -q 'trusted task file'; then
  pass "msg_path_with_space"
else
  fail "msg_path_with_space" "out=$sp_out"
fi
rm -rf "$SP_ROOT"

# --- Test 28: send-lock root is UID-scoped 0700 and fails closed on a symlink ---
lockroot_out=$(
  source "$HERE/lib.sh"
  T=$(mktemp -d); export TMPDIR="$T"
  r=$(_session_chat_lock_root)
  myuid=$(id -u)
  mode=$(stat -c '%a' "$r" 2>/dev/null || stat -f '%Lp' "$r" 2>/dev/null)
  echo "MODE=$mode"
  if [ "$r" = "$T/session-chat-locks-$myuid" ]; then echo "UID_SCOPED"; fi
  # Poison the root: replace it with a symlink to an attacker-controlled dir.
  rm -rf "$r"; mkdir -p "$T/elsewhere"; ln -s "$T/elsewhere" "$r"
  if _session_chat_lock_root >/dev/null 2>&1; then echo "SYMLINK_ACCEPTED"; else echo "SYMLINK_REJECTED"; fi
  lp=$(session_chat_lock_path somepane)
  if [ -z "$lp" ]; then echo "LOCKPATH_EMPTY"; fi
  if acquire_lock somepane >/dev/null 2>&1; then echo "ACQUIRE_OK"; else echo "ACQUIRE_FAILCLOSED"; fi
  rm -rf "$T"
)
if echo "$lockroot_out" | grep -q "MODE=700" && echo "$lockroot_out" | grep -q UID_SCOPED \
   && echo "$lockroot_out" | grep -q SYMLINK_REJECTED && echo "$lockroot_out" | grep -q LOCKPATH_EMPTY \
   && echo "$lockroot_out" | grep -q ACQUIRE_FAILCLOSED; then
  pass "lock_root_uid_scoped_failclosed"
else
  fail "lock_root_uid_scoped_failclosed" "out=$lockroot_out"
fi

# --- Test 29: failed emit (closed stdout) retains the row AND leaves recent,
#     reply-correlation, and archive state untouched; a normal retry then
#     surfaces the exact body, drains the row, and records all three. Fixture is
#     a queued SEND carrying a [re:<id>] marker so reply-correlation is real. ---
CS_HOME=$(mktemp -d); CS_MSGS="$CS_HOME/.claude/messages"; mkdir -p "$CS_MSGS/queue"
PLUGROOT="$(cd "$HERE/.." && pwd)"
(
  source "$HERE/lib.sh"; export MESSAGES_DIR="$CS_MSGS"; export SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS=0
  enqueue_message me cs1 send peer "[re:deadbeef01] ACK-BODY" "$CS_MSGS"
  mark_message_ready me cs1 "$CS_MSGS"
)
run_detect_cs() {
  printf '{"hook_event_name":"Stop"}' | env HOME="$CS_HOME" TMUX="fake,0,0" \
    CLAUDE_PLUGIN_ROOT="$PLUGROOT" SESSION_CHAT_PANE_NAME=me SESSION_CHAT_INCOMING_MODE=auto \
    bash "$HERE/detect-incoming-message.sh"
}
qcnt() { awk "/cs1/{c++} END{print c+0}" "$1" 2>/dev/null || echo 0; }
reply_cnt() { awk "/deadbeef01/{c++} END{print c+0}" "$CS_MSGS/replies-log.tsv" 2>/dev/null || echo 0; }
arch_cnt() { find "$CS_MSGS/archive" -type f -exec grep -l 'cs1' {} + 2>/dev/null | wc -l | tr -d ' '; }
# (1) failed emit — closed stdout: row retained; recent/reply/archive all untouched.
run_detect_cs >&- 2>/dev/null || true
cs_rows=$(qcnt "$CS_MSGS/queue/me.tsv")
recent_fail=$(qcnt "$CS_MSGS/queue/.recent-me.tsv")
reply_fail=$(reply_cnt)
arch_fail=$(arch_cnt)
# (2) normal retry — stdout open: exact body surfaces; row drains; recent + reply
#     + archive now recorded.
retry_out=$(run_detect_cs)
cs_rows_after=$(qcnt "$CS_MSGS/queue/me.tsv")
recent_ok=$(qcnt "$CS_MSGS/queue/.recent-me.tsv")
reply_ok=$(reply_cnt)
arch_ok=$(arch_cnt)
if [ "$cs_rows" = "1" ] && [ "$recent_fail" = "0" ] && [ "$reply_fail" = "0" ] && [ "$arch_fail" = "0" ] \
   && echo "$retry_out" | grep -q "ACK-BODY" && [ "$cs_rows_after" = "0" ] \
   && [ "$recent_ok" -ge 1 ] && [ "$reply_ok" -ge 1 ] && [ "$arch_ok" -ge 1 ]; then
  pass "closed_stdout_retains_then_retry_drains"
else
  fail "closed_stdout_retains_then_retry_drains" "rows=$cs_rows recent_fail=$recent_fail reply_fail=$reply_fail arch_fail=$arch_fail rows_after=$cs_rows_after recent_ok=$recent_ok reply_ok=$reply_ok arch_ok=$arch_ok body=$(echo "$retry_out" | grep -c ACK-BODY)"
fi
rm -rf "$CS_HOME"

# --- Test 30: a symlinked messages ROOT makes dispatch files untrusted ---
SL_HOME=$(mktemp -d); mkdir -p "$SL_HOME/.claude" "$SL_HOME/real-msgs"
ln -s "$SL_HOME/real-msgs" "$SL_HOME/.claude/messages"
printf 'SECRETBODY\n' > "$SL_HOME/real-msgs/t.md"; chmod 600 "$SL_HOME/real-msgs/t.md"
sl_out=$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"[from:peer pane:%%1 msg:%s id:abcd1234] dispatch (1 lines)"}' "$SL_HOME/.claude/messages/t.md" \
  | env HOME="$SL_HOME" TMUX="fake,0,0" CLAUDE_PLUGIN_ROOT="$PLUGROOT" SESSION_CHAT_PANE_NAME=me SESSION_CHAT_INCOMING_MODE=auto \
    bash "$HERE/detect-incoming-message.sh")
if echo "$sl_out" | grep -q "OUTSIDE the trusted message dir" && ! echo "$sl_out" | grep -q "SECRETBODY"; then
  pass "symlinked_msgroot_untrusted"
else
  fail "symlinked_msgroot_untrusted" "out=$sl_out"
fi
rm -rf "$SL_HOME"

# --- Test 31: sandbox denial of the tmux socket is surfaced, never swallowed ---
# A sandboxed exec (e.g. a Codex sandbox profile) denies the tmux socket with
# "Operation not permitted". The user-facing enumerators (list-panes,
# pane-health, broadcast) and the self-name query (get-my-name) must classify
# that denial into a loud, actionable error + nonzero exit — NOT print an empty
# list / empty name and exit 0, which reads as a false "no panes / no name".
DENY_BIN=$(mktemp -d)
cat > "$DENY_BIN/tmux" <<'FAKE_TMUX'
#!/usr/bin/env bash
# Fake tmux that denies the socket the way a sandboxed exec does. Denies EVERY
# subcommand (display-message AND list-panes) so the current-scope self-session
# query is exercised as the ROOT failure, not just the follow-on list probe.
echo "tmux: connect failed: Operation not permitted" >&2
exit 1
FAKE_TMUX
chmod +x "$DENY_BIN/tmux"

# Fake tmux whose denial signature is "Permission denied" instead — the other
# socket-denial string the classifier must recognize.
PERM_BIN=$(mktemp -d)
cat > "$PERM_BIN/tmux" <<'PERM_TMUX'
#!/usr/bin/env bash
echo "tmux: connect failed: Permission denied" >&2
exit 1
PERM_TMUX
chmod +x "$PERM_BIN/tmux"

# Fake tmux that SUCCEEDS with genuinely-empty output (a real "no named panes"
# / "no name set" state) — the control that proves classification did not turn
# an honest empty result into a spurious error.
OK_BIN=$(mktemp -d)
cat > "$OK_BIN/tmux" <<'OK_TMUX'
#!/usr/bin/env bash
exit 0
OK_TMUX
chmod +x "$OK_BIN/tmux"

deny_run() { PATH="$DENY_BIN:$PATH" TMUX="fake,0,0" TMUX_PANE="%0" bash "$@"; }
ok_run()   { PATH="$OK_BIN:$PATH"   TMUX="fake,0,0" TMUX_PANE="%0" bash "$@"; }

# has_denial <combined-output>: classified escalated-retry message present for
# either recognized socket-denial signature.
has_denial() { echo "$1" | grep -q "escalated/approved" && echo "$1" | grep -Eq "Operation not permitted|Permission denied"; }

# (a) list-panes, enumeration scope (all): denial -> ERROR + rc!=0 + no rows.
lp_out=$(deny_run "$HERE/list-panes.sh" all 2>&1); lp_rc=$?
lp_stdout=$(deny_run "$HERE/list-panes.sh" all 2>/dev/null)
if [ "$lp_rc" -ne 0 ] && has_denial "$lp_out" && [ -z "$lp_stdout" ]; then
  pass "denial_list_panes_surfaced"
else
  fail "denial_list_panes_surfaced" "rc=$lp_rc out=$lp_out stdout=$lp_stdout"
fi

# (a2) list-panes, CURRENT scope (no arg): the self-session display-message is
#      the ROOT failure and must be classified at its source, not swallowed.
lpc_out=$(deny_run "$HERE/list-panes.sh" 2>&1); lpc_rc=$?
lpc_stdout=$(deny_run "$HERE/list-panes.sh" 2>/dev/null)
if [ "$lpc_rc" -ne 0 ] && has_denial "$lpc_out" && echo "$lpc_out" | grep -q "current tmux session" && [ -z "$lpc_stdout" ]; then
  pass "denial_list_panes_current_scope_surfaced"
else
  fail "denial_list_panes_current_scope_surfaced" "rc=$lpc_rc out=$lpc_out stdout=$lpc_stdout"
fi

# (b) pane-health, enumeration scope (--all): denial -> ERROR + rc!=0, and
#     specifically NOT the benign "No named panes found" all-clear.
ph_out=$(deny_run "$HERE/pane-health.sh" --all 2>&1); ph_rc=$?
if [ "$ph_rc" -ne 0 ] && has_denial "$ph_out" && ! echo "$ph_out" | grep -q "No named panes found"; then
  pass "denial_pane_health_surfaced"
else
  fail "denial_pane_health_surfaced" "rc=$ph_rc out=$ph_out"
fi

# (b2) pane-health, CURRENT scope (no arg): self-session display-message denial
#      is the ROOT failure and must be classified at its source.
phc_out=$(deny_run "$HERE/pane-health.sh" 2>&1); phc_rc=$?
if [ "$phc_rc" -ne 0 ] && has_denial "$phc_out" && echo "$phc_out" | grep -q "current tmux session" && ! echo "$phc_out" | grep -q "No named panes found"; then
  pass "denial_pane_health_current_scope_surfaced"
else
  fail "denial_pane_health_current_scope_surfaced" "rc=$phc_rc out=$phc_out"
fi

# (c) get-my-name: denial -> ERROR + rc!=0 + empty stdout (self-name flavor hint,
#     which additionally names the SESSION_CHAT_PANE_NAME escape hatch).
gmn_out=$(deny_run "$HERE/get-my-name.sh" 2>&1); gmn_rc=$?
gmn_stdout=$(deny_run "$HERE/get-my-name.sh" 2>/dev/null)
if [ "$gmn_rc" -ne 0 ] && has_denial "$gmn_out" && echo "$gmn_out" | grep -q "SESSION_CHAT_PANE_NAME" && [ -z "$gmn_stdout" ]; then
  pass "denial_get_my_name_surfaced"
else
  fail "denial_get_my_name_surfaced" "rc=$gmn_rc out=$gmn_out stdout=$gmn_stdout"
fi

# (d) broadcast, self-name path: no SESSION_CHAT_PANE_NAME -> the denied self-name
#     query must report a resolution failure, NOT "This pane has no name".
bc_self=$(deny_run "$HERE/broadcast-message.sh" "ping" 2>&1); bc_self_rc=$?
if [ "$bc_self_rc" -ne 0 ] && has_denial "$bc_self" && ! echo "$bc_self" | grep -q "This pane has no name"; then
  pass "denial_broadcast_selfname_surfaced"
else
  fail "denial_broadcast_selfname_surfaced" "rc=$bc_self_rc out=$bc_self"
fi

# (e) broadcast, enumeration path: self-name asserted via env AND --all scope so
#     we skip the self-session query and reach the pane listing -> denial there
#     must report a listing failure, NOT the benign "No named panes matched".
bc_enum=$(PATH="$DENY_BIN:$PATH" TMUX="fake,0,0" TMUX_PANE="%0" SESSION_CHAT_PANE_NAME=me \
  bash "$HERE/broadcast-message.sh" --all "ping" 2>&1); bc_enum_rc=$?
if [ "$bc_enum_rc" -ne 0 ] && has_denial "$bc_enum" && ! echo "$bc_enum" | grep -q "No named panes matched"; then
  pass "denial_broadcast_enumeration_surfaced"
else
  fail "denial_broadcast_enumeration_surfaced" "rc=$bc_enum_rc out=$bc_enum"
fi

# (e2) broadcast, CURRENT scope: self-name asserted via env so we pass the name
#      gate, then the self-session display-message denial is the ROOT failure.
bc_cur=$(PATH="$DENY_BIN:$PATH" TMUX="fake,0,0" TMUX_PANE="%0" SESSION_CHAT_PANE_NAME=me \
  bash "$HERE/broadcast-message.sh" "ping" 2>&1); bc_cur_rc=$?
if [ "$bc_cur_rc" -ne 0 ] && has_denial "$bc_cur" && echo "$bc_cur" | grep -q "current tmux session" && ! echo "$bc_cur" | grep -q "No named panes matched"; then
  pass "denial_broadcast_current_scope_surfaced"
else
  fail "denial_broadcast_current_scope_surfaced" "rc=$bc_cur_rc out=$bc_cur"
fi

# (g) "Permission denied" is classified identically to "Operation not permitted".
pd_out=$(PATH="$PERM_BIN:$PATH" TMUX="fake,0,0" TMUX_PANE="%0" bash "$HERE/list-panes.sh" all 2>&1); pd_rc=$?
if [ "$pd_rc" -ne 0 ] && has_denial "$pd_out" && echo "$pd_out" | grep -q "Permission denied"; then
  pass "denial_permission_denied_classified"
else
  fail "denial_permission_denied_classified" "rc=$pd_rc out=$pd_out"
fi

# (f) control: an honest empty result (tmux OK, nothing named) stays a clean
#     exit-0 empty listing — denial classification must not false-positive.
ctl_out=$(ok_run "$HERE/list-panes.sh" all 2>&1); ctl_rc=$?
if [ "$ctl_rc" -eq 0 ] && [ -z "$ctl_out" ]; then
  pass "empty_list_not_misclassified_as_denial"
else
  fail "empty_list_not_misclassified_as_denial" "rc=$ctl_rc out=$ctl_out"
fi

rm -rf "$DENY_BIN" "$PERM_BIN" "$OK_BIN"

# --- Test 32: reply correlation — apply_reply_to normalization ---
# Exactly-one leading token; repeated same-id LEADING tokens collapse (a token
# later in the body is quoted text and stays verbatim); a conflicting different
# leading token is refused; malformed ids fail closed.
ar=$(
  source "$HERE/lib.sh"
  printf 'VALID=[%s]\n'    "$(apply_reply_to deadbeef 'hello world')"
  printf 'LEAD=[%s]\n'     "$(apply_reply_to deadbeef '[re:deadbeef] hello')"
  printf 'DUP=[%s]\n'      "$(apply_reply_to deadbeef '[re:deadbeef] [re:deadbeef] x')"
  printf 'MID=[%s]\n'      "$(apply_reply_to deadbeef 'foo [re:deadbeef] bar')"
  conflict_err=$(apply_reply_to deadbeef '[re:cafebabe] x' 2>&1 >/dev/null); conflict_rc=$?
  if [ "$conflict_rc" -ne 0 ] && printf '%s' "$conflict_err" | grep -q 'conflicting correlation token'; then echo CONFLICT=ok; else echo CONFLICT=bad; fi
  if apply_reply_to deadbeef '[re:deadbeef] [re:cafebabe] x' >/dev/null 2>&1; then echo MIXCONFLICT=bad; else echo MIXCONFLICT=ok; fi
  apply_reply_to ABCDEF12 x >/dev/null 2>&1 && echo UPPER=bad || echo UPPER=ok
  apply_reply_to abc x >/dev/null 2>&1 && echo SHORT=bad || echo SHORT=ok
  apply_reply_to abcdef1234567890a x >/dev/null 2>&1 && echo LONG=bad || echo LONG=ok
  apply_reply_to 'dead beef' x >/dev/null 2>&1 && echo SPACE=bad || echo SPACE=ok
  printf 'COUNT=%s\n' "$(apply_reply_to deadbeef '[re:deadbeef] [re:deadbeef] x' | grep -oF '[re:deadbeef]' | wc -l | tr -d ' ')"
)
if echo "$ar" | grep -qF 'VALID=[[re:deadbeef] hello world]' \
   && echo "$ar" | grep -qF 'LEAD=[[re:deadbeef] hello]' \
   && echo "$ar" | grep -qF 'DUP=[[re:deadbeef] x]' \
   && echo "$ar" | grep -qF 'MID=[[re:deadbeef] foo [re:deadbeef] bar]' \
   && echo "$ar" | grep -q 'CONFLICT=ok' && echo "$ar" | grep -q 'MIXCONFLICT=ok' \
   && echo "$ar" | grep -q 'UPPER=ok' && echo "$ar" | grep -q 'SHORT=ok' \
   && echo "$ar" | grep -q 'LONG=ok' && echo "$ar" | grep -q 'SPACE=ok' \
   && echo "$ar" | grep -q 'COUNT=1'; then
  pass "reply_apply_normalization"
else
  fail "reply_apply_normalization" "out=$ar"
fi

# --- Test 33: send-path reply correlation (token lands in payload) ---
sc=$(
  source "$HERE/lib.sh"
  RB=$(mktemp -d); export MESSAGES_DIR="$RB/messages"
  payload=$(apply_reply_to deadbeef01 'thanks, done')
  log_reply_ids peer "$payload"
  awk '/deadbeef01/{c++} END{print c+0}' "$MESSAGES_DIR/replies-log.tsv" 2>/dev/null
  rm -rf "$RB"
)
if [ "$sc" = "1" ]; then pass "reply_send_correlation"; else fail "reply_send_correlation" "count=$sc"; fi

# --- Test 34: transport rejects a malformed --reply-to before sending ---
# Run with TMUX/TMUX_PANE unset: the id must be validated BEFORE ensure_tmux, so
# a bad --reply-to reports the id error, not "Not inside tmux" (ordering defect).
inv_send=$(env -u TMUX -u TMUX_PANE bash "$HERE/send-message.sh" --reply-to NOTHEX alpha "hi" 2>&1); inv_send_rc=$?
PF34=$(mktemp); printf 'body\n' > "$PF34"
inv_disp=$(env -u TMUX -u TMUX_PANE bash "$HERE/dispatch-to-session.sh" --reply-to 12xy alpha "$PF34" 2>&1); inv_disp_rc=$?
rm -f "$PF34"
if [ "$inv_send_rc" -ne 0 ] && echo "$inv_send" | grep -q "8-16 char lowercase hex" \
   && [ "$inv_disp_rc" -ne 0 ] && echo "$inv_disp" | grep -q "8-16 char lowercase hex"; then
  pass "reply_transport_rejects_bad_id"
else
  fail "reply_transport_rejects_bad_id" "send(rc=$inv_send_rc)=$inv_send disp(rc=$inv_disp_rc)=$inv_disp"
fi

# --- Test 35: dispatch body scan — main path + bounded prefix ---
df=$(
  source "$HERE/lib.sh"
  RB=$(mktemp -d); export MESSAGES_DIR="$RB/messages"; mkdir -p "$MESSAGES_DIR"
  f="$MESSAGES_DIR/body.md"; printf '[re:cafed00d] big task\nmore lines\n' > "$f"
  log_reply_ids_from_file peer "$f"
  echo "MAIN=$(awk '/cafed00d/{c++} END{print c+0}' "$MESSAGES_DIR/replies-log.tsv" 2>/dev/null)"
  # Token past the scan window must NOT be seen.
  g="$MESSAGES_DIR/big.md"; { head -c 4000 /dev/zero | tr '\0' 'x'; printf '\n[re:beefbeef]\n'; } > "$g"
  SESSION_CHAT_REPLY_SCAN_BYTES=1024 log_reply_ids_from_file peer "$g"
  echo "BOUND=$(awk '/beefbeef/{c++} END{print c+0}' "$MESSAGES_DIR/replies-log.tsv" 2>/dev/null)"
  rm -rf "$RB"
)
if echo "$df" | grep -q 'MAIN=1' && echo "$df" | grep -q 'BOUND=0'; then
  pass "reply_dispatch_body_scan"
else
  fail "reply_dispatch_body_scan" "out=$df"
fi

# --- Test 36: end-to-end dispatch correlation (live + queued) via detect ---
RC_HOME=$(mktemp -d); RC_MSGS="$RC_HOME/.claude/messages"; mkdir -p "$RC_MSGS/queue"
RPLUG="$(cd "$HERE/.." && pwd)"
# Live dispatch: notification points at a trusted file whose body leads with a
# reply token distinct from the message's own id.
LDFILE="$RC_MSGS/live-dispatch.md"; printf '[re:feedface] please do the thing\n' > "$LDFILE"; chmod 600 "$LDFILE"
printf '{"hook_event_name":"UserPromptSubmit","prompt":"[from:peer pane:%%1 msg:%s id:abcd1234] dispatch (1 lines) — read msg file id:abcd1234"}' "$LDFILE" \
  | env HOME="$RC_HOME" TMUX="fake,0,0" CLAUDE_PLUGIN_ROOT="$RPLUG" SESSION_CHAT_PANE_NAME=me SESSION_CHAT_INCOMING_MODE=auto \
    bash "$HERE/detect-incoming-message.sh" >/dev/null 2>&1
live_corr=$(awk '/feedface/{c++} END{print c+0}' "$RC_MSGS/replies-log.tsv" 2>/dev/null || echo 0)
# Queued dispatch: enqueue a dispatch row for a trusted file, surface on Stop.
QDFILE="$RC_MSGS/queued-dispatch.md"; printf '[re:cafef00d] queued task body\n' > "$QDFILE"; chmod 600 "$QDFILE"
(
  source "$HERE/lib.sh"; export MESSAGES_DIR="$RC_MSGS"; export SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS=0
  enqueue_message me qd1 dispatch peer "$QDFILE" "$RC_MSGS"
  mark_message_ready me qd1 "$RC_MSGS"
)
printf '{"hook_event_name":"Stop"}' \
  | env HOME="$RC_HOME" TMUX="fake,0,0" CLAUDE_PLUGIN_ROOT="$RPLUG" SESSION_CHAT_PANE_NAME=me SESSION_CHAT_INCOMING_MODE=auto SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS=0 \
    bash "$HERE/detect-incoming-message.sh" >/dev/null 2>&1
queued_corr=$(awk '/cafef00d/{c++} END{print c+0}' "$RC_MSGS/replies-log.tsv" 2>/dev/null || echo 0)
if [ "$live_corr" -ge 1 ] && [ "$queued_corr" -ge 1 ]; then
  pass "reply_dispatch_correlation_live_and_queued"
else
  fail "reply_dispatch_correlation_live_and_queued" "live=$live_corr queued=$queued_corr log=$(cat "$RC_MSGS/replies-log.tsv" 2>/dev/null)"
fi
rm -rf "$RC_HOME"

# --- Test 38: /reply hint carries the CONCRETE id in every mode (notify + queued) ---
# The reply-correlation hint must appear even in notify mode (and for queued
# recovery), with the concrete /reply <from> <id>, WITHOUT weakening the trust
# framing (notify still says ask the local user first).
RH_HOME=$(mktemp -d); RH_MSGS="$RH_HOME/.claude/messages"; mkdir -p "$RH_MSGS/queue"
RHPLUG="$(cd "$HERE/.." && pwd)"
# (a) notify mode, live send: concrete hint present AND untrusted framing intact.
notify_out=$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"[from:peer pane:%%1 id:abc12345] hello there [id:abc12345]"}' \
  | env HOME="$RH_HOME" TMUX="fake,0,0" CLAUDE_PLUGIN_ROOT="$RHPLUG" SESSION_CHAT_PANE_NAME=me SESSION_CHAT_INCOMING_MODE=notify \
    bash "$HERE/detect-incoming-message.sh" 2>&1)
# (b) queued send recovery (notify mode): concrete hint present for the queued id.
(
  source "$HERE/lib.sh"; export MESSAGES_DIR="$RH_MSGS"; export SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS=0
  enqueue_message me beadcafe send peer "a queued ping" "$RH_MSGS"
  mark_message_ready me beadcafe "$RH_MSGS"
)
queued_out=$(printf '{"hook_event_name":"Stop"}' \
  | env HOME="$RH_HOME" TMUX="fake,0,0" CLAUDE_PLUGIN_ROOT="$RHPLUG" SESSION_CHAT_PANE_NAME=me SESSION_CHAT_INCOMING_MODE=notify SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS=0 \
    bash "$HERE/detect-incoming-message.sh" 2>&1)
if echo "$notify_out" | grep -qF 'When a reply is authorized, use /reply peer abc12345' \
   && echo "$notify_out" | grep -q 'ask the local user' \
   && echo "$queued_out" | grep -qF 'When a reply is authorized, use /reply peer beadcafe'; then
  pass "reply_hint_concrete_id_notify_and_queued"
else
  fail "reply_hint_concrete_id_notify_and_queued" "notify=$notify_out queued=$queued_out"
fi
rm -rf "$RH_HOME"

# --- Test 37: check-replies reports 'unconfirmed' (not 'awaiting') ---
CK_HOME=$(mktemp -d); CK_MSGS="$CK_HOME/.claude/messages"; mkdir -p "$CK_MSGS"
(
  source "$HERE/lib.sh"; export MESSAGES_DIR="$CK_MSGS"
  log_sent_message beadfeed me peer send live "an unanswered ping"
)
ck_out=$(env HOME="$CK_HOME" bash "$HERE/check-replies.sh" 2>&1)
if echo "$ck_out" | grep -q "unconfirmed" && ! echo "$ck_out" | grep -qw "awaiting"; then
  pass "check_replies_unconfirmed_status"
else
  fail "check_replies_unconfirmed_status" "out=$ck_out"
fi
rm -rf "$CK_HOME"

# --- Test 39: nested queue subtree symlink planted AFTER the perms marker is
#     rejected on enqueue (the one-time migration marker must not grant a pass to
#     a later-swapped queue dir). ---
qsub_out=$(
  source "$HERE/lib.sh"
  QB=$(mktemp -d); md="$QB/messages"; export MESSAGES_DIR="$md"
  mkdir -p "$md/queue"
  harden_messages_dir "$md"                 # stamps .perms-hardened-v1 marker
  outside="$QB/outside"; mkdir -p "$outside"
  rm -rf "$md/queue"; ln -s "$outside" "$md/queue"   # swap queue -> symlink, post-marker
  enqueue_message peer id1 send me hello "$md"; echo "ENQ_RC=$?"
  [ -z "$(ls -A "$outside" 2>/dev/null)" ] && echo "OUTSIDE_CLEAN"
  rm -rf "$QB"
)
if echo "$qsub_out" | grep -q 'ENQ_RC=1' && echo "$qsub_out" | grep -q 'OUTSIDE_CLEAN'; then
  pass "queue_subtree_symlink_rejected_post_marker"
else
  fail "queue_subtree_symlink_rejected_post_marker" "out=$qsub_out"
fi

# --- Test 40: a symlinked queue-file LEAF (planted after the marker, inside a
#     real queue dir) is refused and its out-of-tree target preserved — subtree
#     dir guards alone don't catch leaf redirection. ---
leaf_out=$(
  source "$HERE/lib.sh"
  LB=$(mktemp -d); md="$LB/messages"; export MESSAGES_DIR="$md"
  mkdir -p "$md/queue"
  harden_messages_dir "$md"
  outside="$LB/outside.tsv"; printf 'ORIGINAL\n' > "$outside"
  ln -s "$outside" "$md/queue/peer.tsv"     # queue_file_for peer -> outside
  enqueue_message peer id1 send me hello "$md"; echo "ENQ_RC=$?"
  [ "$(cat "$outside")" = "ORIGINAL" ] && echo "LEAF_PRESERVED"
  rm -rf "$LB"
)
if echo "$leaf_out" | grep -q 'ENQ_RC=1' && echo "$leaf_out" | grep -q 'LEAF_PRESERVED'; then
  pass "queue_leaf_symlink_preserved"
else
  fail "queue_leaf_symlink_preserved" "out=$leaf_out"
fi

# --- Test 41: a HARDLINKED queue-file leaf (link count 2 => shares an inode with
#     an outside file) is refused before any write; the outside content is
#     preserved. ---
hard_out=$(
  source "$HERE/lib.sh"
  HB=$(mktemp -d); md="$HB/messages"; export MESSAGES_DIR="$md"
  mkdir -p "$md/queue"
  harden_messages_dir "$md"
  outside="$HB/outside.tsv"; printf 'ORIGINAL\n' > "$outside"
  ln "$outside" "$md/queue/peer.tsv"        # hardlink, planted post-marker
  enqueue_message peer id1 send me hello "$md"; echo "ENQ_RC=$?"
  [ "$(cat "$outside")" = "ORIGINAL" ] && echo "HARD_PRESERVED"
  rm -rf "$HB"
)
if echo "$hard_out" | grep -q 'ENQ_RC=1' && echo "$hard_out" | grep -q 'HARD_PRESERVED'; then
  pass "queue_leaf_hardlink_rejected"
else
  fail "queue_leaf_hardlink_rejected" "out=$hard_out"
fi

# --- Test 42: sent-log / replies-log / archive date-file leaves that are
#     symlinks to out-of-tree files are never appended through (best-effort ops
#     skip on refusal); the outside targets stay untouched. ---
log_out=$(
  source "$HERE/lib.sh"
  GB=$(mktemp -d); md="$GB/messages"; export MESSAGES_DIR="$md"
  mkdir -p "$md/archive"
  harden_messages_dir "$md"
  out_sent="$GB/outside-sent.tsv"; printf 'ORIGINAL\n' > "$out_sent"
  out_rep="$GB/outside-rep.tsv";  printf 'ORIGINAL\n' > "$out_rep"
  out_arch="$GB/outside-arch.tsv"; printf 'ORIGINAL\n' > "$out_arch"
  day=$(date +%Y-%m-%d)
  ln -s "$out_sent" "$md/sent-log.tsv"
  ln -s "$out_rep"  "$md/replies-log.tsv"
  ln -s "$out_arch" "$md/archive/$day.tsv"
  # Each guard is exercised by the function that owns that leaf. archive_message
  # is called DIRECTLY: log_sent_message returns at its own sent-log guard and
  # would never reach the archive append, so relying on it would false-green ARCH.
  log_sent_message id1 me peer send live "hello there"   # sent-log leaf guard
  log_reply_ids peer "[re:deadbeef] ok"                  # replies-log leaf guard
  archive_message out peer send id1 "hello there"        # archive day-file leaf guard
  echo "SENT=$(wc -l < "$out_sent" | tr -d ' ')"
  echo "REP=$(wc -l < "$out_rep" | tr -d ' ')"
  echo "ARCH=$(wc -l < "$out_arch" | tr -d ' ')"
  rm -rf "$GB"
)
if echo "$log_out" | grep -q 'SENT=1' && echo "$log_out" | grep -q 'REP=1' && echo "$log_out" | grep -q 'ARCH=1'; then
  pass "log_and_archive_leaf_symlink_preserved"
else
  fail "log_and_archive_leaf_symlink_preserved" "out=$log_out"
fi

# --- Test 43: the receiver trust gate rejects a HARDLINKED dispatch file (link
#     count 2 => an outside path shares the inode), so hardlinked outside content
#     is never treated as a trusted task body. ---
HL_HOME=$(mktemp -d); HL_MSGS="$HL_HOME/.claude/messages"; mkdir -p "$HL_MSGS"
printf 'HARDLINKBODY\n' > "$HL_HOME/outside-body.txt"
ln "$HL_HOME/outside-body.txt" "$HL_MSGS/task.md"   # hardlink into the messages dir
chmod 600 "$HL_MSGS/task.md"
hl_out=$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"[from:peer pane:%%1 msg:%s id:abcd1234] dispatch (1 lines)"}' "$HL_MSGS/task.md" \
  | env HOME="$HL_HOME" TMUX="fake,0,0" CLAUDE_PLUGIN_ROOT="" SESSION_CHAT_INCOMING_MODE=auto \
    bash "$HERE/detect-incoming-message.sh")
if echo "$hl_out" | grep -q 'OUTSIDE the trusted message dir' && ! echo "$hl_out" | grep -q 'HARDLINKBODY'; then
  pass "trust_reject_hardlink"
else
  fail "trust_reject_hardlink" "out=$hl_out"
fi
rm -rf "$HL_HOME"

# --- Test 44: a DANGLING .perms-hardened-v1 marker symlink must be rejected, not
#     followed by the create redirection out of the tree. harden + enqueue fail
#     closed and the out-of-tree marker target is never created. ---
dm_out=$(
  source "$HERE/lib.sh"
  DB=$(mktemp -d); md="$DB/messages"; export MESSAGES_DIR="$md"
  mkdir -p "$md"
  outside="$DB/outside-marker"                    # does NOT exist (dangling target)
  ln -s "$outside" "$md/.perms-hardened-v1"
  harden_messages_dir "$md"; echo "HARDEN_RC=$?"
  enqueue_message peer id1 send me hello "$md"; echo "ENQ_RC=$?"
  [ ! -e "$outside" ] && echo "OUTSIDE_NOT_CREATED"
  rm -rf "$DB"
)
if echo "$dm_out" | grep -q 'HARDEN_RC=1' && echo "$dm_out" | grep -q 'ENQ_RC=1' \
   && echo "$dm_out" | grep -q 'OUTSIDE_NOT_CREATED'; then
  pass "dangling_marker_symlink_rejected"
else
  fail "dangling_marker_symlink_rejected" "out=$dm_out"
fi

# --- Test 45: a queue subdir loosened to 0777 AFTER the perms marker is
#     re-tightened to 0700 on the next op (owner-only contract holds post-marker),
#     and the op still succeeds. ---
loose_out=$(
  source "$HERE/lib.sh"
  LB=$(mktemp -d); md="$LB/messages"; export MESSAGES_DIR="$md"
  mkdir -p "$md/queue"; harden_messages_dir "$md"   # marker set
  chmod 777 "$md/queue"                             # loosen AFTER marker
  enqueue_message peer id1 send me hello "$md"; echo "ENQ_RC=$?"
  echo "QMODE=$(stat -c '%a' "$md/queue" 2>/dev/null || stat -f '%Lp' "$md/queue" 2>/dev/null)"
  rm -rf "$LB"
)
if echo "$loose_out" | grep -q 'ENQ_RC=0' && echo "$loose_out" | grep -q 'QMODE=700'; then
  pass "queue_subtree_loose_dir_tightened_post_marker"
else
  fail "queue_subtree_loose_dir_tightened_post_marker" "out=$loose_out"
fi

# --- Test 46: custom mailbox: live dispatch trusted + auto-inlined ---
# SESSION_CHAT_TARGET_MESSAGES_DIR relocates the whole mailbox; the receiver
# hook sources lib.sh (CLAUDE_PLUGIN_ROOT set) so this exercises the
# clobber regression directly: MESSAGES_DIR must resolve to the custom dir
# both before and after lib.sh is sourced.
CMB=$(mktemp -d); CMB_HOME="$CMB/home"; CMB_MSGS="$CMB/custom-mailbox"
mkdir -p "$CMB_HOME" "$CMB_MSGS"
PLUGROOT="$(cd "$HERE/.." && pwd)"
printf 'CUSTOM-DIR-TASK-BODY\nsecond line\n' > "$CMB_MSGS/ctask.md"; chmod 600 "$CMB_MSGS/ctask.md"
cmb_out=$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"[from:peer pane:%%1 msg:%s id:cafe1234] dispatch (2 lines) — read msg file for full task id:cafe1234"}' "$CMB_MSGS/ctask.md" \
  | env HOME="$CMB_HOME" TMUX="fake,0,0" CLAUDE_PLUGIN_ROOT="$PLUGROOT" SESSION_CHAT_PANE_NAME=me \
    SESSION_CHAT_INCOMING_MODE=auto SESSION_CHAT_TARGET_MESSAGES_DIR="$CMB_MSGS" \
    bash "$HERE/detect-incoming-message.sh")
if echo "$cmb_out" | grep -q 'trusted task file' && echo "$cmb_out" | grep -q 'CUSTOM-DIR-TASK-BODY' \
   && [ ! -d "$CMB_HOME/.claude/messages" ]; then
  pass "custom_mailbox_live_dispatch_trusted"
else
  fail "custom_mailbox_live_dispatch_trusted" "default_dir_exists=$([ -d "$CMB_HOME/.claude/messages" ] && echo yes || echo no) out=$cmb_out"
fi

# --- Test 47: custom mailbox: queued recovery drains through the hook ---
# Seed the queue via the public var only (no exported MESSAGES_DIR) — the
# sourced lib.sh must resolve MESSAGES_DIR to the custom dir on its own.
printf 'CUSTOM-QUEUED-BODY\n' > "$CMB_MSGS/qtask.md"; chmod 600 "$CMB_MSGS/qtask.md"
(
  export SESSION_CHAT_TARGET_MESSAGES_DIR="$CMB_MSGS" SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS=0
  source "$HERE/lib.sh"
  enqueue_message me qd123456 dispatch peer "$CMB_MSGS/qtask.md"
  mark_message_ready me qd123456
)
cmbq_out=$(printf '{"hook_event_name":"Stop"}' | env HOME="$CMB_HOME" TMUX="fake,0,0" \
  CLAUDE_PLUGIN_ROOT="$PLUGROOT" SESSION_CHAT_PANE_NAME=me SESSION_CHAT_INCOMING_MODE=auto \
  SESSION_CHAT_TARGET_MESSAGES_DIR="$CMB_MSGS" SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS=0 \
  bash "$HERE/detect-incoming-message.sh")
cmbq_remaining=$(awk -F'\t' '$1=="qd123456"{c++} END{print c+0}' "$CMB_MSGS/queue/me.tsv" 2>/dev/null)
cmbq_ledger=$(grep -c qd123456 "$CMB_MSGS/queue/.recent-me.tsv" 2>/dev/null || echo 0)
if echo "$cmbq_out" | grep -q 'CUSTOM-QUEUED-BODY' && [ "$cmbq_remaining" = "0" ] && [ "$cmbq_ledger" -ge 1 ]; then
  pass "custom_mailbox_queued_recovery_drains"
else
  fail "custom_mailbox_queued_recovery_drains" "remaining=$cmbq_remaining ledger=$cmbq_ledger out=$cmbq_out"
fi
rm -rf "$CMB"

# --- Test 48: lib-less receiver honors CLAUDE_HOME (and the override still
#     wins over it) — regression guard for the pre-source MESSAGES_DIR fallback
#     in detect-incoming-message.sh. No tmux/lib needed: CLAUDE_PLUGIN_ROOT=""
#     keeps lib.sh unsourced, so this exercises the raw fallback expression
#     directly, same harness style as tests 13-18.
CHB_FAKEHOME=$(mktemp -d)
CHB_BASE=$(mktemp -d); CH="$CHB_BASE/claude-home"
mkdir -p "$CH/messages"
printf 'CLAUDE-HOME-FALLBACK-BODY\n' > "$CH/messages/chtask.md"; chmod 600 "$CH/messages/chtask.md"

# (a) override UNSET: a lib-less receiver must still trust a dispatch file
#     under CLAUDE_HOME/messages (matches what a lib-sourcing sender would
#     have written there). Fails against the old $HOME/.claude/messages-only
#     fallback — the file would be rejected as outside the trusted dir.
chb_a_out=$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"[from:peer pane:%%1 msg:%s id:c1a2b3c4] dispatch (1 lines) — read msg file"}' "$CH/messages/chtask.md" \
  | env HOME="$CHB_FAKEHOME" TMUX="fake-socket,0,0" CLAUDE_HOME="$CH" CLAUDE_PLUGIN_ROOT="" \
    SESSION_CHAT_INCOMING_MODE=auto bash "$HERE/detect-incoming-message.sh")

# (b) override SET to a third dir: must beat CLAUDE_HOME in the lib-less path too.
CHB_OV=$(mktemp -d)
printf 'OVERRIDE-BEATS-CLAUDE-HOME-BODY\n' > "$CHB_OV/ovtask.md"; chmod 600 "$CHB_OV/ovtask.md"
chb_b_out=$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"[from:peer pane:%%1 msg:%s id:d5e6f7a8] dispatch (1 lines) — read msg file"}' "$CHB_OV/ovtask.md" \
  | env HOME="$CHB_FAKEHOME" TMUX="fake-socket,0,0" CLAUDE_HOME="$CH" CLAUDE_PLUGIN_ROOT="" \
    SESSION_CHAT_TARGET_MESSAGES_DIR="$CHB_OV" SESSION_CHAT_INCOMING_MODE=auto bash "$HERE/detect-incoming-message.sh")

if echo "$chb_a_out" | grep -q 'trusted task file' && echo "$chb_a_out" | grep -q 'CLAUDE-HOME-FALLBACK-BODY' \
   && echo "$chb_b_out" | grep -q 'trusted task file' && echo "$chb_b_out" | grep -q 'OVERRIDE-BEATS-CLAUDE-HOME-BODY'; then
  pass "lib_less_claude_home_fallback_and_override_precedence"
else
  fail "lib_less_claude_home_fallback_and_override_precedence" "a_out=$chb_a_out b_out=$chb_b_out"
fi
rm -rf "$CHB_FAKEHOME" "$CHB_BASE" "$CHB_OV"

# --- Cross-plugin integration: a real 20 KB dispatch is fully readable ---
# Real dispatch helper + isolated tmux socket -> incoming hook header ->
# validated strict-v1 --decision-json -> execute the emitted cat and compare
# every byte, for both receiving roles at the default inline cap and past the
# outer context cap, with a wrong-role negative control. Needs the sibling
# session-workspace plugin (present in this source tree).
if python3 -B "$HERE/test-dispatch-read.py" >"${TMPDIR:-/tmp}/session-chat-dispatch-read.$$.log" 2>&1; then
  pass "dispatch_read_20kb_integration"
else
  fail "dispatch_read_20kb_integration" "$(tail -20 "${TMPDIR:-/tmp}/session-chat-dispatch-read.$$.log")"
fi
rm -f "${TMPDIR:-/tmp}/session-chat-dispatch-read.$$.log"

# ===========================================================================
# Tier 1.2a — typed reply envelope (leading [re:] / [task:]), expected-peer
# verification, and 16-hex message ids. Every refusal below has a paired
# positive control in the same fixture.
# ===========================================================================
E_ROOT=$(mktemp -d)
E_PLUG="$(cd "$HERE/.." && pwd)"

# --- envelope grammar: conflicts / reorder refused, duplicates collapse ---
ev=$(
  source "$HERE/lib.sh"
  chk() { # chk <label> <ok|refuse> <body>
    local got=ok
    parse_reply_envelope "$3" || got=refuse
    if [ "$got" = "$2" ]; then echo "$1=pass"; else echo "$1=FAIL(got=$got re=$ENV_RE task=$ENV_TASK err=$ENV_ERR)"; fi
  }
  chk two_re_refused        refuse '[re:aaaaaaaa] [re:bbbbbbbb] x'
  chk same_re_collapses     ok     '[re:aaaaaaaa] [re:aaaaaaaa] x'
  parse_reply_envelope '[re:aaaaaaaa] [re:aaaaaaaa] x'
  [ "$ENV_RE" = aaaaaaaa ] && [ "$ENV_REST" = x ] && echo "same_re_value=pass" || echo "same_re_value=FAIL($ENV_RE|$ENV_REST)"
  chk full_run_consumed     refuse '[re:aaaaaaaa] [re:aaaaaaaa] [re:bbbbbbbb] x'
  chk two_task_refused      refuse '[re:aaaaaaaa] [task:t1] [task:t2] x'
  chk same_task_collapses   ok     '[re:aaaaaaaa] [task:t1] [task:t1] x'
  chk task_before_re_refused refuse '[task:t1] [re:aaaaaaaa] x'
  chk re_then_task_ok       ok     '[re:aaaaaaaa] [task:t1] x'
  chk task_only_ok          ok     '[task:t1] x'
  parse_reply_envelope '[task:t1] x'
  [ -z "$ENV_RE" ] && [ "$ENV_TASK" = t1 ] && [ "$ENV_REST" = x ] && echo "task_only_value=pass" || echo "task_only_value=FAIL($ENV_RE|$ENV_TASK|$ENV_REST)"
  # A token after non-envelope text is quoted text, whatever it says.
  chk quoted_conflict_ignored ok 'see [re:aaaaaaaa] and [re:bbbbbbbb] [task:t1] [task:t2]'
  parse_reply_envelope 'see [re:aaaaaaaa] x'
  [ -z "$ENV_RE" ] && [ "$ENV_REST" = 'see [re:aaaaaaaa] x' ] && echo "quoted_not_parsed=pass" || echo "quoted_not_parsed=FAIL($ENV_RE|$ENV_REST)"
  # Glued / malformed tokens end the run and are left verbatim.
  parse_reply_envelope '[re:aaaaaaaa]x'
  [ -z "$ENV_RE" ] && [ "$ENV_REST" = '[re:aaaaaaaa]x' ] && echo "glued_not_token=pass" || echo "glued_not_token=FAIL($ENV_RE|$ENV_REST)"
  parse_reply_envelope '[re:aaaaaaaa] [task:bad!] [re:bbbbbbbb]'
  [ "$ENV_RE" = aaaaaaaa ] && [ "$ENV_REST" = '[task:bad!] [re:bbbbbbbb]' ] && echo "malformed_ends_run=pass" || echo "malformed_ends_run=FAIL($ENV_RE|$ENV_REST)"
)
if [ "$(printf '%s\n' "$ev" | grep -c '=pass$')" = "14" ] && ! printf '%s\n' "$ev" | grep -q 'FAIL'; then
  pass "envelope_grammar_refusals_with_controls"
else
  fail "envelope_grammar_refusals_with_controls" "out=$ev"
fi

# --- apply_envelope: compose re+task, leading-only normalization ---
ae=$(
  source "$HERE/lib.sh"
  show() { local out; if out=$("$@" 2>/dev/null); then printf '[%s]' "$out"; else printf 'REFUSED'; fi; }
  echo "BOTH=$(show apply_envelope aaaaaaaa t1 'hello')"
  echo "TASKONLY=$(show apply_envelope '' t1 'hello')"
  echo "IDEMP=$(show apply_envelope aaaaaaaa t1 '[re:aaaaaaaa] [task:t1] hello')"
  echo "ADDTASK=$(show apply_envelope aaaaaaaa t1 '[re:aaaaaaaa] hello')"
  echo "ADDRE=$(show apply_envelope aaaaaaaa t1 '[task:t1] hello')"
  echo "TASKCONFLICT=$(show apply_envelope aaaaaaaa t2 '[re:aaaaaaaa] [task:t1] hello')"
  echo "TASKCONFLICT_CTRL=$(show apply_envelope aaaaaaaa t1 '[re:aaaaaaaa] [task:t1] hello')"
  echo "REORDER=$(show apply_envelope aaaaaaaa '' '[task:t1] [re:aaaaaaaa] hello')"
  echo "BADTASK=$(show apply_envelope '' 'bad!' 'hello')"
  echo "BADTASK_CTRL=$(show apply_envelope '' 'good-1_x' 'hello')"
  echo "QUOTED=$(show apply_envelope aaaaaaaa t1 'see [re:bbbbbbbb] and [task:zz] in the doc')"
  echo "QUOTED_LEADING=$(show apply_envelope aaaaaaaa '' '[re:bbbbbbbb] see doc')"
  echo "MULTILINE=$(show apply_envelope aaaaaaaa t1 $'first\nsecond')"
  echo "ENVONLY=$(show apply_envelope aaaaaaaa t1 '[re:aaaaaaaa]')"
)
if echo "$ae" | grep -qxF 'BOTH=[[re:aaaaaaaa] [task:t1] hello]' \
   && echo "$ae" | grep -qxF 'TASKONLY=[[task:t1] hello]' \
   && echo "$ae" | grep -qxF 'IDEMP=[[re:aaaaaaaa] [task:t1] hello]' \
   && echo "$ae" | grep -qxF 'ADDTASK=[[re:aaaaaaaa] [task:t1] hello]' \
   && echo "$ae" | grep -qxF 'ADDRE=[[re:aaaaaaaa] [task:t1] hello]' \
   && echo "$ae" | grep -qxF 'TASKCONFLICT=REFUSED' \
   && echo "$ae" | grep -qxF 'TASKCONFLICT_CTRL=[[re:aaaaaaaa] [task:t1] hello]' \
   && echo "$ae" | grep -qxF 'REORDER=REFUSED' \
   && echo "$ae" | grep -qxF 'BADTASK=REFUSED' \
   && echo "$ae" | grep -qxF 'BADTASK_CTRL=[[task:good-1_x] hello]' \
   && echo "$ae" | grep -qxF 'QUOTED=[[re:aaaaaaaa] [task:t1] see [re:bbbbbbbb] and [task:zz] in the doc]' \
   && echo "$ae" | grep -qxF 'QUOTED_LEADING=REFUSED' \
   && echo "$ae" | grep -qF 'MULTILINE=[[re:aaaaaaaa] [task:t1] first' \
   && echo "$ae" | grep -qxF 'ENVONLY=[[re:aaaaaaaa] [task:t1]]'; then
  pass "envelope_apply_compose_and_leading_only"
else
  fail "envelope_apply_compose_and_leading_only" "out=$ae"
fi

# --- log_reply_ids: quoted [re:] mid-body never correlates; leading does ---
lr=$(
  source "$HERE/lib.sh"
  RB=$(mktemp -d); export MESSAGES_DIR="$RB/messages"
  log_reply_ids peer 'thanks, see [re:cafe0001] for context' me 11112222
  log_reply_ids peer '[re:cafe0002] [task:T1] thanks' me 11112223
  log_reply_ids peer '[re:cafe0003] [re:cafe0004] conflicting' me 11112224
  log_reply_ids peer '[task:T1] [re:cafe0005] reordered' me 11112225
  log_reply_ids peer '[task:T1] task only, nothing to correlate' me 11112226
  log_reply_ids peer '[re:cafe0006] [re:cafe0006] dup' me 11112227
  for id in cafe0001 cafe0002 cafe0003 cafe0004 cafe0005 cafe0006; do
    echo "$id=$(awk -F'\t' -v id="$id" '$2 == id' "$MESSAGES_DIR/replies-log.tsv" 2>/dev/null | wc -l | tr -d ' ')"
  done
  awk -F'\t' '$2 == "cafe0002" { print "ROW2=" NF ":" $3 ":" $4 ":" $5 ":" $6 }' "$MESSAGES_DIR/replies-log.tsv"
  rm -rf "$RB"
)
if echo "$lr" | grep -qx 'cafe0001=0' && echo "$lr" | grep -qx 'cafe0002=1' \
   && echo "$lr" | grep -qx 'cafe0003=0' && echo "$lr" | grep -qx 'cafe0004=0' \
   && echo "$lr" | grep -qx 'cafe0005=0' && echo "$lr" | grep -qx 'cafe0006=1' \
   && echo "$lr" | grep -qx 'ROW2=6:peer:T1:me:11112223'; then
  pass "reply_log_leading_only_quoted_and_refused_record_nothing"
else
  fail "reply_log_leading_only_quoted_and_refused_record_nothing" "out=$lr"
fi

# --- sent-log column 8 carries the leading task; quoted/absent tasks do not ---
sl=$(
  source "$HERE/lib.sh"
  RB=$(mktemp -d); export MESSAGES_DIR="$RB/messages"
  log_sent_message s0000001 me peer send live '[re:aaaaaaaa] [task:T7] do it'
  log_sent_message s0000002 me peer send live 'mention [task:T8] in passing'
  log_sent_message s0000003 me peer send live 'plain'
  awk -F'\t' '{ print $2 "=" NF ":" $8 }' "$MESSAGES_DIR/sent-log.tsv"
  rm -rf "$RB"
)
if echo "$sl" | grep -qx 's0000001=8:T7' && echo "$sl" | grep -qx 's0000002=8:' && echo "$sl" | grep -qx 's0000003=8:'; then
  pass "sent_log_task_column_leading_only"
else
  fail "sent_log_task_column_leading_only" "out=$sl"
fi

# --- incoming forms: each is reduced to its BODY, then the leading envelope is
#     read. Every form has a leading (correlates) and a quoted (does not) case. ---
EH="$E_ROOT/in-home"; EM="$EH/.claude/messages"; mkdir -p "$EM/queue"
e_hook() { env HOME="$EH" TMUX="fake,0,0" CLAUDE_PLUGIN_ROOT="$E_PLUG" SESSION_CHAT_PANE_NAME=me \
  SESSION_CHAT_INCOMING_MODE=auto SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS=0 bash "$HERE/detect-incoming-message.sh"; }
e_rows() { awk -F'\t' -v id="$1" '$2 == id' "$EM/replies-log.tsv" 2>/dev/null; }
# e_row_is <reply-id> <from> <task> <recipient> <incoming-id>: exactly one row, 6 columns, all matching.
e_row_is() { e_rows "$1" | awk -F'\t' -v f="$2" -v t="$3" -v r="$4" -v m="$5" \
  'NF == 6 && $3 == f && $4 == t && $5 == r && $6 == m { ok++ } END { exit !(ok == 1) }'; }
e_no_row() { [ -z "$(e_rows "$1")" ]; }

# (1) live raw header form
printf '%s' '[from:peer pane:%1 id:abcd1234abcd1001] [re:11110001] [task:T-live] hello [id:abcd1234abcd1001]' | e_hook >/dev/null
printf '%s' '[from:peer pane:%1 id:abcd1234abcd1002] please see [re:11110002] above [id:abcd1234abcd1002]' | e_hook >/dev/null
printf '%s' '[from:peer pane:%1 id:abcd1234abcd1003] [from:other pane:%2 id:abcd1234abcd1999] [re:11110003] nested header [id:abcd1234abcd1003]' | e_hook >/dev/null
if e_row_is 11110001 peer T-live me abcd1234abcd1001 && e_no_row 11110002 && e_no_row 11110003; then
  pass "incoming_live_raw_header_leading_vs_quoted"
else
  fail "incoming_live_raw_header_leading_vs_quoted" "rows=$(cat "$EM/replies-log.tsv" 2>/dev/null)"
fi

# (2) live provider hook JSON form (prompt field only)
printf '{"hook_event_name":"UserPromptSubmit","prompt":"[from:peer pane:%%1 id:abcd1234abcd2001] [re:22220001] [task:T-json] line1\\nline2 [id:abcd1234abcd2001]"}' | e_hook >/dev/null
printf '{"hook_event_name":"UserPromptSubmit","prompt":"[from:peer pane:%%1 id:abcd1234abcd2002] intro [re:22220002] quoted [id:abcd1234abcd2002]"}' | e_hook >/dev/null
printf '{"hook_event_name":"UserPromptSubmit","prompt":"note [from:peer pane:%%1 id:abcd1234abcd2003] [re:22220003] header not first"}' | e_hook >/dev/null
printf '{"hook_event_name":"UserPromptSubmit","note":"[re:22220004] decoy field","prompt":"[from:peer pane:%%1 id:abcd1234abcd2004] hi [id:abcd1234abcd2004]"}' | e_hook >/dev/null
printf '{"hook_event_name":"UserPromptSubmit","note":"decoy field","prompt":"[from:peer pane:%%1 id:abcd1234abcd2005] [re:22220005] ok [id:abcd1234abcd2005]"}' | e_hook >/dev/null
if e_row_is 22220001 peer T-json me abcd1234abcd2001 && e_no_row 22220002 && e_no_row 22220003 \
   && e_no_row 22220004 && e_row_is 22220005 peer "" me abcd1234abcd2005; then
  pass "incoming_live_provider_json_leading_vs_quoted"
else
  fail "incoming_live_provider_json_leading_vs_quoted" "rows=$(cat "$EM/replies-log.tsv" 2>/dev/null)"
fi

# (3) queued send recovery (Stop hook): the row payload IS the body
(
  source "$HERE/lib.sh"; export MESSAGES_DIR="$EM"; export SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS=0
  enqueue_message me 0a0a0a01 send peer "[re:33330001] [task:T-q] queued body" "$EM"
  enqueue_message me 0a0a0a02 send peer "queued text mentioning [re:33330002] mid-body" "$EM"
  enqueue_message me 0a0a0a03 send peer "[re:33330003] [re:33330004] conflicting" "$EM"
  mark_message_ready me 0a0a0a01 "$EM"; mark_message_ready me 0a0a0a02 "$EM"; mark_message_ready me 0a0a0a03 "$EM"
)
printf '{"hook_event_name":"Stop"}' | e_hook >/dev/null
if e_row_is 33330001 peer T-q me 0a0a0a01 && e_no_row 33330002 && e_no_row 33330003 && e_no_row 33330004; then
  pass "incoming_queued_send_leading_vs_quoted"
else
  fail "incoming_queued_send_leading_vs_quoted" "rows=$(cat "$EM/replies-log.tsv" 2>/dev/null)"
fi

# (4) dispatch files, live notification and queued row
mkf() { printf '%b' "$2" > "$EM/$1"; chmod 600 "$EM/$1"; }
mkf d-live-lead.md '[re:44440001] [task:T-d] do the thing\nmore\n'
mkf d-live-quoted.md 'do the thing\nplease cite [re:44440002]\n'
mkf d-live-firstline-quoted.md 'quoted: [re:44440003] first line\n'
mkf d-q-lead.md '[re:44440004] queued task\n'
mkf d-q-quoted.md 'queued task, ref [re:44440005]\n'
for pair in "d-live-lead.md:abcd1234abcd3001" "d-live-quoted.md:abcd1234abcd3002" "d-live-firstline-quoted.md:abcd1234abcd3003"; do
  printf '{"hook_event_name":"UserPromptSubmit","prompt":"[from:peer pane:%%1 msg:%s id:%s] dispatch (2 lines) — read msg file for full task id:%s"}' \
    "$EM/${pair%%:*}" "${pair##*:}" "${pair##*:}" | e_hook >/dev/null
done
(
  source "$HERE/lib.sh"; export MESSAGES_DIR="$EM"; export SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS=0
  enqueue_message me 0b0b0b01 dispatch peer "$EM/d-q-lead.md" "$EM"
  enqueue_message me 0b0b0b02 dispatch peer "$EM/d-q-quoted.md" "$EM"
  mark_message_ready me 0b0b0b01 "$EM"; mark_message_ready me 0b0b0b02 "$EM"
)
printf '{"hook_event_name":"Stop"}' | e_hook >/dev/null
if e_row_is 44440001 peer T-d me abcd1234abcd3001 && e_no_row 44440002 && e_no_row 44440003 \
   && e_row_is 44440004 peer "" me 0b0b0b01 && e_no_row 44440005; then
  pass "incoming_dispatch_file_live_and_queued_leading_vs_quoted"
else
  fail "incoming_dispatch_file_live_and_queued_leading_vs_quoted" "rows=$(cat "$EM/replies-log.tsv" 2>/dev/null)"
fi

# --- check-replies: multi-task associations and --task filter ---
MT_HOME="$E_ROOT/mt-home"; MT_MSGS="$MT_HOME/.claude/messages"; mkdir -p "$MT_MSGS"
(
  source "$HERE/lib.sh"; export MESSAGES_DIR="$MT_MSGS"
  log_sent_message a1b2c3d4 me peer send live "do the four things"
  log_sent_message a1b2c3d5 me peer send live "one plain request"
  for t in T1 T2 T3 T4; do
    log_reply_ids peer "[re:a1b2c3d4] [task:$t] done $t" me "5555000${t#T}"
  done
  log_reply_ids peer "[re:a1b2c3d5] ok" me 55550009
)
mt_out=$(env HOME="$MT_HOME" bash "$HERE/check-replies.sh" 2>&1)
mt_four=$(printf '%s\n' "$mt_out" | awk -F'\t' '$1 == "a1b2c3d4" && $6 == "verified:peer" { printf "%s,", $8 }')
mt_one=$(printf '%s\n' "$mt_out" | awk -F'\t' '$1 == "a1b2c3d5" { printf "%s|%s;", $6, $8 }')
mt_filt=$(env HOME="$MT_HOME" bash "$HERE/check-replies.sh" --task T2 2>&1)
mt_none=$(env HOME="$MT_HOME" bash "$HERE/check-replies.sh" --task T99 2>&1)
if [ "$mt_four" = "T1,T2,T3,T4," ] && [ "$mt_one" = "verified:peer|;" ] \
   && [ "$(printf '%s\n' "$mt_filt" | awk -F'\t' '$1 == "a1b2c3d4" { c++ } END { print c+0 }')" = "1" ] \
   && printf '%s\n' "$mt_filt" | awk -F'\t' '$1 == "a1b2c3d4" && $8 == "T2" { ok = 1 } END { exit !ok }' \
   && ! printf '%s\n' "$mt_filt" | grep -q 'a1b2c3d5' \
   && printf '%s\n' "$mt_none" | grep -q 'tagged \[task:T99\]'; then
  pass "check_replies_multi_task_associations_and_filter"
else
  fail "check_replies_multi_task_associations_and_filter" "four=$mt_four one=$mt_one filt=$mt_filt none=$mt_none"
fi

# --- check-replies: expected-peer verification (refusals paired with controls) ---
VF_HOME="$E_ROOT/vf-home"; VF_MSGS="$VF_HOME/.claude/messages"; mkdir -p "$VF_MSGS"
vf_now=$(( $(date +%s) * 1000 ))
vsent() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$vf_now" "$1" me peer send live "req $1" "" >> "$VF_MSGS/sent-log.tsv"; }
vrep() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$vf_now" "$1" "$2" "" "$3" "abcdef01" >> "$VF_MSGS/replies-log.tsv"; }
for i in a0000001 b0000002 c0000003 d0000004 e0000005 f0000006 a0000008; do vsent "$i"; done
# legacy 7-column sent rows (no task column)
for i in a0000007 a0000009; do printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$vf_now" "$i" me peer send live "legacy $i" >> "$VF_MSGS/sent-log.tsv"; done
vrep a0000001 peer me                       # control: from the recipient, received by the sender
vrep b0000002 mallory me                    # reply from a non-recipient
vrep c0000003 peer other                    # recipient replied, but recorded as received elsewhere
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$vf_now" d0000004 peer "" "" "" >> "$VF_MSGS/replies-log.tsv"   # new row, empty recipient
vrep e0000005 mallory me                    # unexpected FIRST ...
vrep e0000005 peer me                       # ... valid LATER
vrep f0000006 peer me                       # control: valid alone
printf '%s\t%s\t%s\n' "$vf_now" a0000007 peer >> "$VF_MSGS/replies-log.tsv"      # legacy 3-column, right sender
printf '%s\t%s\t%s\n' "$vf_now" a0000008 mallory >> "$VF_MSGS/replies-log.tsv"   # legacy 3-column, wrong sender
vrep a0000009 peer me                       # new reply against a legacy 7-column sent row
vf_out=$(env HOME="$VF_HOME" bash "$HERE/check-replies.sh" 2>&1)
vf_pend=$(env HOME="$VF_HOME" bash "$HERE/check-replies.sh" --pending 2>&1)
vcol() { printf '%s\n' "$vf_out" | awk -F'\t' -v id="$1" '$1 == id { print $6 }'; }
vf_bad=""
vexp() { # vexp <id> <must-match-regex>... ; also reports unexpected extras
  local id="$1" rx; shift
  for rx in "$@"; do vcol "$id" | grep -qE -- "$rx" || vf_bad="$vf_bad $id:missing($rx)"; done
}
vnot() { local id="$1" rx="$2"; ! vcol "$id" | grep -qE -- "$rx" || vf_bad="$vf_bad $id:unwanted($rx)"; }
vexp a0000001 '^verified:peer$';                      vnot a0000001 'unconfirmed|^unexpected'
vexp b0000002 '^unconfirmed$' '^unexpected:mallory \(not the recipient'; vnot b0000002 '^verified:|^replied'
vexp c0000003 '^unconfirmed$' "^unexpected:peer \(received by 'other'"; vnot c0000003 '^verified:|^replied'
vexp d0000004 '^unconfirmed$' '^unexpected:peer \(no recipient context'; vnot d0000004 '^verified:|^replied'
vexp e0000005 '^verified:peer$' '^unexpected:mallory';  vnot e0000005 'unconfirmed'
vexp f0000006 '^verified:peer$';                      vnot f0000006 'unconfirmed|unexpected'
vexp a0000007 '^replied \(recipient-unknown\):peer$'; vnot a0000007 '^verified|unconfirmed|unexpected'
vexp a0000008 '^unconfirmed$' '^unexpected:mallory';  vnot a0000008 '^verified:|^replied'
vexp a0000009 '^verified:peer$'
pend_ids=$(printf '%s\n' "$vf_pend" | awk -F'\t' 'NR > 1 && $1 ~ /^[a-f0-9]{8}$/ { print $1 }' | sort -u | tr '\n' ' ')
if [ -z "$vf_bad" ] && [ "$pend_ids" = "a0000008 b0000002 c0000003 d0000004 " ]; then
  pass "check_replies_expected_peer_verification"
else
  fail "check_replies_expected_peer_verification" "bad=$vf_bad pend=$pend_ids out=$vf_out"
fi

# --- 8-hex (legacy) and 16-hex ids through every id-consuming path ---
RT_BAD=""
for RT_ID in 1a2b3c4d 0123456789abcdef; do
  RT_HOME="$E_ROOT/rt-home-$RT_ID"; RT_MSGS="$RT_HOME/.claude/messages"; mkdir -p "$RT_MSGS/queue"
  RT_Q="${RT_ID%?}0"   # distinct queued id of the same length
  rt_hook() { env HOME="$RT_HOME" TMUX="fake,0,0" CLAUDE_PLUGIN_ROOT="$E_PLUG" SESSION_CHAT_PANE_NAME=me \
    SESSION_CHAT_INCOMING_MODE=notify SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS=0 bash "$HERE/detect-incoming-message.sh"; }
  # live hook read
  live=$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"[from:peer pane:%%1 id:%s] [re:%s] ping [id:%s]"}' "$RT_ID" "$RT_ID" "$RT_ID" | rt_hook)
  echo "$live" | grep -qF "use /reply peer $RT_ID " || RT_BAD="$RT_BAD $RT_ID:live-hint"
  grep -qxF "$RT_ID" <(cut -f1 "$RT_MSGS/queue/.recent-me.tsv" 2>/dev/null) || RT_BAD="$RT_BAD $RT_ID:live-recent"
  awk -F'\t' -v id="$RT_ID" '$2 == id && $6 == id && $5 == "me" { ok = 1 } END { exit !ok }' "$RT_MSGS/replies-log.tsv" 2>/dev/null || RT_BAD="$RT_BAD $RT_ID:live-replyrow"
  # queued recovery (Stop)
  ( source "$HERE/lib.sh"; export MESSAGES_DIR="$RT_MSGS" SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS=0
    enqueue_message me "$RT_Q" send peer "queued ping" "$RT_MSGS"; mark_message_ready me "$RT_Q" "$RT_MSGS" )
  queued=$(printf '{"hook_event_name":"Stop"}' | rt_hook)
  echo "$queued" | grep -qF "use /reply peer $RT_Q " || RT_BAD="$RT_BAD $RT_ID:queued-hint"
  grep -qxF "$RT_Q" <(cut -f1 "$RT_MSGS/queue/.recent-me.tsv" 2>/dev/null) || RT_BAD="$RT_BAD $RT_ID:queued-recent"
  [ -z "$(grep -F "$RT_Q" "$RT_MSGS/queue/me.tsv" 2>/dev/null)" ] || RT_BAD="$RT_BAD $RT_ID:queued-not-drained"
  # archive + message-search
  srch=$(env HOME="$RT_HOME" bash "$HERE/message-search.sh" "$RT_ID" 2>&1)
  srch_q=$(env HOME="$RT_HOME" bash "$HERE/message-search.sh" "$RT_Q" 2>&1)
  echo "$srch" | awk -F'\t' -v id="$RT_ID" '$2 == "in" && $5 == id { ok = 1 } END { exit !ok }' || RT_BAD="$RT_BAD $RT_ID:search-live"
  echo "$srch_q" | awk -F'\t' -v id="$RT_Q" '$2 == "in" && $5 == id { ok = 1 } END { exit !ok }' || RT_BAD="$RT_BAD $RT_ID:search-queued"
  # messages-clean / messages-list parse the <epoch>-<pid>-<id>-<from>-to-<to>.md name
  old_file="$RT_MSGS/$(( $(date +%s) - 20 * 86400 ))-4242-${RT_ID}-peer-to-me.md"
  printf 'old body\n' > "$old_file"; chmod 600 "$old_file"
  lst=$(env HOME="$RT_HOME" bash "$HERE/messages-list.sh" --from peer 2>&1)
  echo "$lst" | grep -qF "$(basename "$old_file")" || RT_BAD="$RT_BAD $RT_ID:list-from"
  dry=$(env HOME="$RT_HOME" bash "$HERE/messages-clean.sh" --older-than 7 --from peer 2>&1)
  echo "$dry" | grep -qF "$(basename "$old_file")" || RT_BAD="$RT_BAD $RT_ID:clean-from"
  ctl=$(env HOME="$RT_HOME" bash "$HERE/messages-clean.sh" --older-than 7 --from nobody 2>&1)   # control: parsing is not a match-all
  echo "$ctl" | grep -qF "$(basename "$old_file")" && RT_BAD="$RT_BAD $RT_ID:clean-ctl"
  env HOME="$RT_HOME" bash "$HERE/messages-clean.sh" --older-than 7 --from peer --apply >/dev/null 2>&1
  [ ! -e "$old_file" ] || RT_BAD="$RT_BAD $RT_ID:clean-apply"
  # explicit --reply-to (+ --task) through the real transport into a live pane
  rt_send=$(
    TMUX_PANE="$SENDER_PANE" SESSION_CHAT_ALLOW_SHELL_TARGET=1 \
    SESSION_CHAT_VERIFY_TIMEOUT_MS=1500 SESSION_CHAT_SETTLE_MS=50 \
    SESSION_CHAT_TARGET_MESSAGES_DIR="$RT_MSGS" \
    TMUX="$(tmux -L "$SOCKET" display-message -p '#{socket_path}'),0,0" \
    bash -c "
      tmux() { command tmux -L '$SOCKET' \"\$@\"; }
      export -f tmux
      bash '$HERE/send-message.sh' --reply-to '$RT_ID' --task T-rt alpha 'rt-ack-$RT_ID'
    " 2>&1
  )
  echo "$rt_send" | grep -q '^Sent to alpha' || RT_BAD="$RT_BAD $RT_ID:send-rc($rt_send)"
  cap_wait "$RECIPIENT_PANE" "[re:$RT_ID] [task:T-rt] rt-ack-$RT_ID" >/dev/null || RT_BAD="$RT_BAD $RT_ID:send-envelope-not-in-pane"
  awk -F'\t' -v id="$RT_ID" 'NF == 8 && $2 ~ /^[a-f0-9]{16}$/ && $7 ~ ("^\\[re:" id "\\] \\[task:T-rt\\] rt-ack") && $8 == "T-rt" { ok = 1 } END { exit !ok }' "$RT_MSGS/sent-log.tsv" || RT_BAD="$RT_BAD $RT_ID:sent-log"
  # the same envelope read back by the receiving hook
  printf '{"hook_event_name":"UserPromptSubmit","prompt":"[from:sender pane:%%1 id:abcd1234abcd9999] [re:%s] [task:T-rt] rt-ack [id:abcd1234abcd9999]"}' "$RT_ID" | rt_hook >/dev/null
  awk -F'\t' -v id="$RT_ID" '$2 == id && $3 == "sender" && $4 == "T-rt" { ok = 1 } END { exit !ok }' "$RT_MSGS/replies-log.tsv" || RT_BAD="$RT_BAD $RT_ID:roundtrip-reply"
  # strict-v1 grammar (read-only): REPLY_RE and MESSAGE_NAME_RE accept this id
  env PYTHONDONTWRITEBYTECODE=1 python3 -B -I -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hp", sys.argv[1])
m = importlib.util.module_from_spec(spec); sys.modules["hp"] = m; spec.loader.exec_module(m)
i = sys.argv[2]
sys.exit(0 if m.REPLY_RE.fullmatch(i) and m.MESSAGE_NAME_RE.fullmatch("1700000000-4242-%s-peer-to-me.md" % i) else 1)
' "$HERE/../../session-workspace/scripts/harness-policy.py" "$RT_ID" || RT_BAD="$RT_BAD $RT_ID:strict-v1-grammar"
done
if [ -z "$RT_BAD" ]; then
  pass "message_ids_8hex_and_16hex_roundtrip"
else
  fail "message_ids_8hex_and_16hex_roundtrip" "bad=$RT_BAD"
fi

# --- dispatch --task/--reply-to writes the envelope at the top of the file ---
DT_MSGS="$E_ROOT/dt-msgs"; DT_PF="$E_ROOT/dt-prompt.txt"
printf 'line one\nsee [re:deadbeef] quoted\n' > "$DT_PF"
dt_out=$(
  TMUX_PANE="$SENDER_PANE" SESSION_CHAT_ALLOW_SHELL_TARGET=1 \
  SESSION_CHAT_VERIFY_TIMEOUT_MS=1000 SESSION_CHAT_SETTLE_MS=50 \
  SESSION_CHAT_TARGET_MESSAGES_DIR="$DT_MSGS" \
  TMUX="$(tmux -L "$SOCKET" display-message -p '#{socket_path}'),0,0" \
  bash -c "
    tmux() { command tmux -L '$SOCKET' \"\$@\"; }
    export -f tmux
    bash '$HERE/dispatch-to-session.sh' --reply-to 0123456789abcdef --task T-disp alpha '$DT_PF'
  " 2>&1
)
dt_file=$(find "$DT_MSGS" -maxdepth 1 -name '*.md' 2>/dev/null | head -1)
dt_bad_out=$(
  TMUX_PANE="$SENDER_PANE" bash "$HERE/dispatch-to-session.sh" --task 'bad!' alpha "$DT_PF" 2>&1; echo "rc=$?"
)
if echo "$dt_out" | grep -q "^Dispatched task to 'alpha'" && [ -n "$dt_file" ] \
   && [ "$(head -1 "$dt_file")" = '[re:0123456789abcdef] [task:T-disp] line one' ] \
   && grep -qxF 'see [re:deadbeef] quoted' "$dt_file" \
   && echo "$dt_bad_out" | grep -q -- '--task expects' && echo "$dt_bad_out" | grep -q 'rc=1'; then
  pass "dispatch_task_envelope_at_top_and_bad_task_refused"
else
  fail "dispatch_task_envelope_at_top_and_bad_task_refused" "out=$dt_out file=$dt_file head=$(head -3 "$dt_file" 2>/dev/null) bad=$dt_bad_out"
fi

# --- generate_id: 16 lowercase hex from urandom only; fails closed otherwise ---
GI_SHIM="$E_ROOT/od-shim"; mkdir -p "$GI_SHIM"
gi_shim() { printf '#!/bin/sh\n%s\n' "$1" > "$GI_SHIM/od"; chmod +x "$GI_SHIM/od"; }
gi_run() { PATH="$GI_SHIM:$PATH" bash -c 'source "$1"; id=$(generate_id); rc=$?; printf "%s|%s" "$rc" "$id"' _ "$HERE/lib.sh"; }
gi_ok=$(bash -c 'source "$1"; a=$(generate_id); b=$(generate_id); printf "%s %s" "$a" "$b"' _ "$HERE/lib.sh")
gi_bad=""
read -r gi_a gi_b <<< "$gi_ok"
{ [[ "${gi_a:-}" =~ ^[a-f0-9]{16}$ ]] && [[ "${gi_b:-}" =~ ^[a-f0-9]{16}$ ]] && [ "${gi_a:-}" != "${gi_b:-}" ]; } || gi_bad="$gi_bad normal($gi_ok)"
gi_shim 'exit 1';                                       [ "$(gi_run)" = "1|" ] || gi_bad="$gi_bad od-fails($(gi_run))"
gi_shim 'printf " ab cd\n"';                            [ "$(gi_run)" = "1|" ] || gi_bad="$gi_bad short($(gi_run))"
gi_shim 'printf " zz zz zz zz zz zz zz zz\n"';          [ "$(gi_run)" = "1|" ] || gi_bad="$gi_bad nonhex($(gi_run))"
gi_shim 'printf " AB CD EF 01 23 45 67 89\n"';          [ "$(gi_run)" = "1|" ] || gi_bad="$gi_bad uppercase($(gi_run))"
gi_shim 'printf " 01 23 45 67 89 ab cd ef 00\n"';       [ "$(gi_run)" = "1|" ] || gi_bad="$gi_bad long($(gi_run))"
gi_shim 'printf " 01 23 45 67 89 ab cd ef\n"';          [ "$(gi_run)" = "0|0123456789abcdef" ] || gi_bad="$gi_bad shim-control($(gi_run))"
GI_NOOD="$E_ROOT/no-od"; mkdir -p "$GI_NOOD"; ln -sf "$(command -v tr)" "$GI_NOOD/tr"
[ "$(PATH="$GI_NOOD" "$BASH" -c 'source "$1"; id=$(generate_id); rc=$?; printf "%s|%s" "$rc" "$id"' _ "$HERE/lib.sh")" = "1|" ] || gi_bad="$gi_bad no-od"
if [ -z "$gi_bad" ]; then
  pass "generate_id_16hex_urandom_only_fails_closed"
else
  fail "generate_id_16hex_urandom_only_fails_closed" "bad=$gi_bad"
fi

# --- send/dispatch abort BEFORE writing or sending when no id can be made ---
tree_state() { { find "$TEST_MSGS_DIR" 2>/dev/null | sort; cat "$TEST_MSGS_DIR/sent-log.tsv" 2>/dev/null; } | cksum; }
gi_shim 'exit 1'
ab_before=$(tree_state)
ab_send=$(PATH="$GI_SHIM:$PATH" run_lib "$SENDER_PANE" "send_message alpha 'abort-send-marker'" 2>&1); ab_send_rc=$?
ab_disp=$(PATH="$GI_SHIM:$PATH" run_lib "$SENDER_PANE" "dispatch_message alpha 'abort-dispatch-marker'" 2>&1); ab_disp_rc=$?
ab_after=$(tree_state)
sleep 0.3
ab_cap=$(cap "$RECIPIENT_PANE")
# control: the same calls with a working od succeed and DO change the tree / pane
SESSION_CHAT_VERIFY_TIMEOUT_MS=1500 run_lib "$SENDER_PANE" "send_message alpha 'abort-ctl-send-marker'" >/dev/null 2>&1; ok_send_rc=$?
SESSION_CHAT_VERIFY_TIMEOUT_MS=1500 run_lib "$SENDER_PANE" "dispatch_message alpha 'abort-ctl-dispatch-marker'" >/dev/null 2>&1; ok_disp_rc=$?
ok_after=$(tree_state)
if [ "$ab_send_rc" -ne 0 ] && echo "$ab_send" | grep -q 'could not generate a message id' \
   && [ "$ab_disp_rc" -ne 0 ] && echo "$ab_disp" | grep -q 'could not generate a message id' \
   && [ "$ab_before" = "$ab_after" ] \
   && ! echo "$ab_cap" | grep -q 'abort-send-marker' && ! echo "$ab_cap" | grep -q 'abort-dispatch' \
   && [ "$ok_send_rc" -eq 0 ] && [ "$ok_disp_rc" -eq 0 ] && [ "$ab_after" != "$ok_after" ] \
   && cap_wait "$RECIPIENT_PANE" 'abort-ctl-send-marker' >/dev/null; then
  pass "send_dispatch_abort_without_writing_when_id_unavailable"
else
  fail "send_dispatch_abort_without_writing_when_id_unavailable" "send(rc=$ab_send_rc)=$ab_send disp(rc=$ab_disp_rc)=$ab_disp same=$([ "$ab_before" = "$ab_after" ] && echo y || echo n) ctl=$ok_send_rc/$ok_disp_rc"
fi

# ===========================================================================
# Review fixes R1-R4 (session-chat). Each refusal has a paired control.
# ===========================================================================

# --- R1: sender, id and body are bound from ONE parsed header of the
#     authoritative prompt; a decoy in another JSON field supplies nothing ---
D_HOME="$E_ROOT/decoy-home"; D_MSGS="$D_HOME/.claude/messages"; mkdir -p "$D_MSGS/queue"
d_hook() { env HOME="$D_HOME" TMUX="fake,0,0" CLAUDE_PLUGIN_ROOT="$E_PLUG" SESSION_CHAT_PANE_NAME=me \
  SESSION_CHAT_INCOMING_MODE=auto SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS=0 bash "$HERE/detect-incoming-message.sh"; }
d_rows() { awk -F'\t' -v id="$1" '$2 == id' "$D_MSGS/replies-log.tsv" 2>/dev/null; }
d_row_is() { d_rows "$1" | awk -F'\t' -v f="$2" -v m="$3" 'NF == 6 && $3 == f && $5 == "me" && $6 == m { ok++ } END { exit !(ok == 1) }'; }
# (a) live send: decoy metadata field BEFORE the real prompt
d_out_a=$(printf '{"hook_event_name":"UserPromptSubmit","meta":"[from:peer pane:%%1 id:11111111] ignored","prompt":"[from:attacker pane:%%2 id:22222222] [re:aaaa1111] body [id:22222222]"}' | d_hook)
# control: the same input without the decoy field
d_out_b=$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"[from:attacker pane:%%2 id:22222223] [re:aaaa1112] body [id:22222223]"}' | d_hook)
if d_row_is aaaa1111 attacker 22222222 && d_row_is aaaa1112 attacker 22222223 \
   && ! grep -q 'peer' "$D_MSGS/replies-log.tsv" && ! grep -q '11111111' "$D_MSGS/replies-log.tsv" \
   && echo "$d_out_a" | grep -qF '[attacker]' && ! echo "$d_out_a" | grep -qF '[peer]' \
   && echo "$d_out_a" | grep -qF '/reply attacker 22222222 ' && echo "$d_out_b" | grep -qF '/reply attacker 22222223 '; then
  pass "incoming_live_send_metadata_decoy_ignored_with_control"
else
  fail "incoming_live_send_metadata_decoy_ignored_with_control" "rows=$(cat "$D_MSGS/replies-log.tsv" 2>/dev/null) out=$d_out_a"
fi
# (b) dispatch notification: decoy header (pointing at a different trusted file) before the real prompt
printf '[re:bbbb2222] real task\n' > "$D_MSGS/real-task.md"; chmod 600 "$D_MSGS/real-task.md"
printf '[re:cccc3333] decoy task\n' > "$D_MSGS/decoy-task.md"; chmod 600 "$D_MSGS/decoy-task.md"
d_out_c=$(printf '{"hook_event_name":"UserPromptSubmit","meta":"[from:peer pane:%%1 msg:%s id:11111111] x","prompt":"[from:attacker pane:%%2 msg:%s id:22222224] dispatch (1 lines) — read msg file for full task id:22222224"}' \
  "$D_MSGS/decoy-task.md" "$D_MSGS/real-task.md" | d_hook)
printf '[re:bbbb2223] control task\n' > "$D_MSGS/control-task.md"; chmod 600 "$D_MSGS/control-task.md"
d_out_d=$(printf '{"hook_event_name":"UserPromptSubmit","prompt":"[from:attacker pane:%%2 msg:%s id:22222225] dispatch (1 lines) — read msg file for full task id:22222225"}' \
  "$D_MSGS/control-task.md" | d_hook)
if d_row_is bbbb2222 attacker 22222224 && d_row_is bbbb2223 attacker 22222225 && [ -z "$(d_rows cccc3333)" ] \
   && echo "$d_out_c" | grep -qF 'real-task.md' && ! echo "$d_out_c" | grep -qF 'decoy-task.md' \
   && echo "$d_out_c" | grep -qF 'dispatch from [attacker]' && ! echo "$d_out_c" | grep -qF '[peer]' \
   && echo "$d_out_d" | grep -qF 'control-task.md'; then
  pass "incoming_dispatch_notification_metadata_decoy_ignored_with_control"
else
  fail "incoming_dispatch_notification_metadata_decoy_ignored_with_control" "rows=$(cat "$D_MSGS/replies-log.tsv" 2>/dev/null) out=$d_out_c"
fi

# --- R2: file names are split as epoch, pid, ONE id, then <from>-to-<to> ---
FN_HOME="$E_ROOT/fn-home"; FN_MSGS="$FN_HOME/.claude/messages"; mkdir -p "$FN_MSGS"
fn_files="1-123-0123456789abcdef-deadbeefdeadbeef-worker-to-alpha.md 1-123-0123456789abcdef-worker-to-alpha.md 1-123-0123456789abcdef-12345678-worker-to-alpha.md 1-worker-to-alpha.md 1-deadbeef-worker-to-alpha.md"
for f in $fn_files; do printf 'body\n' > "$FN_MSGS/$f"; chmod 600 "$FN_MSGS/$f"; done
fn_ls() { env HOME="$FN_HOME" bash "$HERE/messages-list.sh" "$@" 2>&1 | awk -F'\t' 'NR > 1 && $5 ~ /\.md$/ { print $5 }' | sort | tr '\n' ' '; }
fn_dry() { env HOME="$FN_HOME" bash "$HERE/messages-clean.sh" --older-than 0 "$@" 2>&1 | grep -E '^  [0-9]+-.*\.md$' | sed 's/^  //' | sort | tr '\n' ' '; }
fn_left() { find "$FN_MSGS" -maxdepth 1 -name '*.md' -exec basename {} \; | sort | tr '\n' ' '; }
F1=1-123-0123456789abcdef-deadbeefdeadbeef-worker-to-alpha.md
F2=1-123-0123456789abcdef-worker-to-alpha.md
F3=1-123-0123456789abcdef-12345678-worker-to-alpha.md
F4=1-worker-to-alpha.md
F5=1-deadbeef-worker-to-alpha.md
fn_bad=""
[ "$(fn_ls --from worker)" = "$F2 $F4 " ] || fn_bad="$fn_bad list-worker($(fn_ls --from worker))"
[ "$(fn_ls --from deadbeefdeadbeef-worker)" = "$F1 " ] || fn_bad="$fn_bad list-hexsender"
[ "$(fn_ls --from 12345678-worker)" = "$F3 " ] || fn_bad="$fn_bad list-numsender"
[ "$(fn_ls --from deadbeef-worker)" = "$F5 " ] || fn_bad="$fn_bad list-legacy-hexsender"
[ -z "$(fn_ls --from nobody)" ] || fn_bad="$fn_bad list-control"
[ "$(fn_ls --to alpha | wc -w | tr -d ' ')" = "5" ] || fn_bad="$fn_bad list-to"
[ "$(fn_dry --from worker)" = "$F2 $F4 " ] || fn_bad="$fn_bad dry-worker($(fn_dry --from worker))"
[ -z "$(fn_dry --from nobody)" ] || fn_bad="$fn_bad dry-control"
env HOME="$FN_HOME" bash "$HERE/messages-clean.sh" --older-than 0 --from worker --apply >/dev/null 2>&1
[ "$(fn_left)" = "$(printf '%s\n' $F1 $F3 $F5 | sort | tr '\n' ' ')" ] || fn_bad="$fn_bad apply-worker-left($(fn_left))"
env HOME="$FN_HOME" bash "$HERE/messages-clean.sh" --older-than 0 --from deadbeefdeadbeef-worker --apply >/dev/null 2>&1
[ "$(fn_left)" = "$(printf '%s\n' $F3 $F5 | sort | tr '\n' ' ')" ] || fn_bad="$fn_bad apply-hex-left($(fn_left))"
if [ -z "$fn_bad" ]; then
  pass "messages_clean_list_exact_sender_hexlike_and_numeric"
else
  fail "messages_clean_list_exact_sender_hexlike_and_numeric" "bad=$fn_bad"
fi

# --- R3: a failing od with plausible output never yields an id (no pipefail) ---
R3_SHIM="$E_ROOT/r3-shim"; mkdir -p "$R3_SHIM"
r3_od() { printf '#!/bin/sh\nprintf " 01 23 45 67 89 ab cd ef\\n"\nexit %s\n' "$1" > "$R3_SHIM/od"; chmod +x "$R3_SHIM/od"; }
R3_MSGS="$E_ROOT/r3-msgs"; mkdir -p "$R3_MSGS"; R3_PF="$E_ROOT/r3-prompt.txt"; printf 'r3 body\n' > "$R3_PF"
printf '%s\n' '#!/usr/bin/env bash' 'tmux() { command tmux -L "$R3_SOCK" "$@"; }' 'export -f tmux' 'exec bash "$@"' > "$E_ROOT/r3run.sh"
r3_wrap() { # r3_wrap <script> <args...> — the real wrapper against the test tmux, with the shimmed od first on PATH
  local script="$1"; shift
  TMUX_PANE="$SENDER_PANE" SESSION_CHAT_ALLOW_SHELL_TARGET=1 SESSION_CHAT_VERIFY_TIMEOUT_MS=1500 SESSION_CHAT_SETTLE_MS=50 \
  SESSION_CHAT_TARGET_MESSAGES_DIR="$R3_MSGS" PATH="$R3_SHIM:$PATH" R3_SOCK="$SOCKET" \
  TMUX="$(tmux -L "$SOCKET" display-message -p '#{socket_path}'),0,0" \
  bash "$E_ROOT/r3run.sh" "$HERE/$script" "$@" 2>&1
}
r3_tree() { find "$R3_MSGS" 2>/dev/null | sort | cksum; }
r3_bad=""
r3_od 1
rg=$(PATH="$R3_SHIM:$PATH" bash -c 'source "$1"; id=$(generate_id); echo "$?|$id"' _ "$HERE/lib.sh")
[ "$rg" = "1|" ] || r3_bad="$r3_bad generate_id($rg)"
before=$(r3_tree)
s_out=$(r3_wrap send-message.sh alpha 'r3-send-marker'); s_rc=$?
d_out=$(r3_wrap dispatch-to-session.sh alpha "$R3_PF"); d_rc=$?
{ [ "$s_rc" != 0 ] && echo "$s_out" | grep -q 'could not generate a message id' && [ "$d_rc" != 0 ] && echo "$d_out" | grep -q 'could not generate a message id' && [ "$before" = "$(r3_tree)" ]; } \
  || r3_bad="$r3_bad failing-od(send rc=$s_rc out=$s_out; disp rc=$d_rc out=$d_out)"
# control: the same plausible output with exit 0 is accepted and the wrappers deliver
r3_od 0
rg=$(PATH="$R3_SHIM:$PATH" bash -c 'source "$1"; id=$(generate_id); echo "$?|$id"' _ "$HERE/lib.sh")
[ "$rg" = "0|0123456789abcdef" ] || r3_bad="$r3_bad control-generate_id($rg)"
s_out=$(r3_wrap send-message.sh alpha 'r3-send-ok-marker'); s_rc=$?
d_out=$(r3_wrap dispatch-to-session.sh alpha "$R3_PF"); d_rc=$?
{ [ "$s_rc" = 0 ] && echo "$s_out" | grep -q '^Sent to alpha' && [ "$d_rc" = 0 ] && echo "$d_out" | grep -q "^Dispatched task to 'alpha'" && [ "$before" != "$(r3_tree)" ]; } \
  || r3_bad="$r3_bad control-wrappers(send rc=$s_rc out=$s_out; disp rc=$d_rc out=$d_out)"
if [ -z "$r3_bad" ]; then
  pass "generate_id_failing_od_with_output_aborts_through_wrappers"
else
  fail "generate_id_failing_od_with_output_aborts_through_wrappers" "bad=$r3_bad"
fi

# --- R4: a read-limited prefix never validates an envelope whose extent is unknown ---
R4=$(
  source "$HERE/lib.sh"
  RB=$(mktemp -d); export MESSAGES_DIR="$RB/messages"
  n=0
  try() { # try <label> <scan-bytes> <file-content>  -> "<label>=<rows>" (rows recorded for reply ids a/b)
    n=$((n + 1)); local f="$RB/f$n.md"
    printf '%s' "$3" > "$f"
    mkdir -p "$MESSAGES_DIR"; : > "$MESSAGES_DIR/replies-log.tsv"
    SESSION_CHAT_REPLY_SCAN_BYTES="$2" log_reply_ids_from_file peer "$f" me 12345678
    echo "$1=$(awk -F'\t' '{ printf "%s/%s;", $2, $4 }' "$MESSAGES_DIR/replies-log.tsv")"
  }
  try glued_cut_at_boundary 13 '[re:aaaaaaaa]suffix'
  try glued_control_short 4096 '[re:aaaaaaaa] suffix'
  try exact_undecided_at_cap 14 '[re:aaaaaaaa] body-text'
  try exact_decided_one_past 15 '[re:aaaaaaaa] body-text'
  try exact_full_budget 4096 '[re:aaaaaaaa] body-text'
  try whole_file_fits 23 '[re:aaaaaaaa] body-text'
  big=$(printf 'x%.0s' $(seq 1 100))
  try task_crossing_cap 60 "[re:aaaaaaaa] [task:${big}] body"
  try task_complete_control 4096 "[re:aaaaaaaa] [task:${big}] body"
  many=$(printf '[re:aaaaaaaa] %.0s' $(seq 1 300))
  try conflict_beyond_cap 4096 "${many}[re:bbbbbbbb] body"
  few=$(printf '[re:aaaaaaaa] %.0s' $(seq 1 100))
  try many_tokens_decided_control 4096 "${few}body"
  try short_conflict_control 4096 '[re:aaaaaaaa] [re:bbbbbbbb] body'
  rm -rf "$RB"
)
if echo "$R4" | grep -qx 'glued_cut_at_boundary=' && echo "$R4" | grep -qx 'glued_control_short=aaaaaaaa/;' \
   && echo "$R4" | grep -qx 'exact_undecided_at_cap=' && echo "$R4" | grep -qx 'exact_decided_one_past=aaaaaaaa/;' \
   && echo "$R4" | grep -qx 'exact_full_budget=aaaaaaaa/;' && echo "$R4" | grep -qx 'whole_file_fits=aaaaaaaa/;' \
   && echo "$R4" | grep -qx 'task_crossing_cap=' && echo "$R4" | grep -q '^task_complete_control=aaaaaaaa/x\{100\};$' \
   && echo "$R4" | grep -qx 'conflict_beyond_cap=' && echo "$R4" | grep -qx 'many_tokens_decided_control=aaaaaaaa/;' \
   && echo "$R4" | grep -qx 'short_conflict_control='; then
  pass "reply_scan_prefix_undecided_envelope_records_nothing"
else
  fail "reply_scan_prefix_undecided_envelope_records_nothing" "out=$R4"
fi

rm -rf "$E_ROOT"

# --- Summary ---
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
