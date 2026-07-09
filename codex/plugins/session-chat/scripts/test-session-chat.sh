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

assert_empty() {
  local value="$1"
  local label="$2"
  [ -z "$value" ] || fail "$label was not empty: $value"
}

require_tmux_env() {
  local pane="$1"
  tmux display-message -p -t "$pane" '#{socket_path},#{pid},0'
}

run_as_sender() {
  TMUX="$TMUX_ENV" TMUX_PANE="$SENDER" CODEX_HOME="$TEST_HOME" SESSION_CHAT_ALLOW_SHELL_TARGET=1 "$@"
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

HOOK_OUT="$(printf '%s\n' '[from:sender-test pane:%999 id:feedface] hook hello' | TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" CODEX_HOME="$TEST_HOME" CODEX_PLUGIN_ROOT="$PLUGIN_ROOT" SESSION_CHAT_INCOMING_MODE=auto bash "$SCRIPT_DIR/detect-incoming-message.sh")"
assert_contains '"hookSpecificOutput"' "$HOOK_OUT"
assert_contains '"hookEventName":"UserPromptSubmit"' "$HOOK_OUT"
assert_contains '"additionalContext":"session-chat:' "$HOOK_OUT"
if printf '%s\n' "$HOOK_OUT" | grep -E '"decision"|"systemMessage"' >/dev/null; then
  fail "hook output used legacy Claude envelope"
fi

QUEUE_OUT="$(CODEX_HOME="$TEST_HOME" bash -c 'source "$0"; enqueue_message recipient-test deadbeef send sender-test "queued fallback"; drain_inbox "" recipient-test' "$SCRIPT_DIR/lib.sh")"
assert_empty "$QUEUE_OUT" "fresh queued message"
QUEUE_OUT="$(CODEX_HOME="$TEST_HOME" bash -c 'source "$0"; mark_message_ready recipient-test deadbeef; drain_inbox "" recipient-test' "$SCRIPT_DIR/lib.sh")"
assert_contains $'deadbeef\tsend\tsender-test\tqueued fallback' "$QUEUE_OUT"
QUEUE_LOCK="$(CODEX_HOME="$TEST_HOME" bash -c 'source "$0"; queue_lock_path recipient-test' "$SCRIPT_DIR/lib.sh")"
[ "$QUEUE_LOCK" = "$TEST_HOME/messages/queue/.locks/recipient-test.lock" ] || fail "queue lock path was not messages-dir keyed: $QUEUE_LOCK"
DUP_OUT="$(printf '%s\n' '[from:sender-test pane:%999 id:deadbeef] queued fallback' | TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" CODEX_HOME="$TEST_HOME" CODEX_PLUGIN_ROOT="$PLUGIN_ROOT" SESSION_CHAT_INCOMING_MODE=auto bash "$SCRIPT_DIR/detect-incoming-message.sh")"
assert_empty "$DUP_OUT" "recent duplicate live hook output"

# Stop-event drain: a ready queued row must surface as a decision:block
# envelope (live-verified Codex Stop schema), then the queue must be empty.
CODEX_HOME="$TEST_HOME" bash -c 'source "$0"; enqueue_message recipient-test cafe0001 send sender-test "stop drain payload"; mark_message_ready recipient-test cafe0001' "$SCRIPT_DIR/lib.sh"
STOP_OUT="$(printf '%s' '{"hook_event_name":"Stop","stop_hook_active":false}' | TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" CODEX_HOME="$TEST_HOME" CODEX_PLUGIN_ROOT="$PLUGIN_ROOT" SESSION_CHAT_INCOMING_MODE=auto bash "$SCRIPT_DIR/detect-incoming-message.sh")"
assert_contains '"decision":"block"' "$STOP_OUT"
assert_contains 'stop drain payload' "$STOP_OUT"
if printf '%s\n' "$STOP_OUT" | grep -F '"hookSpecificOutput"' >/dev/null; then
  fail "Stop drain used the UserPromptSubmit envelope"
fi
STOP_EMPTY="$(printf '%s' '{"hook_event_name":"Stop","stop_hook_active":false}' | TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" CODEX_HOME="$TEST_HOME" CODEX_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SCRIPT_DIR/detect-incoming-message.sh")"
assert_empty "$STOP_EMPTY" "Stop with empty inbox"
CODEX_HOME="$TEST_HOME" bash -c 'source "$0"; enqueue_message recipient-test cafe0002 send sender-test "guarded payload"; mark_message_ready recipient-test cafe0002' "$SCRIPT_DIR/lib.sh"
STOP_GUARD="$(printf '%s' '{"hook_event_name":"Stop","stop_hook_active":true}' | TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" CODEX_HOME="$TEST_HOME" CODEX_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SCRIPT_DIR/detect-incoming-message.sh")"
assert_empty "$STOP_GUARD" "stop_hook_active re-entry guard"
# Guarded row must remain queued for the next UserPromptSubmit, not be lost.
GUARD_ROWS="$(grep -c cafe0002 "$TEST_HOME/messages/queue/recipient-test.tsv" 2>/dev/null || true)"
[ "$GUARD_ROWS" = "1" ] || fail "guarded Stop consumed the queued row (rows=$GUARD_ROWS)"
CODEX_HOME="$TEST_HOME" bash -c 'source "$0"; dequeue_message_id recipient-test cafe0002' "$SCRIPT_DIR/lib.sh"

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

CROSS_DIR="$TEST_HOME/recipient-runtime/messages"
CROSS_PANE="$(tmux new-window -t "$SESSION" -n cross-runtime -P -F '#{pane_id}' "sh -c 'stty -echo; sleep 2; stty echo; cat'")"
tmux set-option -p -t "$CROSS_PANE" @name cross-runtime-recipient
run_as_sender env SESSION_CHAT_TARGET_MESSAGES_DIR="$CROSS_DIR" SESSION_CHAT_SETTLE_MS=50 SESSION_CHAT_VERIFY_TIMEOUT_MS=50 SESSION_CHAT_SEND_RETRIES=0 \
  bash "$SCRIPT_DIR/send-message.sh" cross-runtime-recipient "cross runtime fallback" > "$TEST_HOME/cross-runtime.txt"
assert_file_contains "$TEST_HOME/cross-runtime.txt" "Queued to cross-runtime-recipient"
assert_file_contains "$CROSS_DIR/queue/cross-runtime-recipient.tsv" "cross runtime fallback"
CROSS_LOCK="$(CODEX_HOME="$TEST_HOME" bash -c 'source "$0"; queue_lock_path cross-runtime-recipient "$1"' "$SCRIPT_DIR/lib.sh" "$CROSS_DIR")"
[ "$CROSS_LOCK" = "$CROSS_DIR/queue/.locks/cross-runtime-recipient.lock" ] || fail "cross-runtime queue lock path was not target-dir keyed: $CROSS_LOCK"
if [ -e "$TEST_HOME/messages/queue/cross-runtime-recipient.tsv" ]; then
  fail "cross-runtime fallback wrote to sender CODEX_HOME queue"
fi

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

# A recipient pane whose foreground command is bare `node` is a Claude runtime;
# its durable fallback MUST route to the Claude messages dir, not Codex's own —
# otherwise a failed live paste queues where the Claude pane never drains (lost).
NODE_ROUTE="$(CODEX_HOME="$TEST_HOME" CLAUDE_HOME="$TEST_HOME/claude-rt" bash -c '
  source "$0"
  tmux() { if [ "$1" = display-message ]; then echo node; return 0; fi; command tmux "$@"; }
  export -f tmux
  target_messages_dir_for_pane %999
' "$SCRIPT_DIR/lib.sh")"
[ "$NODE_ROUTE" = "$TEST_HOME/claude-rt/messages" ] || fail "node-reporting pane must route to Claude dir, got: $NODE_ROUTE"

# Enter (submit) failure must queue, not drop: a failed `send-keys Enter` must
# NOT be reported as live delivery (which would dequeue the durable copy and
# silently lose the message). Expect send_message rc 3 with the row retained.
ENTER_FAIL_OUT="$(TMUX="$TMUX_ENV" TMUX_PANE="$SENDER" CODEX_HOME="$TEST_HOME" \
  SESSION_CHAT_ALLOW_SHELL_TARGET=1 SESSION_CHAT_VERIFY_TIMEOUT_MS=1000 \
  SESSION_CHAT_SETTLE_MS=50 SESSION_CHAT_SEND_RETRIES=1 \
  bash -c '
    set -u
    source "$0"
    tmux() {
      if [ "$1" = send-keys ]; then
        local last="${@: -1}"
        [ "$last" = Enter ] && return 1
      fi
      command tmux "$@"
    }
    export -f tmux
    send_message recipient-test "enter-fail-probe"
    echo "RC=$?"
  ' "$SCRIPT_DIR/lib.sh")"
assert_contains "RC=3" "$ENTER_FAIL_OUT"
assert_file_contains "$TEST_HOME/messages/queue/recipient-test.tsv" "enter-fail-probe"

echo "session-chat smoke tests passed"
