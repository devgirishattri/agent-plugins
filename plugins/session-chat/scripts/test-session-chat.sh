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
  tmux -L "$SOCKET" capture-pane -t "$1" -p -S -200 2>/dev/null
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
  enqueue_message me cs1 send peer "ACK-BODY [re:deadbeef01]" "$CS_MSGS"
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
# Exactly-one leading token; repeated same-id tokens collapse; a conflicting
# different token is refused; malformed ids fail closed.
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
   && echo "$ar" | grep -qF 'MID=[[re:deadbeef] foo bar]' \
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

# --- Summary ---
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
