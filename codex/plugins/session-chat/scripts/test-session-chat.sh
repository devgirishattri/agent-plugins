#!/usr/bin/env bash
# test-session-chat.sh — Smoke tests for session-chat scripts
# Supported platforms: macOS, Linux
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SESSION="session-chat-test-$$"
OTHER_SESSION="${SESSION}-other"
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/session-chat-test.XXXXXX")"
PROMPT_FILE="$TEST_HOME/prompt.md"
ERR_FILE="$TEST_HOME/error.log"

cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  tmux kill-session -t "$OTHER_SESSION" 2>/dev/null || true
  rm -rf "$TEST_HOME"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  printf '%s\n' "$haystack" | grep -F "$needle" >/dev/null || fail "missing expected text: $needle"
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  grep -F "$needle" "$file" >/dev/null || fail "missing expected text in $file: $needle"
}

require_tmux_env() {
  local pane="$1"
  tmux display-message -p -t "$pane" '#{socket_path},#{pid},0'
}

run_as_sender() {
  TMUX="$TMUX_ENV" TMUX_PANE="$SENDER" CODEX_HOME="$TEST_HOME" "$@"
}

capture_recipient() {
  tmux capture-pane -J -t "$RECIPIENT" -p -S -200
}

tmux new-session -d -x 220 -y 40 -s "$SESSION" "cat"
tmux split-window -t "$SESSION" "cat" >/dev/null
tmux new-session -d -x 120 -y 20 -s "$OTHER_SESSION" "cat"
SENDER="$(tmux list-panes -t "$SESSION" -F '#{pane_id}' | sed -n '1p')"
RECIPIENT="$(tmux list-panes -t "$SESSION" -F '#{pane_id}' | sed -n '2p')"
OTHER_PANE="$(tmux list-panes -t "$OTHER_SESSION" -F '#{pane_id}' | sed -n '1p')"
tmux set-option -p -t "$SENDER" @name sender-test
tmux set-option -p -t "$RECIPIENT" @name recipient-test
tmux set-option -p -t "$OTHER_PANE" @name other-session-test
TMUX_ENV="$(require_tmux_env "$SENDER")"

run_as_sender bash "$SCRIPT_DIR/list-panes.sh" > "$TEST_HOME/panes-current.txt"
assert_file_contains "$TEST_HOME/panes-current.txt" "sender-test"
assert_file_contains "$TEST_HOME/panes-current.txt" "recipient-test"
if grep -F "other-session-test" "$TEST_HOME/panes-current.txt" >/dev/null; then
  fail "current-session pane list included another tmux session"
fi
run_as_sender bash "$SCRIPT_DIR/list-panes.sh" all > "$TEST_HOME/panes-all.txt"
assert_file_contains "$TEST_HOME/panes-all.txt" "other-session-test"

run_as_sender env SESSION_CHAT_SETTLE_MS=50 SESSION_CHAT_VERIFY_TIMEOUT_MS=5000 \
  bash "$SCRIPT_DIR/send-message.sh" recipient-test "send happy path"
assert_contains "send happy path" "$(capture_recipient)"

if run_as_sender bash "$SCRIPT_DIR/send-message.sh" missing-target "hello" 2>"$ERR_FILE"; then
  fail "send to unknown pane unexpectedly succeeded"
fi
assert_file_contains "$ERR_FILE" "No pane named 'missing-target'"
! grep -F "Failed to send message" "$ERR_FILE" >/dev/null || fail "generic send wrapper error leaked"

if run_as_sender bash "$SCRIPT_DIR/send-message.sh" recipient-test $'line one\nline two' 2>"$ERR_FILE"; then
  fail "newline guard unexpectedly succeeded"
fi
assert_file_contains "$ERR_FILE" "/send only supports single-line messages"

if run_as_sender env SESSION_CHAT_SEND_MAX_LEN=4 bash "$SCRIPT_DIR/send-message.sh" recipient-test "12345" 2>"$ERR_FILE"; then
  fail "length guard unexpectedly succeeded"
fi
assert_file_contains "$ERR_FILE" "/send payload exceeds 4 characters"

printf '%s\n' "dispatch one" "dispatch two with special chars: \$foo, \`bar\`, \"baz\", 'qux'" > "$PROMPT_FILE"
run_as_sender env SESSION_CHAT_SETTLE_MS=50 SESSION_CHAT_VERIFY_TIMEOUT_MS=5000 \
  bash "$SCRIPT_DIR/dispatch-to-session.sh" recipient-test "$PROMPT_FILE"
CAPTURED="$(capture_recipient)"
assert_contains "dispatch (2 lines)" "$CAPTURED"
assert_contains "read msg file for full task" "$CAPTURED"
MSG_FILE="$(printf '%s\n' "$CAPTURED" | grep -o 'msg:[^ ]*' | tail -1 | sed 's/^msg://')"
[ -f "$MSG_FILE" ] || fail "dispatch message file not found"
assert_file_contains "$MSG_FILE" "dispatch one"
assert_file_contains "$MSG_FILE" "dispatch two with special chars"

THIRD="$(tmux split-window -t "$SESSION" -P -F '#{pane_id}' "cat")"
tmux set-option -p -t "$THIRD" @name recipient-test
if run_as_sender bash "$SCRIPT_DIR/send-message.sh" recipient-test "duplicate target" 2>"$ERR_FILE"; then
  fail "duplicate-name detection unexpectedly succeeded"
fi
assert_file_contains "$ERR_FILE" "Multiple panes named 'recipient-test'"
tmux set-option -p -t "$THIRD" @name third-test

run_as_sender env SESSION_CHAT_SETTLE_MS=50 SESSION_CHAT_VERIFY_TIMEOUT_MS=5000 \
  bash "$SCRIPT_DIR/send-message.sh" recipient-test "parallel one" &
pid_one=$!
run_as_sender env SESSION_CHAT_SETTLE_MS=50 SESSION_CHAT_VERIFY_TIMEOUT_MS=5000 \
  bash "$SCRIPT_DIR/send-message.sh" recipient-test "parallel two" &
pid_two=$!
wait "$pid_one"
wait "$pid_two"
CAPTURED="$(capture_recipient)"
assert_contains "parallel one" "$CAPTURED"
assert_contains "parallel two" "$CAPTURED"

tmux new-window -t "$SESSION" -n retry "sleep 0.4; cat" >/dev/null
RETRY_PANE="$(tmux list-panes -t "$SESSION:retry" -F '#{pane_id}' | sed -n '1p')"
tmux set-option -p -t "$RETRY_PANE" @name retry-recipient
run_as_sender env SESSION_CHAT_SETTLE_MS=50 SESSION_CHAT_VERIFY_TIMEOUT_MS=100 SESSION_CHAT_SEND_RETRIES=4 SESSION_CHAT_RETRY_BACKOFF_MS=200 \
  bash "$SCRIPT_DIR/send-message.sh" retry-recipient "retry happy path"
tmux capture-pane -J -t "$RETRY_PANE" -p -S -200 | grep -F "retry happy path" >/dev/null || fail "retry send did not land"

bash "$SCRIPT_DIR/incoming-mode.sh" > "$TEST_HOME/incoming.txt"
assert_file_contains "$TEST_HOME/incoming.txt" "SESSION_CHAT_INCOMING_MODE=notify"
bash "$SCRIPT_DIR/incoming-mode.sh" auto > "$TEST_HOME/incoming-auto.txt"
assert_file_contains "$TEST_HOME/incoming-auto.txt" "export SESSION_CHAT_INCOMING_MODE=auto"

CODEX_HOME="$TEST_HOME" bash "$SCRIPT_DIR/list-messages.sh" > "$TEST_HOME/list.txt"
assert_file_contains "$TEST_HOME/list.txt" "Summary"
CODEX_HOME="$TEST_HOME" bash "$SCRIPT_DIR/clean-messages.sh" --older-than 0s > "$TEST_HOME/clean-dry-run.txt"
assert_file_contains "$TEST_HOME/clean-dry-run.txt" "Dry run only"
CODEX_HOME="$TEST_HOME" bash "$SCRIPT_DIR/clean-messages.sh" --older-than 0s --apply > "$TEST_HOME/clean-apply.txt"
assert_file_contains "$TEST_HOME/clean-apply.txt" "Summary"
if find "$TEST_HOME/messages" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep . >/dev/null; then
  fail "leftover test message files"
fi

echo "session-chat smoke tests passed"
