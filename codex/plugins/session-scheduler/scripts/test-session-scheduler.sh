#!/usr/bin/env bash
# test-session-scheduler.sh — Smoke tests for session-scheduler
# Supported platforms: macOS, Linux
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/session-scheduler-test.XXXXXX")"
SESSION="session-scheduler-test-$$"

cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -rf "$TEST_HOME"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_sender() {
  TMUX="$TMUX_ENV" TMUX_PANE="$SENDER" CODEX_HOME="$TEST_HOME" SESSION_SCHEDULER_HOME="$TEST_HOME/scheduler" SESSION_CHAT_ROOT_OVERRIDE="$SESSION_CHAT_ROOT" "$@"
}

run_recipient() {
  TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" CODEX_HOME="$TEST_HOME" SESSION_SCHEDULER_HOME="$TEST_HOME/scheduler" SESSION_CHAT_ROOT_OVERRIDE="$SESSION_CHAT_ROOT" "$@"
}

SESSION_CHAT_ROOT="${SESSION_CHAT_ROOT_OVERRIDE:-${SESSION_CHAT_PLUGIN_ROOT:-$SCRIPT_DIR/../../session-chat}}"
[ -d "$SESSION_CHAT_ROOT" ] || SESSION_CHAT_ROOT="$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.12.1"

tmux new-session -d -x 220 -y 40 -s "$SESSION" "cat"
tmux split-window -t "$SESSION" "cat" >/dev/null
SENDER=$(tmux list-panes -t "$SESSION" -F '#{pane_id}' | sed -n '1p')
RECIPIENT=$(tmux list-panes -t "$SESSION" -F '#{pane_id}' | sed -n '2p')
tmux set-option -p -t "$SENDER" @name scheduler-orchestrator
tmux set-option -p -t "$RECIPIENT" @name scheduler-executor
TMUX_ENV=$(tmux display-message -p -t "$SENDER" '#{socket_path},#{pid},0')

created=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Smoke task" --meta area=test)
echo "$created" | grep 'Created task' >/dev/null || fail "task-new did not create"
TASK_ID=$(printf '%s\n' "$created" | awk '{print $3}' | sed 's/:$//')
[ -f "$TEST_HOME/scheduler/tasks/$TASK_ID.json" ] || fail "task file missing"

run_sender bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$TASK_ID" "Do the smoke task"
tmux capture-pane -J -t "$RECIPIENT" -p -S -200 | grep "$TASK_ID" >/dev/null || fail "assigned task did not reach recipient"
run_sender bash "$SCRIPT_DIR/task-status.sh" "$TASK_ID" | grep 'assigned' >/dev/null || fail "task not assigned"

run_recipient bash "$SCRIPT_DIR/task-done.sh" "$TASK_ID" "completed"
run_sender bash "$SCRIPT_DIR/task-status.sh" "$TASK_ID" | grep 'done' >/dev/null || fail "task not done"
tmux capture-pane -J -t "$SENDER" -p -S -200 | grep "Task $TASK_ID done" >/dev/null || fail "done ack did not reach assigner"

blocked=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Blocked task")
BLOCK_ID=$(printf '%s\n' "$blocked" | awk '{print $3}' | sed 's/:$//')
run_sender bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$BLOCK_ID" "Block this task"
run_recipient bash "$SCRIPT_DIR/task-block.sh" "$BLOCK_ID" "blocked reason"
run_sender bash "$SCRIPT_DIR/task-status.sh" "$BLOCK_ID" | grep 'blocked' >/dev/null || fail "task not blocked"

run_sender bash "$SCRIPT_DIR/tasks-clean.sh" --older-than 0s > "$TEST_HOME/clean.txt"
grep 'Dry run only' "$TEST_HOME/clean.txt" >/dev/null || fail "clean dry-run missing"
run_sender bash "$SCRIPT_DIR/tasks-clean.sh" --older-than 0s --status done --apply > "$TEST_HOME/clean-apply.txt"
grep 'Summary' "$TEST_HOME/clean-apply.txt" >/dev/null || fail "clean apply missing summary"

run_sender bash "$SCRIPT_DIR/scheduler-doctor.sh" | grep 'session-chat version' >/dev/null || fail "doctor missing session-chat version"

echo "session-scheduler smoke tests passed"
