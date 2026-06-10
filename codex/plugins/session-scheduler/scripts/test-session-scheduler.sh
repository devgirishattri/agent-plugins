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
[ -d "$SESSION_CHAT_ROOT" ] || SESSION_CHAT_ROOT="$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.12.2"

tmux new-session -d -x 220 -y 40 -s "$SESSION" "cat"
tmux split-window -t "$SESSION" "cat" >/dev/null
SENDER=$(tmux list-panes -t "$SESSION" -F '#{pane_id}' | sed -n '1p')
RECIPIENT=$(tmux list-panes -t "$SESSION" -F '#{pane_id}' | sed -n '2p')
tmux set-option -p -t "$SENDER" @name scheduler-orchestrator
tmux set-option -p -t "$RECIPIENT" @name scheduler-executor
TMUX_ENV=$(tmux display-message -p -t "$SENDER" '#{socket_path},#{pid},0')

created=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Smoke task" --meta area=test)
echo "$created" | grep 'Created task' >/dev/null || fail "task-new did not create"
TASK_ID=$(printf '%s\n' "$created" | awk '/^Created task/{print $3}' | sed 's/:$//')
[ -f "$TEST_HOME/scheduler/tasks/$TASK_ID.json" ] || fail "task file missing"

run_sender bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$TASK_ID" "Do the smoke task"
tmux capture-pane -J -t "$RECIPIENT" -p -S -200 | grep "$TASK_ID" >/dev/null || fail "assigned task did not reach recipient"
run_sender bash "$SCRIPT_DIR/task-status.sh" "$TASK_ID" | grep 'assigned' >/dev/null || fail "task not assigned"

run_recipient bash "$SCRIPT_DIR/task-done.sh" "$TASK_ID" "completed"
run_sender bash "$SCRIPT_DIR/task-status.sh" "$TASK_ID" | grep 'done' >/dev/null || fail "task not done"
tmux capture-pane -J -t "$SENDER" -p -S -200 | grep "Task $TASK_ID done" >/dev/null || fail "done ack did not reach assigner"

blocked=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Blocked task")
BLOCK_ID=$(printf '%s\n' "$blocked" | awk '/^Created task/{print $3}' | sed 's/:$//')
run_sender bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$BLOCK_ID" "Block this task"
run_recipient bash "$SCRIPT_DIR/task-block.sh" "$BLOCK_ID" "blocked reason"
run_sender bash "$SCRIPT_DIR/task-status.sh" "$BLOCK_ID" | grep 'blocked' >/dev/null || fail "task not blocked"

run_sender bash "$SCRIPT_DIR/tasks-clean.sh" --older-than 0s > "$TEST_HOME/clean.txt"
grep 'Dry run only' "$TEST_HOME/clean.txt" >/dev/null || fail "clean dry-run missing"
run_sender bash "$SCRIPT_DIR/tasks-clean.sh" --older-than 0s --status done --apply > "$TEST_HOME/clean-apply.txt"
grep 'Summary' "$TEST_HOME/clean-apply.txt" >/dev/null || fail "clean apply missing summary"

run_sender bash "$SCRIPT_DIR/scheduler-doctor.sh" | grep 'session-chat version' >/dev/null || fail "doctor missing session-chat version"
run_sender bash "$SCRIPT_DIR/scheduler-doctor.sh" | grep 'date math: OK' >/dev/null || fail "doctor date math check failed"

# --- Illegal transition rejected (created -> done) ---
illegal=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Illegal transition task")
ILLEGAL_ID=$(printf '%s\n' "$illegal" | awk '/^Created task/{print $3}' | sed 's/:$//')
if run_sender bash "$SCRIPT_DIR/task-done.sh" "$ILLEGAL_ID" "premature" 2> "$TEST_HOME/illegal.txt"; then
  fail "illegal transition created->done was not rejected"
fi
grep 'Illegal status transition' "$TEST_HOME/illegal.txt" >/dev/null || fail "illegal transition error message missing"
run_sender bash "$SCRIPT_DIR/task-status.sh" "$ILLEGAL_ID" | grep 'created' >/dev/null || fail "status changed despite rejected transition"

# --- Forced transition records 'forced' in history note ---
run_sender bash "$SCRIPT_DIR/task-done.sh" "$ILLEGAL_ID" --force "override" >/dev/null
forced_note=$(jq -r '.history[-1].note' "$TEST_HOME/scheduler/tasks/$ILLEGAL_ID.json")
printf '%s\n' "$forced_note" | grep 'forced' >/dev/null || fail "forced transition did not record 'forced' in note"

# --- Review flow: assign -> review -> done (+ started_at, duration) ---
review=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Review task")
REVIEW_ID=$(printf '%s\n' "$review" | awk '/^Created task/{print $3}' | sed 's/:$//')
run_sender bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$REVIEW_ID" "Do reviewable work"
started=$(jq -r '.started_at // empty' "$TEST_HOME/scheduler/tasks/$REVIEW_ID.json")
[ -n "$started" ] || fail "started_at not stamped on assignment"
run_recipient bash "$SCRIPT_DIR/task-review.sh" "$REVIEW_ID" "commit abc1234"
run_sender bash "$SCRIPT_DIR/task-status.sh" "$REVIEW_ID" | grep 'review' >/dev/null || fail "task not in review"
tmux capture-pane -J -t "$SENDER" -p -S -200 | grep "Task $REVIEW_ID ready for REVIEW" >/dev/null || fail "review ack did not reach assigner"
run_sender bash "$SCRIPT_DIR/task-done.sh" "$REVIEW_ID" "approved"
run_sender bash "$SCRIPT_DIR/task-status.sh" "$REVIEW_ID" | grep 'done' >/dev/null || fail "reviewed task not done"
duration=$(jq -r '.duration_seconds // empty' "$TEST_HOME/scheduler/tasks/$REVIEW_ID.json")
[ -n "$duration" ] || fail "duration_seconds not recorded on done"

# --- depends_on gating ---
dep=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Dependency task")
DEP_ID=$(printf '%s\n' "$dep" | awk '/^Created task/{print $3}' | sed 's/:$//')
gated=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Gated task" --depends-on "$DEP_ID")
GATED_ID=$(printf '%s\n' "$gated" | awk '/^Created task/{print $3}' | sed 's/:$//')
if run_sender bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$GATED_ID" "Gated work" 2> "$TEST_HOME/gated.txt"; then
  fail "assign with unmet dependency was not refused"
fi
grep 'unmet dependencies' "$TEST_HOME/gated.txt" >/dev/null || fail "unmet dependency error missing"
grep "$DEP_ID" "$TEST_HOME/gated.txt" >/dev/null || fail "unmet dependency error does not name the dep"
run_sender bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$DEP_ID" "Dep work"
run_recipient bash "$SCRIPT_DIR/task-done.sh" "$DEP_ID" "dep complete"
run_sender bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$GATED_ID" "Gated work" || fail "assign failed after dependency done"

# --- --depends-on rejects nonexistent ids ---
if run_sender bash "$SCRIPT_DIR/task-new.sh" "Bad deps task" --depends-on "no-such-task" 2> "$TEST_HOME/baddep.txt"; then
  fail "task-new accepted nonexistent dependency"
fi
grep 'does not exist' "$TEST_HOME/baddep.txt" >/dev/null || fail "missing-dependency error missing"

# --- eta stored + OVERDUE flag ---
eta=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Eta task" --stage execute)
ETA_ID=$(printf '%s\n' "$eta" | awk '/^Created task/{print $3}' | sed 's/:$//')
run_sender bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$ETA_ID" --eta 5 "Timed work"
eta_at=$(jq -r '.eta_at // empty' "$TEST_HOME/scheduler/tasks/$ETA_ID.json")
[ -n "$eta_at" ] || fail "eta_at not stored"
jq '.eta_at = "2020-01-01T00:00:00Z"' "$TEST_HOME/scheduler/tasks/$ETA_ID.json" > "$TEST_HOME/eta.tmp"
mv "$TEST_HOME/eta.tmp" "$TEST_HOME/scheduler/tasks/$ETA_ID.json"
run_sender bash "$SCRIPT_DIR/task-status.sh" | grep "$ETA_ID" | grep 'OVERDUE' >/dev/null || fail "OVERDUE flag missing"

# --- task-board renders groups + totals ---
run_sender bash "$SCRIPT_DIR/task-board.sh" > "$TEST_HOME/board.txt"
grep 'Stage: execute' "$TEST_HOME/board.txt" >/dev/null || fail "board missing stage group"
grep "$ETA_ID" "$TEST_HOME/board.txt" >/dev/null || fail "board missing task row"
grep 'OVERDUE' "$TEST_HOME/board.txt" >/dev/null || fail "board missing OVERDUE flag"
grep -E '[0-9]+ active:' "$TEST_HOME/board.txt" >/dev/null || fail "board missing totals summary"

# --- task-status --by-stage groups output ---
run_sender bash "$SCRIPT_DIR/task-status.sh" --by-stage > "$TEST_HOME/bystage.txt"
grep 'Stage: execute' "$TEST_HOME/bystage.txt" >/dev/null || fail "by-stage missing stage group"
grep "$ETA_ID" "$TEST_HOME/bystage.txt" >/dev/null || fail "by-stage missing task row"

# --- --context attach + missing context rejected ---
mkdir -p "$TEST_HOME/contexts"
echo "# shared context for ProjectA" > "$TEST_HOME/contexts/ctx-1.md"
ctx=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Context task")
CTX_ID=$(printf '%s\n' "$ctx" | awk '/^Created task/{print $3}' | sed 's/:$//')
run_sender env SESSION_CONTEXT_HOME="$TEST_HOME/contexts" bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$CTX_ID" --context ctx-1 "Context work"
grep '## Context' "$TEST_HOME/scheduler/prompts/$CTX_ID.md" >/dev/null || fail "prompt missing context section"
grep 'context-load ctx-1' "$TEST_HOME/scheduler/prompts/$CTX_ID.md" >/dev/null || fail "prompt missing context-load line"
meta_ctx=$(jq -r '.meta.context // empty' "$TEST_HOME/scheduler/tasks/$CTX_ID.json")
[ "$meta_ctx" = "ctx-1" ] || fail "meta.context not recorded"
if run_sender env SESSION_CONTEXT_HOME="$TEST_HOME/contexts" bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$CTX_ID" --context no-such-ctx "More work" 2> "$TEST_HOME/ctxmiss.txt"; then
  fail "assign with missing context was not refused"
fi
grep 'not found' "$TEST_HOME/ctxmiss.txt" >/dev/null || fail "missing-context error missing"

# --- dispatch failure rolls back new prompt + leaves ledger untouched ---
FAIL_STUB="$TEST_HOME/failstub/scripts"
mkdir -p "$FAIL_STUB"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAIL_STUB/dispatch-to-session.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAIL_STUB/send-message.sh"
chmod +x "$FAIL_STUB"/*.sh
rb=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Rollback task")
RB_ID=$(printf '%s\n' "$rb" | awk '/^Created task/{print $3}' | sed 's/:$//')
if run_sender env SESSION_CHAT_ROOT_OVERRIDE="$TEST_HOME/failstub" bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$RB_ID" "Doomed work" 2>/dev/null; then
  fail "assign with failing dispatch did not fail"
fi
[ ! -f "$TEST_HOME/scheduler/prompts/$RB_ID.md" ] || fail "orphaned prompt file left after dispatch failure"
run_sender bash "$SCRIPT_DIR/task-status.sh" "$RB_ID" | grep 'created' >/dev/null || fail "ledger updated despite dispatch failure"

echo "session-scheduler smoke tests passed"
