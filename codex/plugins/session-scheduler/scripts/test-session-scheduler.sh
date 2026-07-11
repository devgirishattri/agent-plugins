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

path_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

run_sender() {
  TMUX="$TMUX_ENV" TMUX_PANE="$SENDER" CODEX_HOME="$TEST_HOME" SESSION_SCHEDULER_HOME="$TEST_HOME/scheduler" SESSION_CHAT_ROOT_OVERRIDE="$SESSION_CHAT_ROOT" "$@"
}

run_recipient() {
  TMUX="$TMUX_ENV" TMUX_PANE="$RECIPIENT" CODEX_HOME="$TEST_HOME" SESSION_SCHEDULER_HOME="$TEST_HOME/scheduler" SESSION_CHAT_ROOT_OVERRIDE="$SESSION_CHAT_ROOT" "$@"
}

run_reviewer() {
  TMUX="$TMUX_ENV" TMUX_PANE="$REVIEWER" CODEX_HOME="$TEST_HOME" SESSION_SCHEDULER_HOME="$TEST_HOME/scheduler" SESSION_CHAT_ROOT_OVERRIDE="$SESSION_CHAT_ROOT" "$@"
}

SESSION_CHAT_ROOT="${SESSION_CHAT_ROOT_OVERRIDE:-${SESSION_CHAT_PLUGIN_ROOT:-$SCRIPT_DIR/../../session-chat}}"
[ -d "$SESSION_CHAT_ROOT" ] || fail "session-chat test dependency missing: $SESSION_CHAT_ROOT"

# Existing owner-owned ledgers are safely migrated to private modes before any
# operation. Unsafe symlink roots fail closed without writing through them.
LEGACY_SCHEDULER="$TEST_HOME/legacy-scheduler"
mkdir -p "$LEGACY_SCHEDULER/tasks" "$LEGACY_SCHEDULER/prompts"
printf '{"id":"legacy","status":"created"}\n' > "$LEGACY_SCHEDULER/tasks/legacy.json"
printf 'legacy prompt\n' > "$LEGACY_SCHEDULER/prompts/legacy.md"
chmod 755 "$LEGACY_SCHEDULER" "$LEGACY_SCHEDULER/tasks" "$LEGACY_SCHEDULER/prompts"
chmod 644 "$LEGACY_SCHEDULER/tasks/legacy.json" "$LEGACY_SCHEDULER/prompts/legacy.md"
SESSION_SCHEDULER_HOME="$LEGACY_SCHEDULER" bash "$SCRIPT_DIR/task-status.sh" --all >/dev/null
[ "$(path_mode "$LEGACY_SCHEDULER")" = "700" ] || fail "legacy scheduler root was not migrated to mode 700"
[ "$(path_mode "$LEGACY_SCHEDULER/tasks")" = "700" ] || fail "legacy tasks directory was not migrated to mode 700"
[ "$(path_mode "$LEGACY_SCHEDULER/prompts")" = "700" ] || fail "legacy prompts directory was not migrated to mode 700"
[ "$(path_mode "$LEGACY_SCHEDULER/tasks/legacy.json")" = "600" ] || fail "legacy task record was not migrated to mode 600"
[ "$(path_mode "$LEGACY_SCHEDULER/prompts/legacy.md")" = "600" ] || fail "legacy prompt was not migrated to mode 600"

UNSAFE_SCHEDULER_TARGET="$TEST_HOME/unsafe-scheduler-target"
UNSAFE_SCHEDULER_ROOT="$TEST_HOME/unsafe-scheduler-root"
mkdir -p "$UNSAFE_SCHEDULER_TARGET"
ln -s "$UNSAFE_SCHEDULER_TARGET" "$UNSAFE_SCHEDULER_ROOT"
if SESSION_SCHEDULER_HOME="$UNSAFE_SCHEDULER_ROOT" bash "$SCRIPT_DIR/task-status.sh" --all \
  > /dev/null 2> "$TEST_HOME/unsafe-scheduler.err"; then
  fail "scheduler accepted a symlink ledger root"
fi
grep 'Refusing unsafe scheduler root' "$TEST_HOME/unsafe-scheduler.err" >/dev/null \
  || fail "scheduler symlink-root rejection did not explain the unsafe root"
[ ! -e "$UNSAFE_SCHEDULER_TARGET/tasks" ] || fail "scheduler wrote through the rejected symlink root"

UNSAFE_TASK_TREE="$TEST_HOME/unsafe-task-tree"
UNSAFE_TASK_TARGET="$TEST_HOME/unsafe-task-target.json"
mkdir -p "$UNSAFE_TASK_TREE/tasks" "$UNSAFE_TASK_TREE/prompts"
printf '{"id":"outside","status":"created","name":"outside"}\n' > "$UNSAFE_TASK_TARGET"
ln -s "$UNSAFE_TASK_TARGET" "$UNSAFE_TASK_TREE/tasks/linked.json"
if SESSION_SCHEDULER_HOME="$UNSAFE_TASK_TREE" bash "$SCRIPT_DIR/task-status.sh" --all \
  > /dev/null 2> "$TEST_HOME/unsafe-task-tree.err"; then
  fail "scheduler accepted a nested task-record symlink"
fi
grep 'scheduler tree containing a symlink' "$TEST_HOME/unsafe-task-tree.err" >/dev/null \
  || fail "nested task-record symlink rejection did not explain the unsafe tree"

RACE_SCHEDULER="$TEST_HOME/race-scheduler"
scheduler_race_pids=""
for race_i in 1 2 3 4; do
  SESSION_SCHEDULER_HOME="$RACE_SCHEDULER" bash "$SCRIPT_DIR/task-status.sh" --all \
    > "$TEST_HOME/scheduler-race-$race_i.out" &
  scheduler_race_pids="$scheduler_race_pids $!"
done
for race_pid in $scheduler_race_pids; do
  wait "$race_pid" || fail "concurrent scheduler root initialization failed"
done
[ "$(path_mode "$RACE_SCHEDULER")" = "700" ] || fail "concurrently initialized scheduler root is not mode 700"
[ "$(path_mode "$RACE_SCHEDULER/tasks")" = "700" ] || fail "concurrently initialized tasks directory is not mode 700"
[ "$(path_mode "$RACE_SCHEDULER/prompts")" = "700" ] || fail "concurrently initialized prompts directory is not mode 700"

tmux new-session -d -x 220 -y 40 -s "$SESSION" "cat"
tmux split-window -t "$SESSION" "cat" >/dev/null
tmux split-window -t "$SESSION" "cat" >/dev/null
SENDER=$(tmux list-panes -t "$SESSION" -F '#{pane_id}' | sed -n '1p')
RECIPIENT=$(tmux list-panes -t "$SESSION" -F '#{pane_id}' | sed -n '2p')
REVIEWER=$(tmux list-panes -t "$SESSION" -F '#{pane_id}' | sed -n '3p')
tmux set-option -p -t "$SENDER" @name scheduler-orchestrator
tmux set-option -p -t "$RECIPIENT" @name scheduler-executor
tmux set-option -p -t "$REVIEWER" @name scheduler-reviewer
TMUX_ENV=$(tmux display-message -p -t "$SENDER" '#{socket_path},#{pid},0')

created=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Smoke task" --meta area=test)
echo "$created" | grep 'Created task' >/dev/null || fail "task-new did not create"
TASK_ID=$(printf '%s\n' "$created" | awk '/^Created task/{print $3}' | sed 's/:$//')
[ -f "$TEST_HOME/scheduler/tasks/$TASK_ID.json" ] || fail "task file missing"
[ "$(path_mode "$TEST_HOME/scheduler")" = "700" ] || fail "scheduler root is not mode 700"
[ "$(path_mode "$TEST_HOME/scheduler/tasks")" = "700" ] || fail "tasks directory is not mode 700"
[ "$(path_mode "$TEST_HOME/scheduler/prompts")" = "700" ] || fail "prompts directory is not mode 700"
[ "$(path_mode "$TEST_HOME/scheduler/tasks/$TASK_ID.json")" = "600" ] || fail "new task record is not mode 600"

run_sender bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$TASK_ID" "Do the smoke task"
[ "$(path_mode "$TEST_HOME/scheduler/prompts/$TASK_ID.md")" = "600" ] || fail "assignment prompt is not mode 600"
ASSIGN_CAPTURE=$(tmux capture-pane -J -t "$RECIPIENT" -p -S -200)
ASSIGN_MESSAGE_FILE=$(printf '%s\n' "$ASSIGN_CAPTURE" | grep -o 'msg:[^ ]*' | tail -1 | sed 's/^msg://')
[ -n "$ASSIGN_MESSAGE_FILE" ] && [ -f "$ASSIGN_MESSAGE_FILE" ] || fail "assignment dispatch notification did not reach recipient"
grep "$TASK_ID" "$ASSIGN_MESSAGE_FILE" >/dev/null || fail "assignment dispatch body omitted the task id"
EXPECTED_SCHEDULER_HOME=$(cd "$TEST_HOME/scheduler" && pwd -P)
EXPECTED_SCHEDULER_EXPORT=$(printf '%q' "$EXPECTED_SCHEDULER_HOME")
grep -F "export SESSION_SCHEDULER_HOME=$EXPECTED_SCHEDULER_EXPORT" "$ASSIGN_MESSAGE_FILE" >/dev/null \
  || fail "assignment packet missing exact shared scheduler export"
grep -F '$session-scheduler:task-done' "$ASSIGN_MESSAGE_FILE" >/dev/null \
  || fail "assignment packet missing Codex completion command"
grep -F '/session-scheduler:task-done' "$ASSIGN_MESSAGE_FILE" >/dev/null \
  || fail "assignment packet missing Claude completion command"
grep -F '$session-scheduler:task-block' "$ASSIGN_MESSAGE_FILE" >/dev/null \
  || fail "assignment packet missing Codex block command"
grep -F '/session-scheduler:task-block' "$ASSIGN_MESSAGE_FILE" >/dev/null \
  || fail "assignment packet missing Claude block command"
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
run_sender bash "$SCRIPT_DIR/tasks-clean.sh" --older-than 0s --status "done" --apply > "$TEST_HOME/clean-apply.txt"
grep 'Summary' "$TEST_HOME/clean-apply.txt" >/dev/null || fail "clean apply missing summary"

# --- tasks-clean must not trust stored absolute prompt_file paths ---
OUTSIDE_PROMPT="$TEST_HOME/outside-sensitive"
MALICIOUS_ID="clean-malicious"
LEGIT_ID="clean-legit"
printf 'do not delete\n' > "$OUTSIDE_PROMPT"
printf 'legit prompt\n' > "$TEST_HOME/scheduler/prompts/$LEGIT_ID.md"
jq -n \
  --arg id "$MALICIOUS_ID" \
  --arg prompt "$OUTSIDE_PROMPT" \
  '{id:$id,name:"Malicious clean task",status:"done",prompt_file:$prompt}' \
  > "$TEST_HOME/scheduler/tasks/$MALICIOUS_ID.json"
jq -n \
  --arg id "$LEGIT_ID" \
  --arg prompt "$TEST_HOME/scheduler/prompts/$LEGIT_ID.md" \
  '{id:$id,name:"Legit clean task",status:"done",prompt_file:$prompt}' \
  > "$TEST_HOME/scheduler/tasks/$LEGIT_ID.json"
run_sender bash "$SCRIPT_DIR/tasks-clean.sh" --older-than 0s --status "done" --apply > "$TEST_HOME/clean-traversal.txt"
[ -f "$OUTSIDE_PROMPT" ] || fail "tasks-clean deleted an outside prompt_file path"
[ ! -f "$TEST_HOME/scheduler/prompts/$LEGIT_ID.md" ] || fail "tasks-clean did not delete a legitimate prompt file"
[ ! -f "$TEST_HOME/scheduler/tasks/$MALICIOUS_ID.json" ] || fail "tasks-clean did not delete malicious task record"
[ ! -f "$TEST_HOME/scheduler/tasks/$LEGIT_ID.json" ] || fail "tasks-clean did not delete legit task record"

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
if grep -F '\t' "$TEST_HOME/bystage.txt" >/dev/null; then
  fail "by-stage emitted a literal backslash-t instead of a TSV field separator"
fi
awk -F '\t' -v id="$ETA_ID" '
  index($1, id) { found=1; if (NF == 8 && $7 ~ /OVERDUE/) valid=1 }
  END { if (!found || !valid) exit 1 }
' "$TEST_HOME/bystage.txt" || fail "by-stage row lost its flags column or TSV shape"

# --- --context attach + missing context rejected ---
mkdir -p "$TEST_HOME/contexts"
echo "# shared context for ProjectA" > "$TEST_HOME/contexts/ctx-1.md"
ctx=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Context task")
CTX_ID=$(printf '%s\n' "$ctx" | awk '/^Created task/{print $3}' | sed 's/:$//')
run_sender env SESSION_CONTEXT_HOME="$TEST_HOME/contexts" bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$CTX_ID" --context ctx-1 "Context work"
grep '## Context' "$TEST_HOME/scheduler/prompts/$CTX_ID.md" >/dev/null || fail "prompt missing context section"
EXPECTED_CONTEXT_HOME=$(cd "$TEST_HOME/contexts" && pwd -P)
EXPECTED_CONTEXT_EXPORT=$(printf '%q' "$EXPECTED_CONTEXT_HOME")
grep -F "export SESSION_CONTEXT_HOME=$EXPECTED_CONTEXT_EXPORT" "$TEST_HOME/scheduler/prompts/$CTX_ID.md" >/dev/null \
  || fail "context assignment packet missing exact shared context export"
grep -F '$session-context:context-load ctx-1' "$TEST_HOME/scheduler/prompts/$CTX_ID.md" >/dev/null \
  || fail "prompt missing Codex context-load form"
grep -F '/session-context:context-load ctx-1' "$TEST_HOME/scheduler/prompts/$CTX_ID.md" >/dev/null \
  || fail "prompt missing Claude context-load form"
meta_ctx=$(jq -r '.meta.context // empty' "$TEST_HOME/scheduler/tasks/$CTX_ID.json")
[ "$meta_ctx" = "ctx-1" ] || fail "meta.context not recorded"
if run_sender env SESSION_CONTEXT_HOME="$TEST_HOME/contexts" bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$CTX_ID" --context no-such-ctx "More work" 2> "$TEST_HOME/ctxmiss.txt"; then
  fail "assign with missing context was not refused"
fi
grep 'not found' "$TEST_HOME/ctxmiss.txt" >/dev/null || fail "missing-context error missing"

# --- workflow grouping + automatic context + independent reviewer routing ---
routed=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Routed workflow task" --reviewer scheduler-reviewer --workflow release-42)
ROUTED_ID=$(printf '%s\n' "$routed" | awk '/^Created task/{print $3}' | sed 's/:$//')
run_sender env SESSION_CONTEXT_HOME="$TEST_HOME/contexts" bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$ROUTED_ID" --context auto "Implement the routed change"
ROUTED_FILE="$TEST_HOME/scheduler/tasks/$ROUTED_ID.json"
[ "$(jq -r '.reviewer' "$ROUTED_FILE")" = "scheduler-reviewer" ] || fail "reviewer route not recorded"
[ "$(jq -r '.meta.workflow_id' "$ROUTED_FILE")" = "release-42" ] || fail "workflow id not recorded"
AUTO_CONTEXT=$(jq -r '.meta.context' "$ROUTED_FILE")
[ -f "$TEST_HOME/contexts/$AUTO_CONTEXT.md" ] || fail "automatic context snapshot missing"
AUTO_CONTEXT_MODE=$(stat -c '%a' "$TEST_HOME/contexts/$AUTO_CONTEXT.md" 2>/dev/null || stat -f '%Lp' "$TEST_HOME/contexts/$AUTO_CONTEXT.md" 2>/dev/null)
[ "$AUTO_CONTEXT_MODE" = "400" ] || fail "automatic context is not owner read-only: $AUTO_CONTEXT_MODE"
grep 'Shared Scheduler Home:' "$TEST_HOME/scheduler/prompts/$ROUTED_ID.md" >/dev/null || fail "assignment prompt missing shared scheduler home"
run_sender bash "$SCRIPT_DIR/task-status.sh" --by-workflow | grep 'Workflow: release-42' >/dev/null || fail "workflow grouping missing"
run_sender bash "$SCRIPT_DIR/task-status.sh" --workflow release-42 | grep "$ROUTED_ID" >/dev/null || fail "workflow filter missing routed task"
run_recipient bash "$SCRIPT_DIR/task-review.sh" "$ROUTED_ID" "commit feed123"
REVIEW_CAPTURE=$(tmux capture-pane -J -t "$REVIEWER" -p -S -200)
REVIEW_MESSAGE_FILE=$(printf '%s\n' "$REVIEW_CAPTURE" | grep -o 'msg:[^ ]*' | tail -1 | sed 's/^msg://')
[ -n "$REVIEW_MESSAGE_FILE" ] && [ -f "$REVIEW_MESSAGE_FILE" ] || fail "review dispatch notification did not reach reviewer"
grep "$ROUTED_ID" "$REVIEW_MESSAGE_FILE" >/dev/null || fail "review dispatch body omitted the task id"
jq -e '
  (.meta.review_dispatched_at // "") != ""
  and (.meta.review_dispatch_status == "delivered" or .meta.review_dispatch_status == "queued")
  and (.meta.review_dispatch_attempt_at // "") != ""
  and .meta.review_dispatch_attempts == 1
  and .meta.review_dispatch_error == null
  and (.review_dispatched_at | not)
' "$ROUTED_FILE" >/dev/null || fail "canonical review dispatch metadata missing or legacy alias retained"
ROUTED_REVIEW_PACKET="$TEST_HOME/scheduler/prompts/${ROUTED_ID}-review.md"
[ "$(path_mode "$ROUTED_REVIEW_PACKET")" = "600" ] || fail "review prompt is not mode 600"
awk '/^## Original assignment/{exit} {print}' "$ROUTED_REVIEW_PACKET" > "$TEST_HOME/routed-review-instructions.txt"
grep -F "export SESSION_SCHEDULER_HOME=$EXPECTED_SCHEDULER_EXPORT" "$TEST_HOME/routed-review-instructions.txt" >/dev/null \
  || fail "review packet missing exact shared scheduler export"
grep -F "export SESSION_CONTEXT_HOME=$EXPECTED_CONTEXT_EXPORT" "$TEST_HOME/routed-review-instructions.txt" >/dev/null \
  || fail "review packet missing exact shared context export"
grep -F '$session-scheduler:task-done' "$TEST_HOME/routed-review-instructions.txt" >/dev/null \
  || fail "review packet missing Codex approval command"
grep -F '/session-scheduler:task-done' "$TEST_HOME/routed-review-instructions.txt" >/dev/null \
  || fail "review packet missing Claude approval command"
grep -F '$session-scheduler:task-block' "$TEST_HOME/routed-review-instructions.txt" >/dev/null \
  || fail "review packet missing Codex rejection command"
grep -F '/session-scheduler:task-block' "$TEST_HOME/routed-review-instructions.txt" >/dev/null \
  || fail "review packet missing Claude rejection command"
grep -F "\$session-context:context-load $AUTO_CONTEXT" "$TEST_HOME/routed-review-instructions.txt" >/dev/null \
  || fail "review packet missing Codex context-load command"
grep -F "/session-context:context-load $AUTO_CONTEXT" "$TEST_HOME/routed-review-instructions.txt" >/dev/null \
  || fail "review packet missing Claude context-load command"
run_reviewer bash "$SCRIPT_DIR/task-done.sh" "$ROUTED_ID" "approved independently"
run_sender bash "$SCRIPT_DIR/task-status.sh" "$ROUTED_ID" | grep 'done' >/dev/null || fail "reviewer could not complete routed task"

# A legacy root-level success timestamp is authoritative only when the newer
# canonical key is absent. Codex migrates it under .meta and refuses a duplicate
# reviewer dispatch without adding another review history event.
legacy_review=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Legacy review metadata task" --reviewer scheduler-reviewer)
LEGACY_REVIEW_ID=$(printf '%s\n' "$legacy_review" | awk '/^Created task/{print $3}' | sed 's/:$//')
LEGACY_REVIEW_FILE="$TEST_HOME/scheduler/tasks/$LEGACY_REVIEW_ID.json"
run_sender bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$LEGACY_REVIEW_ID" "Legacy metadata assignment"
jq '
  .status="review"
  | .history += [{ts:"2026-01-01T00:00:00Z",event:"review",actor:"legacy-executor",note:"original legacy review"}]
  | .review_dispatched_at="2026-01-01T00:00:01Z"
  | .review_last_dispatch_attempt_at="2026-01-01T00:00:01Z"
  | .review_dispatch_attempts=1
  | del(.meta.review_prompt_file, .meta.review_dispatched_at,
        .meta.review_dispatch_status, .meta.review_dispatch_attempt_at,
        .meta.review_dispatch_attempts, .meta.review_dispatch_error)
' "$LEGACY_REVIEW_FILE" > "$TEST_HOME/legacy-review.tmp"
mv "$TEST_HOME/legacy-review.tmp" "$LEGACY_REVIEW_FILE"
run_recipient bash "$SCRIPT_DIR/task-review.sh" "$LEGACY_REVIEW_ID" "must not dispatch twice" \
  > "$TEST_HOME/legacy-review.out"
grep 'Not re-dispatching' "$TEST_HOME/legacy-review.out" >/dev/null \
  || fail "legacy success timestamp did not prevent duplicate review dispatch"
[ ! -f "$TEST_HOME/scheduler/prompts/${LEGACY_REVIEW_ID}-review.md" ] \
  || fail "legacy success metadata still caused a duplicate review packet"
jq -e '
  .meta.review_dispatched_at == "2026-01-01T00:00:01Z"
  and .meta.review_dispatch_attempt_at == "2026-01-01T00:00:01Z"
  and .meta.review_dispatch_attempts == 1
  and .meta.review_dispatch_status == "delivered"
  and ([.history[] | select(.event == "review")] | length) == 1
  and (.review_dispatched_at | not)
  and (.review_last_dispatch_attempt_at | not)
  and (.review_dispatch_attempts | not)
' "$LEGACY_REVIEW_FILE" >/dev/null || fail "legacy review metadata was not canonically migrated"

# A workflow is a complete arc: grouped output keeps done steps and omits tasks
# that were never assigned a workflow id.
run_sender bash "$SCRIPT_DIR/task-status.sh" --by-workflow > "$TEST_HOME/byworkflow.txt"
grep 'Workflow: release-42' "$TEST_HOME/byworkflow.txt" >/dev/null || fail "workflow group disappeared after its task completed"
grep "$ROUTED_ID" "$TEST_HOME/byworkflow.txt" | grep 'done' >/dev/null || fail "by-workflow omitted its completed task"
if grep 'Workflow: (none)' "$TEST_HOME/byworkflow.txt" >/dev/null; then
  fail "by-workflow included tasks without workflow ids"
fi

# Same-second reassignments must mint separate immutable automatic contexts.
# Freeze the old timestamp format so this deterministically catches the former
# second-precision filename collision.
FIXED_DATE_DIR="$TEST_HOME/fixed-date-bin"
REAL_DATE_BIN=$(command -v date)
mkdir -p "$FIXED_DATE_DIR"
cat > "$FIXED_DATE_DIR/date" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-u" ] && [ "\${2:-}" = "+%Y%m%dT%H%M%SZ" ]; then
  printf '%s\n' '20300101T000000Z'
else
  exec "$REAL_DATE_BIN" "\$@"
fi
EOF
chmod +x "$FIXED_DATE_DIR/date"
unique_ctx=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Same-second context task")
UNIQUE_CTX_ID=$(printf '%s\n' "$unique_ctx" | awk '/^Created task/{print $3}' | sed 's/:$//')
run_sender env PATH="$FIXED_DATE_DIR:$PATH" SESSION_CONTEXT_HOME="$TEST_HOME/contexts" \
  bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$UNIQUE_CTX_ID" --context auto "First immutable handoff"
FIRST_AUTO_CONTEXT=$(jq -r '.meta.context' "$TEST_HOME/scheduler/tasks/$UNIQUE_CTX_ID.json")
run_sender env PATH="$FIXED_DATE_DIR:$PATH" SESSION_CONTEXT_HOME="$TEST_HOME/contexts" \
  bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$UNIQUE_CTX_ID" --context auto "Second immutable handoff" \
  || fail "same-second auto-context reassignment collided"
SECOND_AUTO_CONTEXT=$(jq -r '.meta.context' "$TEST_HOME/scheduler/tasks/$UNIQUE_CTX_ID.json")
[ "$FIRST_AUTO_CONTEXT" != "$SECOND_AUTO_CONTEXT" ] || fail "same-second reassignment reused an auto-context filename"
[ -f "$TEST_HOME/contexts/$FIRST_AUTO_CONTEXT.md" ] || fail "first immutable auto context was not preserved"
[ -f "$TEST_HOME/contexts/$SECOND_AUTO_CONTEXT.md" ] || fail "second immutable auto context missing"
grep 'First immutable handoff' "$TEST_HOME/contexts/$FIRST_AUTO_CONTEXT.md" >/dev/null || fail "first auto context was overwritten"
grep 'Second immutable handoff' "$TEST_HOME/contexts/$SECOND_AUTO_CONTEXT.md" >/dev/null || fail "second auto context has stale assignment content"

# Review packets must never inline a ledger-supplied traversal path.
TRAVERSAL_SECRET='TRAVERSAL-SECRET-MUST-NOT-BE-DISPATCHED'
printf '%s\n' "$TRAVERSAL_SECRET" > "$TEST_HOME/scheduler/review-traversal-secret.md"
traversal_review=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Traversal review task" --reviewer scheduler-reviewer)
TRAVERSAL_REVIEW_ID=$(printf '%s\n' "$traversal_review" | awk '/^Created task/{print $3}' | sed 's/:$//')
run_sender bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$TRAVERSAL_REVIEW_ID" "Legitimate traversal-test assignment"
TRAVERSAL_REVIEW_FILE="$TEST_HOME/scheduler/tasks/$TRAVERSAL_REVIEW_ID.json"
jq --arg prompt "$TEST_HOME/scheduler/prompts/../review-traversal-secret.md" '.prompt_file=$prompt' \
  "$TRAVERSAL_REVIEW_FILE" > "$TEST_HOME/traversal-review.tmp"
mv "$TEST_HOME/traversal-review.tmp" "$TRAVERSAL_REVIEW_FILE"
run_recipient bash "$SCRIPT_DIR/task-review.sh" "$TRAVERSAL_REVIEW_ID" "audit traversal safety"
TRAVERSAL_PACKET="$TEST_HOME/scheduler/prompts/${TRAVERSAL_REVIEW_ID}-review.md"
if grep "$TRAVERSAL_SECRET" "$TRAVERSAL_PACKET" >/dev/null; then
  fail "review packet inlined a traversal prompt_file"
fi
grep 'failed safety checks' "$TRAVERSAL_PACKET" >/dev/null || fail "unsafe traversal prompt_file was not explicitly rejected"

# A nested prompt symlink makes the complete ledger tree unsafe. Reject it
# before task-review reads any task or prompt content, then recover normally
# once the owner restores a real file.
SYMLINK_SECRET='SYMLINK-SECRET-MUST-NOT-BE-DISPATCHED'
printf '%s\n' "$SYMLINK_SECRET" > "$TEST_HOME/review-symlink-secret.md"
symlink_review=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Symlink review task" --reviewer scheduler-reviewer)
SYMLINK_REVIEW_ID=$(printf '%s\n' "$symlink_review" | awk '/^Created task/{print $3}' | sed 's/:$//')
run_sender bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$SYMLINK_REVIEW_ID" "Legitimate symlink-test assignment"
SYMLINK_PROMPT="$TEST_HOME/scheduler/prompts/$SYMLINK_REVIEW_ID.md"
mv "$SYMLINK_PROMPT" "${SYMLINK_PROMPT}.saved"
ln -s "$TEST_HOME/review-symlink-secret.md" "$SYMLINK_PROMPT"
SYMLINK_PACKET="$TEST_HOME/scheduler/prompts/${SYMLINK_REVIEW_ID}-review.md"
if run_recipient bash "$SCRIPT_DIR/task-review.sh" "$SYMLINK_REVIEW_ID" "audit symlink safety" \
  > /dev/null 2> "$TEST_HOME/prompt-symlink.err"; then
  fail "task-review accepted a nested prompt symlink"
fi
grep 'scheduler tree containing a symlink' "$TEST_HOME/prompt-symlink.err" >/dev/null \
  || fail "nested prompt symlink rejection did not explain the unsafe tree"
if [ -f "$SYMLINK_PACKET" ] && grep "$SYMLINK_SECRET" "$SYMLINK_PACKET" >/dev/null; then
  fail "review packet followed a symlink prompt_file"
fi
rm -f "$SYMLINK_PROMPT"
mv "${SYMLINK_PROMPT}.saved" "$SYMLINK_PROMPT"
run_sender bash "$SCRIPT_DIR/task-status.sh" "$SYMLINK_REVIEW_ID" | grep 'assigned' >/dev/null \
  || fail "rejected prompt symlink changed task state"

# --- reject an installed session-chat below the declared minimum ---
LOW_CHAT="$TEST_HOME/low-chat"
mkdir -p "$LOW_CHAT/.codex-plugin" "$LOW_CHAT/scripts"
printf '{"name":"session-chat","version":"0.12.9"}\n' > "$LOW_CHAT/.codex-plugin/plugin.json"
low=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Old transport task")
LOW_ID=$(printf '%s\n' "$low" | awk '/^Created task/{print $3}' | sed 's/:$//')
if run_sender env SESSION_CHAT_ROOT_OVERRIDE="$LOW_CHAT" bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$LOW_ID" "Should fail" 2> "$TEST_HOME/low-chat.txt"; then
  fail "session-chat below minimum was accepted"
fi
grep 'session-chat >= 0.13.0 is required' "$TEST_HOME/low-chat.txt" >/dev/null || fail "minimum-version error missing"
run_sender bash "$SCRIPT_DIR/task-status.sh" "$LOW_ID" | grep 'created' >/dev/null || fail "old transport failure changed ledger"

# --- dispatch failure rolls back new prompt + leaves ledger untouched ---
FAIL_STUB="$TEST_HOME/failstub/scripts"
mkdir -p "$FAIL_STUB" "$TEST_HOME/failstub/.codex-plugin"
printf '{"name":"session-chat","version":"0.16.5"}\n' > "$TEST_HOME/failstub/.codex-plugin/plugin.json"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAIL_STUB/dispatch-to-session.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAIL_STUB/send-message.sh"
chmod +x "$FAIL_STUB"/*.sh

# Review-dispatch metadata is scoped to one assignment cycle. Exercise a
# successful review, rejection, and rework before failing the next review
# dispatch: the stale first-cycle success timestamp must not block a normal
# dispatch-only retry, and the retry must not add a third review transition.
retry_review=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Retry reviewer dispatch task" --reviewer scheduler-reviewer)
RETRY_REVIEW_ID=$(printf '%s\n' "$retry_review" | awk '/^Created task/{print $3}' | sed 's/:$//')
RETRY_REVIEW_FILE="$TEST_HOME/scheduler/tasks/$RETRY_REVIEW_ID.json"
run_sender bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$RETRY_REVIEW_ID" "First review cycle"
run_recipient bash "$SCRIPT_DIR/task-review.sh" "$RETRY_REVIEW_ID" "first-cycle review" >/dev/null
[ -n "$(jq -r '.meta.review_dispatched_at // empty' "$RETRY_REVIEW_FILE")" ] \
  || fail "first review cycle did not record dispatch success"
run_reviewer bash "$SCRIPT_DIR/task-block.sh" "$RETRY_REVIEW_ID" "changes requested" >/dev/null
run_sender bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$RETRY_REVIEW_ID" "Reworked task needing a retryable review"
jq -e '
  ([.meta | keys[] | select(startswith("review_"))] | length) == 0
  and ([keys[] | select(startswith("review_"))] | length) == 0
' "$RETRY_REVIEW_FILE" >/dev/null || fail "reassignment retained canonical or legacy review dispatch metadata"
run_recipient env SESSION_CHAT_ROOT_OVERRIDE="$TEST_HOME/failstub" \
  bash "$SCRIPT_DIR/task-review.sh" "$RETRY_REVIEW_ID" "original review note" >/dev/null
[ "$(jq -r '.status' "$RETRY_REVIEW_FILE")" = "review" ] || fail "failed reviewer dispatch did not leave task in review"
[ -z "$(jq -r '.meta.review_dispatched_at // empty' "$RETRY_REVIEW_FILE")" ] \
  || fail "failed reviewer dispatch recorded a success timestamp"
[ "$(jq '[.history[] | select(.event == "review")] | length' "$RETRY_REVIEW_FILE")" -eq 2 ] \
  || fail "second review cycle did not record exactly one new review event"
[ "$(jq -r '.meta.review_dispatch_attempts // 0' "$RETRY_REVIEW_FILE")" -eq 1 ] \
  || fail "failed reviewer dispatch attempt was not recorded"
jq -e '
  .meta.review_dispatch_status == "failed"
  and (.meta.review_dispatch_attempt_at // "") != ""
  and (.meta.review_dispatch_error | startswith("session-chat dispatch failed"))
  and ([keys[] | select(startswith("review_"))] | length) == 0
' "$RETRY_REVIEW_FILE" >/dev/null || fail "failed review dispatch metadata is not canonical"
run_recipient bash "$SCRIPT_DIR/task-review.sh" "$RETRY_REVIEW_ID" "transport restored" > "$TEST_HOME/retry-review.txt"
grep 'Retried review dispatch' "$TEST_HOME/retry-review.txt" >/dev/null \
  || fail "task-review did not report a dispatch-only retry"
[ "$(jq -r '.status' "$RETRY_REVIEW_FILE")" = "review" ] || fail "review retry changed task status"
[ "$(jq '[.history[] | select(.event == "review")] | length' "$RETRY_REVIEW_FILE")" -eq 2 ] \
  || fail "review retry created a duplicate review history event"
[ "$(jq -r '[.history[] | select(.event == "review")][-1].note' "$RETRY_REVIEW_FILE")" = "original review note" ] \
  || fail "review retry overwrote the original review note"
[ -n "$(jq -r '.meta.review_dispatched_at // empty' "$RETRY_REVIEW_FILE")" ] \
  || fail "successful review retry did not record its dispatch timestamp"
[ "$(jq -r '.meta.review_dispatch_attempts // 0' "$RETRY_REVIEW_FILE")" -eq 2 ] \
  || fail "review dispatch retry attempt count is wrong"
[ "$(jq -r '.meta.review_dispatch_error // empty' "$RETRY_REVIEW_FILE")" = "" ] \
  || fail "successful review retry did not clear dispatch error metadata"
jq -e '
  (.meta.review_dispatch_status == "delivered" or .meta.review_dispatch_status == "queued")
  and ([keys[] | select(startswith("review_"))] | length) == 0
' "$RETRY_REVIEW_FILE" >/dev/null || fail "successful review retry did not retain canonical status only"
RETRY_REVIEW_PACKET="$TEST_HOME/scheduler/prompts/${RETRY_REVIEW_ID}-review.md"
grep -F 'Review request: original review note' "$RETRY_REVIEW_PACKET" >/dev/null \
  || fail "review retry packet did not preserve the original review request"
grep -F 'Dispatch retry note: transport restored' "$RETRY_REVIEW_PACKET" >/dev/null \
  || fail "review retry packet omitted the retry note"

rb=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Rollback task")
RB_ID=$(printf '%s\n' "$rb" | awk '/^Created task/{print $3}' | sed 's/:$//')
if run_sender env SESSION_CHAT_ROOT_OVERRIDE="$TEST_HOME/failstub" bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$RB_ID" "Doomed work" 2>/dev/null; then
  fail "assign with failing dispatch did not fail"
fi
[ ! -f "$TEST_HOME/scheduler/prompts/$RB_ID.md" ] || fail "orphaned prompt file left after dispatch failure"
run_sender bash "$SCRIPT_DIR/task-status.sh" "$RB_ID" | grep 'created' >/dev/null || fail "ledger updated despite dispatch failure"

auto_rb=$(run_sender bash "$SCRIPT_DIR/task-new.sh" "Auto-context rollback task")
AUTO_RB_ID=$(printf '%s\n' "$auto_rb" | awk '/^Created task/{print $3}' | sed 's/:$//')
before_auto=$(find "$TEST_HOME/contexts" -maxdepth 1 -type f -name "*${AUTO_RB_ID}*" | wc -l | tr -d ' ')
if run_sender env SESSION_CONTEXT_HOME="$TEST_HOME/contexts" SESSION_CHAT_ROOT_OVERRIDE="$TEST_HOME/failstub" \
  bash "$SCRIPT_DIR/task-assign.sh" scheduler-executor "$AUTO_RB_ID" --context auto "Doomed handoff" 2>/dev/null; then
  fail "auto-context assignment with failing dispatch did not fail"
fi
after_auto=$(find "$TEST_HOME/contexts" -maxdepth 1 -type f -name "*${AUTO_RB_ID}*" | wc -l | tr -d ' ')
[ "$before_auto" = "$after_auto" ] || fail "failed dispatch left an automatic context snapshot"
run_sender bash "$SCRIPT_DIR/task-status.sh" "$AUTO_RB_ID" | grep 'created' >/dev/null || fail "auto-context rollback changed ledger"

# Every persisted ledger record and prompt/review packet remains owner-only,
# including files updated atomically or rewritten during rollback paths.
while IFS= read -r persisted; do
  [ "$(path_mode "$persisted")" = "600" ] || fail "scheduler data file is not mode 600: $persisted"
done < <(find "$TEST_HOME/scheduler/tasks" "$TEST_HOME/scheduler/prompts" -type f -print)

echo "session-scheduler smoke tests passed"
