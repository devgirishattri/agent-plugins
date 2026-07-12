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
unset SESSION_CHAT_INCOMING_MODE SESSION_CHAT_DISPATCH_INLINE_MAX

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

path_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
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

assert_file_not_contains() {
  local file="$1"
  local needle="$2"
  if grep -F "$needle" "$file" >/dev/null; then
    fail "unexpected text in $file: $needle"
  fi
}

# The runtime dispatch instructions must never embed arbitrary task text in a
# fixed shell heredoc. A body line equal to EOF/PROMPT_EOF would terminate it.
for dispatch_doc in \
  "$PLUGIN_ROOT/skills/dispatch/SKILL.md" "$PLUGIN_ROOT/commands/dispatch.md" \
  "$PLUGIN_ROOT/skills/reply/SKILL.md" "$PLUGIN_ROOT/commands/reply.md"; do
  assert_file_contains "$dispatch_doc" 'apply_patch'
  if grep -E '<<-?[[:space:]]*['"'"']?(EOF|PROMPT_EOF)' "$dispatch_doc" >/dev/null; then
    fail "dispatch instructions contain a fixed shell heredoc: $dispatch_doc"
  fi
done

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

DENIED_BIN="$TEST_HOME/denied-bin"
DENIED_TMP="$TEST_HOME/denied-tmp"
EMPTY_BIN="$TEST_HOME/empty-bin"
mkdir -p "$DENIED_BIN" "$DENIED_TMP" "$EMPTY_BIN"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'echo "${SESSION_CHAT_FAKE_TMUX_ERROR:-error connecting to /tmp/tmux-test/default (Operation not permitted)}" >&2' \
  'exit 1' > "$DENIED_BIN/tmux"
chmod +x "$DENIED_BIN/tmux"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'exit 0' > "$EMPTY_BIN/tmux"
chmod +x "$EMPTY_BIN/tmux"

run_with_denied_tmux() {
  PATH="$DENIED_BIN:$PATH" TMPDIR="$DENIED_TMP" TMUX="$TMUX_ENV" \
    TMUX_PANE="$SENDER" CODEX_HOME="$TEST_HOME" "$@"
}

run_with_empty_tmux() {
  PATH="$EMPTY_BIN:$PATH" TMPDIR="$DENIED_TMP" TMUX="$TMUX_ENV" \
    TMUX_PANE="$SENDER" CODEX_HOME="$TEST_HOME" "$@"
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

HOOK_OUT="$(printf '%s\n' '[from:sender-test pane:%999 id:feedface] hook hello' | TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" CODEX_HOME="$TEST_HOME" PLUGIN_ROOT="$PLUGIN_ROOT" SESSION_CHAT_INCOMING_MODE=auto bash "$SCRIPT_DIR/detect-incoming-message.sh")"
assert_contains '"hookSpecificOutput"' "$HOOK_OUT"
assert_contains '"hookEventName":"UserPromptSubmit"' "$HOOK_OUT"
assert_contains '"additionalContext":"session-chat:' "$HOOK_OUT"
assert_contains '$session-chat:reply sender-test feedface <message>' "$HOOK_OUT"
if printf '%s\n' "$HOOK_OUT" | grep -E '"decision"|"systemMessage"' >/dev/null; then
  fail "hook output used legacy Claude envelope"
fi

QUEUE_OUT="$(CODEX_HOME="$TEST_HOME" bash -c 'source "$0"; enqueue_message recipient-test deadbeef send sender-test "queued fallback"; drain_inbox "" recipient-test' "$SCRIPT_DIR/lib.sh")"
assert_empty "$QUEUE_OUT" "fresh queued message"
QUEUE_OUT="$(CODEX_HOME="$TEST_HOME" bash -c 'source "$0"; mark_message_ready recipient-test deadbeef; drain_inbox "" recipient-test' "$SCRIPT_DIR/lib.sh")"
assert_contains $'deadbeef\tsend\tsender-test\tqueued fallback' "$QUEUE_OUT"
QUEUE_LOCK="$(CODEX_HOME="$TEST_HOME" bash -c 'source "$0"; queue_lock_path recipient-test' "$SCRIPT_DIR/lib.sh")"
[ "$QUEUE_LOCK" = "$TEST_HOME/messages/queue/.locks/recipient-test.lock" ] || fail "queue lock path was not messages-dir keyed: $QUEUE_LOCK"

CORRELATED_REPLY="$(CODEX_HOME="$TEST_HOME" bash -c 'source "$0"; correlate_reply deadbeef "[re:deadbeef] [re:deadbeef] reply once"' "$SCRIPT_DIR/lib.sh")"
[ "$CORRELATED_REPLY" = "[re:deadbeef] reply once" ] || fail "correlate_reply did not normalize the token exactly once: $CORRELATED_REPLY"
if CODEX_HOME="$TEST_HOME" bash -c 'source "$0"; correlate_reply deadbeef "[re:cafebabe] conflicting"' "$SCRIPT_DIR/lib.sh" 2>"$ERR_FILE"; then
  fail "correlate_reply accepted a conflicting token"
fi
assert_file_contains "$ERR_FILE" "conflicting correlation token [re:cafebabe]"

QUEUED_REPLY_FILE="$TEST_HOME/messages/queued-reply.md"
printf '%s\n' "[re:0badf00d] queued dispatch reply" > "$QUEUED_REPLY_FILE"
chmod 600 "$QUEUED_REPLY_FILE"
CODEX_HOME="$TEST_HOME" bash -c \
  'source "$0"; enqueue_message recipient-test feedbabe dispatch sender-test "$1"; mark_message_ready recipient-test feedbabe' \
  "$SCRIPT_DIR/lib.sh" "$QUEUED_REPLY_FILE"
QUEUED_REPLY_OUT="$(printf '%s' '{}' | \
  TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" CODEX_HOME="$TEST_HOME" \
  PLUGIN_ROOT="$PLUGIN_ROOT" SESSION_CHAT_INCOMING_MODE=auto \
  bash "$SCRIPT_DIR/detect-incoming-message.sh")"
assert_contains '$session-chat:reply sender-test feedbabe <message>' "$QUEUED_REPLY_OUT"
assert_file_contains "$TEST_HOME/messages/replies-log.tsv" $'0badf00d\tsender-test'

# Live-send locks share a UID-scoped private temp root. Both the root and lock
# directory must be canonical owner-only directories, and pre-planted unsafe
# roots must be rejected before any lock path is returned.
LOCK_TMP="$TEST_HOME/lock-tmp"
mkdir -p "$LOCK_TMP"
LOCK_TMP_CANONICAL=$(cd "$LOCK_TMP" && pwd -P)
LOCK_UID=$(id -u)
LIVE_LOCK=$(TMPDIR="$LOCK_TMP" bash -c 'source "$0"; send_lock_path "%42"' "$SCRIPT_DIR/lib.sh")
EXPECTED_LIVE_LOCK="$LOCK_TMP_CANONICAL/session-chat-$LOCK_UID/send-locks/_42.lock"
[ "$LIVE_LOCK" = "$EXPECTED_LIVE_LOCK" ] || fail "send lock did not use the UID-scoped private root: $LIVE_LOCK"
[ "$(path_mode "$LOCK_TMP_CANONICAL/session-chat-$LOCK_UID")" = "700" ] || fail "send-lock private root is not mode 700"
[ "$(path_mode "$LOCK_TMP_CANONICAL/session-chat-$LOCK_UID/send-locks")" = "700" ] || fail "send-lock directory is not mode 700"
LIVE_LOCK_MODES=$(TMPDIR="$LOCK_TMP" bash -c '
  source "$0"
  lock=$(send_lock_path "%43") || exit 1
  acquire_send_lock "$lock" "%43" || exit 1
  lock_mode=$(stat -c "%a" "$lock" 2>/dev/null || stat -f "%Lp" "$lock" 2>/dev/null) || exit 1
  pid_mode=$(stat -c "%a" "$lock/pid" 2>/dev/null || stat -f "%Lp" "$lock/pid" 2>/dev/null) || exit 1
  printf "%s %s\n" "$lock_mode" "$pid_mode"
  release_send_lock "$lock"
' "$SCRIPT_DIR/lib.sh")
[ "$LIVE_LOCK_MODES" = "700 600" ] || fail "live send lock/pid modes are not 700/600: $LIVE_LOCK_MODES"

LOCK_SYMLINK_TMP="$TEST_HOME/lock-symlink-tmp"
mkdir -p "$LOCK_SYMLINK_TMP/target"
ln -s "$LOCK_SYMLINK_TMP/target" "$LOCK_SYMLINK_TMP/session-chat-$LOCK_UID"
if TMPDIR="$LOCK_SYMLINK_TMP" bash -c 'source "$0"; send_lock_path "%42"' "$SCRIPT_DIR/lib.sh" 2> "$TEST_HOME/lock-symlink.err"; then
  fail "send lock accepted a pre-planted symlink root"
fi
grep 'Refusing unsafe session-chat temp root' "$TEST_HOME/lock-symlink.err" >/dev/null \
  || fail "send-lock symlink rejection did not explain the unsafe root"

LOCK_LOOSE_TMP="$TEST_HOME/lock-loose-tmp"
mkdir -p "$LOCK_LOOSE_TMP/session-chat-$LOCK_UID"
chmod 755 "$LOCK_LOOSE_TMP/session-chat-$LOCK_UID"
if TMPDIR="$LOCK_LOOSE_TMP" bash -c 'source "$0"; send_lock_path "%42"' "$SCRIPT_DIR/lib.sh" 2> "$TEST_HOME/lock-loose.err"; then
  fail "send lock accepted a non-private root"
fi
grep 'Refusing non-private session-chat temp root' "$TEST_HOME/lock-loose.err" >/dev/null \
  || fail "send-lock mode rejection did not explain the unsafe root"

LOCK_RACE_TMP="$TEST_HOME/lock-race-tmp"
mkdir -p "$LOCK_RACE_TMP"
lock_race_pids=""
for race_i in 1 2 3 4 5 6 7 8; do
  TMPDIR="$LOCK_RACE_TMP" bash -c 'source "$0"; send_lock_path "$1"' \
    "$SCRIPT_DIR/lib.sh" "%race-$race_i" > "$TEST_HOME/lock-race-$race_i.out" &
  lock_race_pids="$lock_race_pids $!"
done
for race_pid in $lock_race_pids; do
  wait "$race_pid" || fail "concurrent send-lock root initialization failed"
done
[ "$(path_mode "$(cd "$LOCK_RACE_TMP" && pwd -P)/session-chat-$LOCK_UID")" = "700" ] \
  || fail "concurrently initialized send-lock root is not mode 700"
DUP_OUT="$(printf '%s\n' '[from:sender-test pane:%999 id:deadbeef] queued fallback' | TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" CODEX_HOME="$TEST_HOME" PLUGIN_ROOT="$PLUGIN_ROOT" SESSION_CHAT_INCOMING_MODE=auto bash "$SCRIPT_DIR/detect-incoming-message.sh")"
assert_empty "$DUP_OUT" "recent duplicate live hook output"

# Stop-event drain: a ready queued row must surface as a decision:block
# envelope (live-verified Codex Stop schema), then the queue must be empty.
CODEX_HOME="$TEST_HOME" bash -c 'source "$0"; enqueue_message recipient-test cafe0001 send sender-test "stop drain payload"; mark_message_ready recipient-test cafe0001' "$SCRIPT_DIR/lib.sh"
STOP_OUT="$(printf '%s' '{"hook_event_name":"Stop","stop_hook_active":false}' | TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" CODEX_HOME="$TEST_HOME" PLUGIN_ROOT="$PLUGIN_ROOT" SESSION_CHAT_INCOMING_MODE=auto bash "$SCRIPT_DIR/detect-incoming-message.sh")"
assert_contains '"decision":"block"' "$STOP_OUT"
assert_contains 'stop drain payload' "$STOP_OUT"
if printf '%s\n' "$STOP_OUT" | grep -F '"hookSpecificOutput"' >/dev/null; then
  fail "Stop drain used the UserPromptSubmit envelope"
fi
STOP_EMPTY="$(printf '%s' '{"hook_event_name":"Stop","stop_hook_active":false}' | TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" CODEX_HOME="$TEST_HOME" PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SCRIPT_DIR/detect-incoming-message.sh")"
assert_empty "$STOP_EMPTY" "Stop with empty inbox"
CODEX_HOME="$TEST_HOME" bash -c 'source "$0"; enqueue_message recipient-test cafe0002 send sender-test "guarded payload"; mark_message_ready recipient-test cafe0002' "$SCRIPT_DIR/lib.sh"
STOP_GUARD="$(printf '%s' '{"hook_event_name":"Stop","stop_hook_active":true}' | TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" CODEX_HOME="$TEST_HOME" PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SCRIPT_DIR/detect-incoming-message.sh")"
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
run_as_sender bash "$SCRIPT_DIR/pane-health.sh" recipient-test > "$TEST_HOME/pane-health.txt"
assert_file_contains "$TEST_HOME/pane-health.txt" $'COMMAND\tLOCATION\tBACKLOG'

# A Codex sandbox can leave TMUX/TMUX_PANE set while denying the socket. Every
# user-facing direct tmux workflow must report that denial, return non-zero, and
# never reinterpret it as an empty pane list or an unnamed pane.
printf '%s\n' "denial dispatch probe" > "$PROMPT_FILE"
for denied_case in list-panes list-panes-all pane-health pane-health-all get-my-name broadcast send dispatch; do
  DENIED_OUT="$TEST_HOME/${denied_case}.out"
  DENIED_ERR="$TEST_HOME/${denied_case}.err"
  case "$denied_case" in
    list-panes) denied_cmd=(bash "$SCRIPT_DIR/list-panes.sh") ;;
    list-panes-all) denied_cmd=(bash "$SCRIPT_DIR/list-panes.sh" all) ;;
    pane-health) denied_cmd=(bash "$SCRIPT_DIR/pane-health.sh") ;;
    pane-health-all) denied_cmd=(bash "$SCRIPT_DIR/pane-health.sh" --all) ;;
    get-my-name) denied_cmd=(bash "$SCRIPT_DIR/get-my-name.sh") ;;
    broadcast) denied_cmd=(bash "$SCRIPT_DIR/broadcast-message.sh" "denial probe") ;;
    send) denied_cmd=(bash "$SCRIPT_DIR/send-message.sh" recipient-test "denial probe") ;;
    dispatch) denied_cmd=(bash "$SCRIPT_DIR/dispatch-to-session.sh" recipient-test "$PROMPT_FILE") ;;
  esac
  if run_with_denied_tmux "${denied_cmd[@]}" >"$DENIED_OUT" 2>"$DENIED_ERR"; then
    fail "$denied_case succeeded when tmux socket access was denied"
  fi
  assert_file_contains "$DENIED_ERR" "Operation not permitted"
  assert_file_contains "$DENIED_ERR" "escalated/approved"
  assert_file_not_contains "$DENIED_OUT" "No named panes"
  assert_file_not_contains "$DENIED_ERR" "This pane has no name"
  assert_file_not_contains "$DENIED_ERR" "No named panes matched"
done

# The other common socket-denial signature receives the same classification.
PERMISSION_ERR="$TEST_HOME/permission-denied.err"
if SESSION_CHAT_FAKE_TMUX_ERROR="error connecting to /tmp/tmux-test/default (Permission denied)" \
  run_with_denied_tmux bash "$SCRIPT_DIR/list-panes.sh" all \
  >"$TEST_HOME/permission-denied.out" 2>"$PERMISSION_ERR"; then
  fail "Permission denied tmux probe unexpectedly succeeded"
fi
assert_file_contains "$PERMISSION_ERR" "Permission denied"
assert_file_contains "$PERMISSION_ERR" "escalated/approved"

# Preserve the opposite side of the contract: successful empty tmux output is
# still an honest empty result, not a permission error.
EMPTY_OUT="$TEST_HOME/empty-list.out"
EMPTY_ERR="$TEST_HOME/empty-list.err"
run_with_empty_tmux bash "$SCRIPT_DIR/list-panes.sh" all >"$EMPTY_OUT" 2>"$EMPTY_ERR"
[ ! -s "$EMPTY_OUT" ] || fail "empty pane listing emitted unexpected rows"
[ ! -s "$EMPTY_ERR" ] || fail "empty pane listing emitted an unexpected error"

run_with_empty_tmux bash "$SCRIPT_DIR/get-my-name.sh" \
  >"$TEST_HOME/empty-name.out" 2>"$TEST_HOME/empty-name.err"
[ ! -s "$TEST_HOME/empty-name.out" ] || fail "unnamed pane emitted an unexpected name"
[ ! -s "$TEST_HOME/empty-name.err" ] || fail "unnamed pane emitted an unexpected error"

run_with_empty_tmux bash "$SCRIPT_DIR/pane-health.sh" --all \
  >"$TEST_HOME/empty-health.out" 2>"$TEST_HOME/empty-health.err"
assert_file_contains "$TEST_HOME/empty-health.out" "No named panes found"
[ ! -s "$TEST_HOME/empty-health.err" ] || fail "empty health check emitted an unexpected error"

run_as_sender env SESSION_CHAT_SETTLE_MS=50 SESSION_CHAT_VERIFY_TIMEOUT_MS=5000 \
  bash "$SCRIPT_DIR/send-message.sh" recipient-test "send happy path"
assert_contains "send happy path" "$(capture_recipient)"

run_as_sender env SESSION_CHAT_SETTLE_MS=50 SESSION_CHAT_VERIFY_TIMEOUT_MS=5000 \
  bash "$SCRIPT_DIR/send-message.sh" --reply-to deadbeef recipient-test "reply happy path"
assert_contains "[re:deadbeef] reply happy path" "$(capture_recipient)"

run_as_sender env SESSION_CHAT_SETTLE_MS=50 SESSION_CHAT_VERIFY_TIMEOUT_MS=5000 \
  bash "$SCRIPT_DIR/send-message.sh" --reply-to deadbeef recipient-test "[re:deadbeef] already correlated"
if capture_recipient | grep -F "[re:deadbeef] [re:deadbeef]" >/dev/null; then
  fail "send --reply-to duplicated an existing correlation token"
fi

if run_as_sender bash "$SCRIPT_DIR/send-message.sh" --reply-to NOT_HEX recipient-test "invalid reply" 2>"$ERR_FILE"; then
  fail "send --reply-to accepted an invalid message id"
fi
assert_file_contains "$ERR_FILE" "Reply id must be 8-16 lowercase hexadecimal characters"
if env -u TMUX -u TMUX_PANE CODEX_HOME="$TEST_HOME" \
  bash "$SCRIPT_DIR/dispatch-to-session.sh" --reply-to NOT_HEX recipient-test "$PROMPT_FILE" \
  2>"$ERR_FILE"; then
  fail "dispatch --reply-to accepted an invalid message id"
fi
assert_file_contains "$ERR_FILE" "Reply id must be 8-16 lowercase hexadecimal characters"
assert_file_not_contains "$ERR_FILE" "needs to run inside tmux"

if run_as_sender bash "$SCRIPT_DIR/send-message.sh" missing-target "hello" 2>"$ERR_FILE"; then
  fail "send to unknown pane unexpectedly succeeded"
fi
assert_file_contains "$ERR_FILE" "No pane named 'missing-target'"
! grep -F "Failed to send message" "$ERR_FILE" >/dev/null || fail "generic send wrapper error leaked"

if run_as_sender bash "$SCRIPT_DIR/send-message.sh" recipient-test $'line one\nline two' 2>"$ERR_FILE"; then
  fail "newline guard unexpectedly succeeded"
fi
assert_file_contains "$ERR_FILE" '$session-chat:send only supports single-line messages'

if run_as_sender env SESSION_CHAT_SEND_MAX_LEN=4 bash "$SCRIPT_DIR/send-message.sh" recipient-test "12345" 2>"$ERR_FILE"; then
  fail "length guard unexpectedly succeeded"
fi
assert_file_contains "$ERR_FILE" '$session-chat:send payload exceeds 4 characters'

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
file_mode=$(stat -c '%a' "$MSG_FILE" 2>/dev/null || stat -f '%Lp' "$MSG_FILE" 2>/dev/null)
[ "$file_mode" = "600" ] || fail "dispatch message file is not owner-only: $file_mode"

printf '%s\n' "dispatch reply" "second line" > "$PROMPT_FILE"
run_as_sender env SESSION_CHAT_SETTLE_MS=50 SESSION_CHAT_VERIFY_TIMEOUT_MS=5000 \
  bash "$SCRIPT_DIR/dispatch-to-session.sh" --reply-to cafebabe recipient-test "$PROMPT_FILE"
REPLY_CAPTURED="$(capture_recipient)"
REPLY_MSG_FILE="$(printf '%s\n' "$REPLY_CAPTURED" | grep -o 'msg:[^ ]*' | tail -1 | sed 's/^msg://')"
[ -f "$REPLY_MSG_FILE" ] || fail "reply dispatch message file not found"
assert_file_contains "$REPLY_MSG_FILE" "[re:cafebabe] dispatch reply"
REPLY_NOTICE="$(printf '%s\n' "$REPLY_CAPTURED" | grep -F "msg:$REPLY_MSG_FILE" | tail -1)"
printf '%s\n' "$REPLY_NOTICE" | \
  TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" CODEX_HOME="$TEST_HOME" \
  PLUGIN_ROOT="$PLUGIN_ROOT" SESSION_CHAT_INCOMING_MODE=auto \
  bash "$SCRIPT_DIR/detect-incoming-message.sh" >/dev/null
assert_file_contains "$TEST_HOME/messages/replies-log.tsv" $'cafebabe\tsender-test'

CHECK_REPLIES_OUT="$(CODEX_HOME="$TEST_HOME" bash "$SCRIPT_DIR/check-replies.sh" --since 60)"
assert_contains "unconfirmed" "$CHECK_REPLIES_OUT"
assert_contains "not task-liveness status" "$CHECK_REPLIES_OUT"

# Manually/external tmux names bypass set_pane_name, so outbound paths must
# revalidate both sender and target labels before creating any dispatch file.
dispatch_files_before=$(find "$TEST_HOME/messages" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')
tmux set-option -p -t "$SENDER" @name '../unsafe-sender'
if run_as_sender bash "$SCRIPT_DIR/dispatch-to-session.sh" recipient-test "$PROMPT_FILE" 2> "$ERR_FILE"; then
  fail "dispatch accepted an unsafe externally assigned sender name"
fi
assert_file_contains "$ERR_FILE" 'unsafe externally assigned name'
tmux set-option -p -t "$SENDER" @name sender-test

tmux set-option -p -t "$RECIPIENT" @name '../unsafe-target'
if run_as_sender bash "$SCRIPT_DIR/dispatch-to-session.sh" '../unsafe-target' "$PROMPT_FILE" 2> "$ERR_FILE"; then
  fail "dispatch accepted an unsafe externally assigned target name"
fi
assert_file_contains "$ERR_FILE" 'Label must contain only'
tmux set-option -p -t "$RECIPIENT" @name recipient-test
dispatch_files_after=$(find "$TEST_HOME/messages" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')
[ "$dispatch_files_before" = "$dispatch_files_after" ] || fail "unsafe pane name created a dispatch file"

# Existing loose message data is migrated once to owner-only permissions.
LOOSE_HOME="$TEST_HOME/loose-codex"
mkdir -p "$LOOSE_HOME/messages/queue"
printf 'old secret\n' > "$LOOSE_HOME/messages/old.md"
printf 'old queue\n' > "$LOOSE_HOME/messages/queue/old.tsv"
chmod 755 "$LOOSE_HOME/messages" "$LOOSE_HOME/messages/queue"
chmod 644 "$LOOSE_HOME/messages/old.md" "$LOOSE_HOME/messages/queue/old.tsv"
CODEX_HOME="$LOOSE_HOME" bash -c 'source "$0"; ensure_messages_dir' "$SCRIPT_DIR/lib.sh"
dir_mode=$(stat -c '%a' "$LOOSE_HOME/messages" 2>/dev/null || stat -f '%Lp' "$LOOSE_HOME/messages" 2>/dev/null)
old_mode=$(stat -c '%a' "$LOOSE_HOME/messages/old.md" 2>/dev/null || stat -f '%Lp' "$LOOSE_HOME/messages/old.md" 2>/dev/null)
[ "$dir_mode" = "700" ] || fail "messages directory migration left mode $dir_mode"
[ "$old_mode" = "600" ] || fail "message migration left file mode $old_mode"
[ -f "$LOOSE_HOME/messages/.perms-hardened-v1" ] || fail "permissions migration marker missing"

UNSAFE_HOME="$TEST_HOME/unsafe-codex"
mkdir -p "$UNSAFE_HOME/redirect-target"
ln -s "$UNSAFE_HOME/redirect-target" "$UNSAFE_HOME/messages"
if CODEX_HOME="$UNSAFE_HOME" bash -c 'source "$0"; ensure_messages_dir' "$SCRIPT_DIR/lib.sh" 2>/dev/null; then
  fail "messages directory hardening accepted a symlink root"
fi

MARKER_HOME="$TEST_HOME/marker-symlink-codex"
mkdir -p "$MARKER_HOME/messages"
chmod 700 "$MARKER_HOME/messages"
ln -s "$MARKER_HOME/outside-marker" "$MARKER_HOME/messages/.perms-hardened-v1"
if CODEX_HOME="$MARKER_HOME" bash -c 'source "$0"; ensure_messages_dir' "$SCRIPT_DIR/lib.sh" 2> "$MARKER_HOME/marker.err"; then
  fail "messages directory hardening accepted a dangling marker symlink"
fi
[ ! -e "$MARKER_HOME/outside-marker" ] || fail "dangling marker symlink created an outside file"

LOOSE_QUEUE_HOME="$TEST_HOME/loose-queue-codex"
mkdir -p "$LOOSE_QUEUE_HOME/messages/queue"
chmod 700 "$LOOSE_QUEUE_HOME/messages" "$LOOSE_QUEUE_HOME/messages/queue"
CODEX_HOME="$LOOSE_QUEUE_HOME" bash -c 'source "$0"; ensure_messages_dir' "$SCRIPT_DIR/lib.sh"
chmod 777 "$LOOSE_QUEUE_HOME/messages/queue"
CODEX_HOME="$LOOSE_QUEUE_HOME" bash -c 'source "$0"; enqueue_message recipient-test aaaa0000 send sender-test payload' "$SCRIPT_DIR/lib.sh"
loose_queue_mode=$(stat -c '%a' "$LOOSE_QUEUE_HOME/messages/queue" 2>/dev/null || stat -f '%Lp' "$LOOSE_QUEUE_HOME/messages/queue" 2>/dev/null)
[ "$loose_queue_mode" = "700" ] || fail "post-marker queue directory remained mode $loose_queue_mode"

# The migration marker must not bypass validation of nested runtime paths.
# Queue, lock, archive, and recipient-ledger symlinks must never redirect a
# write outside the trusted messages root.
NESTED_HOME="$TEST_HOME/nested-symlink-codex"
mkdir -p "$NESTED_HOME/messages" "$NESTED_HOME/outside-queue"
chmod 700 "$NESTED_HOME/messages" "$NESTED_HOME/outside-queue"
: > "$NESTED_HOME/messages/.perms-hardened-v1"
chmod 600 "$NESTED_HOME/messages/.perms-hardened-v1"
ln -s "$NESTED_HOME/outside-queue" "$NESTED_HOME/messages/queue"
if CODEX_HOME="$NESTED_HOME" bash -c 'source "$0"; enqueue_message recipient-test aaaa0001 send sender-test payload' \
  "$SCRIPT_DIR/lib.sh" 2> "$NESTED_HOME/queue.err"; then
  fail "message enqueue accepted a symlinked queue directory"
fi
assert_file_contains "$NESTED_HOME/queue.err" 'Refusing symbolic-link message directory'
[ ! -e "$NESTED_HOME/outside-queue/recipient-test.tsv" ] || fail "queue symlink redirected a message write"

LOCK_LINK_HOME="$TEST_HOME/lock-symlink-codex"
mkdir -p "$LOCK_LINK_HOME/messages/queue" "$LOCK_LINK_HOME/outside-locks"
chmod 700 "$LOCK_LINK_HOME/messages" "$LOCK_LINK_HOME/messages/queue" "$LOCK_LINK_HOME/outside-locks"
: > "$LOCK_LINK_HOME/messages/.perms-hardened-v1"
chmod 600 "$LOCK_LINK_HOME/messages/.perms-hardened-v1"
ln -s "$LOCK_LINK_HOME/outside-locks" "$LOCK_LINK_HOME/messages/queue/.locks"
if CODEX_HOME="$LOCK_LINK_HOME" bash -c 'source "$0"; enqueue_message recipient-test aaaa0002 send sender-test payload' \
  "$SCRIPT_DIR/lib.sh" 2> "$LOCK_LINK_HOME/locks.err"; then
  fail "message enqueue accepted a symlinked queue lock directory"
fi
assert_file_contains "$LOCK_LINK_HOME/locks.err" 'Refusing symbolic-link message directory'
[ -z "$(find "$LOCK_LINK_HOME/outside-locks" -mindepth 1 -print -quit)" ] || fail "lock symlink redirected a lock write"

FILE_LINK_HOME="$TEST_HOME/file-symlink-codex"
mkdir -p "$FILE_LINK_HOME/messages/queue"
chmod 700 "$FILE_LINK_HOME/messages" "$FILE_LINK_HOME/messages/queue"
: > "$FILE_LINK_HOME/messages/.perms-hardened-v1"
chmod 600 "$FILE_LINK_HOME/messages/.perms-hardened-v1"
printf 'outside sentinel\n' > "$FILE_LINK_HOME/outside.tsv"
ln -s "$FILE_LINK_HOME/outside.tsv" "$FILE_LINK_HOME/messages/queue/recipient-test.tsv"
if CODEX_HOME="$FILE_LINK_HOME" bash -c 'source "$0"; enqueue_message recipient-test aaaa0003 send sender-test payload' \
  "$SCRIPT_DIR/lib.sh" 2> "$FILE_LINK_HOME/file.err"; then
  fail "message enqueue accepted a symlinked recipient ledger"
fi
assert_file_contains "$FILE_LINK_HOME/file.err" 'Refusing symbolic-link message file'
[ "$(cat "$FILE_LINK_HOME/outside.tsv")" = 'outside sentinel' ] || fail "recipient ledger symlink modified an outside file"

HARDLINK_HOME="$TEST_HOME/hardlink-codex"
mkdir -p "$HARDLINK_HOME/messages/queue"
chmod 700 "$HARDLINK_HOME/messages" "$HARDLINK_HOME/messages/queue"
: > "$HARDLINK_HOME/messages/.perms-hardened-v1"
chmod 600 "$HARDLINK_HOME/messages/.perms-hardened-v1"
printf 'hardlink sentinel\n' > "$HARDLINK_HOME/outside.tsv"
ln "$HARDLINK_HOME/outside.tsv" "$HARDLINK_HOME/messages/queue/recipient-test.tsv"
if CODEX_HOME="$HARDLINK_HOME" bash -c 'source "$0"; enqueue_message recipient-test aaaa0004 send sender-test payload' \
  "$SCRIPT_DIR/lib.sh" 2> "$HARDLINK_HOME/hardlink.err"; then
  fail "message enqueue accepted a multiply-linked recipient ledger"
fi
assert_file_contains "$HARDLINK_HOME/hardlink.err" 'Refusing multiply-linked message file'
[ "$(cat "$HARDLINK_HOME/outside.tsv")" = 'hardlink sentinel' ] || fail "recipient ledger hardlink modified an outside file"

NO_CLOBBER_HOME="$TEST_HOME/no-clobber-codex"
mkdir -p "$NO_CLOBBER_HOME/messages"
chmod 700 "$NO_CLOBBER_HOME/messages"
printf 'existing dispatch\n' > "$NO_CLOBBER_HOME/messages/preplanted.md"
chmod 600 "$NO_CLOBBER_HOME/messages/preplanted.md"
if CODEX_HOME="$NO_CLOBBER_HOME" bash -c 'source "$0"; _write_private_message_file "$1" replacement' \
  "$SCRIPT_DIR/lib.sh" "$NO_CLOBBER_HOME/messages/preplanted.md" 2> "$NO_CLOBBER_HOME/no-clobber.err"; then
  fail "private dispatch writer overwrote a pre-planted file"
fi
assert_file_contains "$NO_CLOBBER_HOME/no-clobber.err" 'Refusing to overwrite existing dispatch file'
[ "$(cat "$NO_CLOBBER_HOME/messages/preplanted.md")" = 'existing dispatch' ] || fail "private dispatch writer changed a pre-planted file"

LOG_LINK_HOME="$TEST_HOME/log-symlink-codex"
mkdir -p "$LOG_LINK_HOME/messages"
chmod 700 "$LOG_LINK_HOME/messages"
: > "$LOG_LINK_HOME/messages/.perms-hardened-v1"
chmod 600 "$LOG_LINK_HOME/messages/.perms-hardened-v1"
printf 'log sentinel\n' > "$LOG_LINK_HOME/outside-log.tsv"
ln -s "$LOG_LINK_HOME/outside-log.tsv" "$LOG_LINK_HOME/messages/sent-log.tsv"
CODEX_HOME="$LOG_LINK_HOME" bash -c 'source "$0"; log_sent_message aaaa0005 sender-test peer send queued payload' \
  "$SCRIPT_DIR/lib.sh" 2> "$LOG_LINK_HOME/log.err"
assert_file_contains "$LOG_LINK_HOME/log.err" 'Refusing symbolic-link message file'
[ "$(cat "$LOG_LINK_HOME/outside-log.tsv")" = 'log sentinel' ] || fail "sent-log symlink modified an outside file"

ARCHIVE_LINK_HOME="$TEST_HOME/archive-symlink-codex"
mkdir -p "$ARCHIVE_LINK_HOME/messages" "$ARCHIVE_LINK_HOME/outside-archive"
chmod 700 "$ARCHIVE_LINK_HOME/messages" "$ARCHIVE_LINK_HOME/outside-archive"
: > "$ARCHIVE_LINK_HOME/messages/.perms-hardened-v1"
chmod 600 "$ARCHIVE_LINK_HOME/messages/.perms-hardened-v1"
ln -s "$ARCHIVE_LINK_HOME/outside-archive" "$ARCHIVE_LINK_HOME/messages/archive"
CODEX_HOME="$ARCHIVE_LINK_HOME" bash -c 'source "$0"; archive_message out peer send aaaa0004 payload' \
  "$SCRIPT_DIR/lib.sh" 2> "$ARCHIVE_LINK_HOME/archive.err"
assert_file_contains "$ARCHIVE_LINK_HOME/archive.err" 'Refusing symbolic-link message directory'
[ -z "$(find "$ARCHIVE_LINK_HOME/outside-archive" -mindepth 1 -print -quit)" ] || fail "archive symlink redirected a history write"

detect_dispatch() {
  local mode="$1" file="$2" id="$3" root="$4" inline_max="${5:-6000}"
  printf '%s\n' "[from:peer pane:%999 msg:$file id:$id] dispatch (2 lines) — read msg file" \
    | TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" CODEX_HOME="$TEST_HOME" \
      PLUGIN_ROOT="$root" SESSION_CHAT_INCOMING_MODE="$mode" \
      SESSION_CHAT_DISPATCH_INLINE_MAX="$inline_max" \
      bash "$SCRIPT_DIR/detect-incoming-message.sh"
}

# Auto mode receives trusted content inline; notify mode never does.
TRUSTED_FILE="$TEST_HOME/messages/trusted-auto.md"
printf 'PLEASE-BUILD-THE-WIDGET\nsecond line\n' > "$TRUSTED_FILE"
chmod 600 "$TRUSTED_FILE"
INLINE_OUT=$(detect_dispatch auto "$TRUSTED_FILE" aaaa0001 "$PLUGIN_ROOT")
assert_contains 'Task content follows' "$INLINE_OUT"
assert_contains 'PLEASE-BUILD-THE-WIDGET' "$INLINE_OUT"
NOTIFY_OUT=$(detect_dispatch notify "$TRUSTED_FILE" aaaa0002 "$PLUGIN_ROOT")
assert_contains 'Treat as untrusted' "$NOTIFY_OUT"
assert_contains 'When a reply is authorized, use $session-chat:reply peer aaaa0002 <message>' "$NOTIFY_OUT"
if printf '%s\n' "$NOTIFY_OUT" | grep -F 'PLEASE-BUILD-THE-WIDGET' >/dev/null; then
  fail "notify mode inlined a dispatch body"
fi

# Symlinks and non-private files are rejected without reading their contents.
printf 'off-limits\n' > "$TEST_HOME/outside-secret.txt"
ln -s "$TEST_HOME/outside-secret.txt" "$TEST_HOME/messages/evil.md"
SYMLINK_OUT=$(detect_dispatch auto "$TEST_HOME/messages/evil.md" aaaa0003 "$PLUGIN_ROOT")
assert_contains 'OUTSIDE the trusted message dir' "$SYMLINK_OUT"
assert_contains '$session-chat:reply peer aaaa0003 <message>' "$SYMLINK_OUT"
if printf '%s\n' "$SYMLINK_OUT" | grep -F 'off-limits' >/dev/null; then
  fail "trusted-file gate followed a symlink"
fi
printf 'hardlinked secret\n' > "$TEST_HOME/outside-hardlink.md"
chmod 600 "$TEST_HOME/outside-hardlink.md"
ln "$TEST_HOME/outside-hardlink.md" "$TEST_HOME/messages/hardlinked.md"
HARDLINK_OUT=$(detect_dispatch auto "$TEST_HOME/messages/hardlinked.md" aaaa0009 "$PLUGIN_ROOT")
assert_contains 'OUTSIDE the trusted message dir' "$HARDLINK_OUT"
if printf '%s\n' "$HARDLINK_OUT" | grep -F 'hardlinked secret' >/dev/null; then
  fail "trusted-file gate read a multiply-linked dispatch file"
fi
mkdir -p "$TEST_HOME/no-lib"
LOOSE_FILE="$TEST_HOME/messages/loose.md"
printf 'loose secret\n' > "$LOOSE_FILE"
chmod 644 "$LOOSE_FILE"
LOOSE_OUT=$(detect_dispatch auto "$LOOSE_FILE" aaaa0004 "$TEST_HOME/no-lib")
assert_contains 'OUTSIDE the trusted message dir' "$LOOSE_OUT"
if printf '%s\n' "$LOOSE_OUT" | grep -F 'loose secret' >/dev/null; then
  fail "trusted-file gate read a group/world-readable file"
fi

# Both per-dispatch inline content and total hook context are bounded.
BIG_FILE="$TEST_HOME/messages/big.md"
{ printf 'HEAD-MARKER\n'; head -c 8000 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$BIG_FILE"
chmod 600 "$BIG_FILE"
BIG_OUT=$(detect_dispatch auto "$BIG_FILE" aaaa0005 "$PLUGIN_ROOT")
assert_contains 'dispatch body truncated at 6000 characters' "$BIG_OUT"
HUGE_FILE="$TEST_HOME/messages/huge.md"
{ printf 'HUGE-MARKER\n'; head -c 12000 /dev/zero | tr '\0' 'y'; printf '\n'; } > "$HUGE_FILE"
chmod 600 "$HUGE_FILE"
HUGE_OUT=$(detect_dispatch auto "$HUGE_FILE" aaaa0006 "$PLUGIN_ROOT" 12000)
assert_contains 'truncated by session-chat' "$HUGE_OUT"

# The inline limit is in Unicode characters, not bytes. At byte 6000 this
# emoji used to be split by head -c, producing invalid JSON or a lost glyph.
UTF8_FILE="$TEST_HOME/messages/utf8-boundary.md"
{ head -c 5999 /dev/zero | tr '\0' 'u'; printf '🙂TAIL-MUST-BE-TRUNCATED\n'; } > "$UTF8_FILE"
chmod 600 "$UTF8_FILE"
UTF8_OUT=$(detect_dispatch auto "$UTF8_FILE" aaaa0007 "$PLUGIN_ROOT")
assert_contains '🙂' "$UTF8_OUT"
assert_contains 'dispatch body truncated at 6000 characters' "$UTF8_OUT"
if printf '%s' "$UTF8_OUT" | grep -F 'TAIL-MUST-BE-TRUNCATED' >/dev/null; then
  fail "UTF-8 character cap retained content after the 6000th character"
fi
printf '%s' "$UTF8_OUT" | python3 -c '
import json, sys
context = json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]
assert "🙂" in context
assert "\ufffd" not in context
assert len(context) <= 10000
' || fail "UTF-8 boundary output was not valid, bounded JSON"

# A live dispatch path may contain spaces (for example CODEX_HOME under a
# workspace directory). Parse through the explicit ` id:<uid>]` delimiter,
# never the first space, or the only live reference becomes unreadable.
SPACE_HOME="$TEST_HOME/codex home"
mkdir -p "$SPACE_HOME/messages"
SPACE_FILE="$SPACE_HOME/messages/space task.md"
printf 'SPACE-PATH-DISPATCH-BODY\n' > "$SPACE_FILE"
chmod 700 "$SPACE_HOME/messages"
chmod 600 "$SPACE_FILE"
SPACE_OUT=$(printf '%s\n' "[from:peer pane:%999 msg:$SPACE_FILE id:aaaa0008] dispatch (1 lines) — read msg file" \
  | TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" CODEX_HOME="$SPACE_HOME" \
    PLUGIN_ROOT="$PLUGIN_ROOT" SESSION_CHAT_INCOMING_MODE=auto \
    bash "$SCRIPT_DIR/detect-incoming-message.sh")
assert_contains 'SPACE-PATH-DISPATCH-BODY' "$SPACE_OUT"
assert_contains "$SPACE_FILE" "$SPACE_OUT"

# Fan-in is selected before mutation. Only the fully rendered prefix that fits
# the 10k context may drain; later rows must remain queued for the next hook.
FAN_ONE="FANIN-ONE-$(head -c 3300 /dev/zero | tr '\0' 'a')"
FAN_TWO="FANIN-TWO-$(head -c 3300 /dev/zero | tr '\0' 'b')"
FAN_THREE="FANIN-THREE-$(head -c 3300 /dev/zero | tr '\0' 'c')"
for fan_spec in "bbbb0001:$FAN_ONE" "bbbb0002:$FAN_TWO" "bbbb0003:$FAN_THREE"; do
  fan_id=${fan_spec%%:*}
  fan_payload=${fan_spec#*:}
  CODEX_HOME="$TEST_HOME" bash -c 'source "$0"; enqueue_message recipient-test "$1" send sender-test "$2"; mark_message_ready recipient-test "$1"' \
    "$SCRIPT_DIR/lib.sh" "$fan_id" "$fan_payload"
done
FAN_OUT="$(printf '%s' '{"hook_event_name":"UserPromptSubmit"}' | TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" \
  CODEX_HOME="$TEST_HOME" PLUGIN_ROOT="$PLUGIN_ROOT" SESSION_CHAT_INCOMING_MODE=auto \
  bash "$SCRIPT_DIR/detect-incoming-message.sh")"
assert_contains 'FANIN-ONE-' "$FAN_OUT"
assert_contains 'FANIN-TWO-' "$FAN_OUT"
if printf '%s' "$FAN_OUT" | grep -F 'FANIN-THREE-' >/dev/null; then
  fail "fan-in hook displayed a row beyond the context-sized prefix"
fi
printf '%s' "$FAN_OUT" | python3 -c '
import json, sys
context = json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]
assert len(context) <= 10000
' || fail "fan-in hook emitted invalid or oversized JSON"
assert_file_contains "$TEST_HOME/messages/queue/recipient-test.tsv" 'bbbb0003'
if grep -E 'bbbb0001|bbbb0002' "$TEST_HOME/messages/queue/recipient-test.tsv" >/dev/null; then
  fail "fan-in hook retained a row it displayed"
fi
FAN_REMAINDER="$(printf '%s' '{"hook_event_name":"UserPromptSubmit"}' | TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" \
  CODEX_HOME="$TEST_HOME" PLUGIN_ROOT="$PLUGIN_ROOT" SESSION_CHAT_INCOMING_MODE=auto \
  bash "$SCRIPT_DIR/detect-incoming-message.sh")"
assert_contains 'FANIN-THREE-' "$FAN_REMAINDER"
if grep -F 'bbbb0003' "$TEST_HOME/messages/queue/recipient-test.tsv" >/dev/null; then
  fail "fan-in remainder did not drain on the next hook"
fi

# Hook output is the commit point. Force its stdout closed so the final JSON
# printf fails, then prove the selected row was neither dequeued nor marked
# recent. A normal retry must surface and claim that same row.
CODEX_HOME="$TEST_HOME" bash -c 'source "$0"; enqueue_message recipient-test cccc0001 send sender-test "POST-EMIT-RETRY"; mark_message_ready recipient-test cccc0001' \
  "$SCRIPT_DIR/lib.sh"
printf '%s' '{"hook_event_name":"UserPromptSubmit"}' > "$TEST_HOME/emit-failure-input.json"
set +e
TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" CODEX_HOME="$TEST_HOME" \
  PLUGIN_ROOT="$PLUGIN_ROOT" SESSION_CHAT_INCOMING_MODE=auto \
  bash "$SCRIPT_DIR/detect-incoming-message.sh" < "$TEST_HOME/emit-failure-input.json" \
  >&- 2> "$TEST_HOME/emit-failure.err"
EMIT_FAILURE_RC=$?
set -e
[ "$EMIT_FAILURE_RC" -ne 0 ] || fail "closed stdout did not fail the incoming hook emit"
assert_file_contains "$TEST_HOME/messages/queue/recipient-test.tsv" 'cccc0001'
if grep -F 'cccc0001' "$TEST_HOME/messages/queue/.recent-recipient-test.tsv" 2>/dev/null; then
  fail "failed hook emit marked the retained row recent"
fi
POST_EMIT_RETRY="$(TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" CODEX_HOME="$TEST_HOME" \
  PLUGIN_ROOT="$PLUGIN_ROOT" SESSION_CHAT_INCOMING_MODE=auto \
  bash "$SCRIPT_DIR/detect-incoming-message.sh" < "$TEST_HOME/emit-failure-input.json")"
assert_contains 'POST-EMIT-RETRY' "$POST_EMIT_RETRY"
if grep -F 'cccc0001' "$TEST_HOME/messages/queue/recipient-test.tsv" >/dev/null; then
  fail "successfully retried hook output did not claim its emitted row"
fi

# A live prompt and its ready durable copy surface once. The live id joins the
# same post-emit atomic claim even though inbox selection deliberately skips it.
CODEX_HOME="$TEST_HOME" bash -c 'source "$0"; enqueue_message recipient-test dddd0001 send sender-test "queued live duplicate"; mark_message_ready recipient-test dddd0001' \
  "$SCRIPT_DIR/lib.sh"
LIVE_COPY_OUT="$(printf '%s\n' '[from:sender-test pane:%999 id:dddd0001] live copy' \
  | TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" CODEX_HOME="$TEST_HOME" \
    PLUGIN_ROOT="$PLUGIN_ROOT" SESSION_CHAT_INCOMING_MODE=auto \
    bash "$SCRIPT_DIR/detect-incoming-message.sh")"
assert_contains 'message from [sender-test]' "$LIVE_COPY_OUT"
if grep -F 'dddd0001' "$TEST_HOME/messages/queue/recipient-test.tsv" >/dev/null; then
  fail "post-emit claim retained the redundant durable live id"
fi
LIVE_COPY_DUP="$(printf '%s\n' '[from:sender-test pane:%999 id:dddd0001] live copy' \
  | TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" CODEX_HOME="$TEST_HOME" \
    PLUGIN_ROOT="$PLUGIN_ROOT" SESSION_CHAT_INCOMING_MODE=auto \
    bash "$SCRIPT_DIR/detect-incoming-message.sh")"
assert_empty "$LIVE_COPY_DUP" "post-emit live id duplicate"

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
