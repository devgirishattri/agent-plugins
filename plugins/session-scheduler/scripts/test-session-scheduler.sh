#!/usr/bin/env bash
# test-session-scheduler.sh — smoke test for the ledger ops.
# Uses an isolated $CLAUDE_HOME so it doesn't touch the real ledger.
# Does NOT exercise session-chat dispatch (covered separately); stubs it.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP=$(mktemp -d -t session-scheduler-test-XXXXXX)
export CLAUDE_HOME="$TMP/home"
mkdir -p "$CLAUDE_HOME"

PASS=0; FAIL=0; FAILURES=()
pass() { PASS=$((PASS+1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL+1)); FAILURES+=("$1: $2"); echo "  FAIL  $1 — $2"; }

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Stub session-chat dispatch + send so tests don't need tmux.
STUB_DIR="$TMP/session-chat-stub/scripts"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/dispatch-to-session.sh" <<'STUB'
#!/usr/bin/env bash
echo "stub-dispatched to $1 with $2"
exit 0
STUB
cat > "$STUB_DIR/send-message.sh" <<'STUB'
#!/usr/bin/env bash
echo "stub-sent to $1: $2"
exit 0
STUB
cat > "$STUB_DIR/get-my-name.sh" <<'STUB'
#!/usr/bin/env bash
echo "test-orchestrator"
STUB
chmod +x "$STUB_DIR"/*.sh

export SESSION_CHAT_ROOT_OVERRIDE="$TMP/session-chat-stub"

echo "=== session-scheduler tests (CLAUDE_HOME=$CLAUDE_HOME) ==="

# --- Test 1: task-new ---
out=$(CLAUDE_HOME="$CLAUDE_HOME" bash "$HERE/task-new.sh" "smoke-task-1" --meta foo=bar 2>&1)
ID=$(echo "$out" | awk '/Created task:/ {print $3}')
if [ -n "$ID" ] && [ -f "$CLAUDE_HOME/scheduler/tasks/$ID.json" ]; then
  status=$(jq -r '.status' "$CLAUDE_HOME/scheduler/tasks/$ID.json")
  meta_foo=$(jq -r '.meta.foo' "$CLAUDE_HOME/scheduler/tasks/$ID.json")
  if [ "$status" = "created" ] && [ "$meta_foo" = "bar" ]; then pass "task_new"
  else fail "task_new" "wrong status/meta: status=$status foo=$meta_foo"; fi
else
  fail "task_new" "no id parsed or file missing; out=$out"
fi

# --- Test 2: task-assign (with stubbed dispatch) ---
out=$(CLAUDE_HOME="$CLAUDE_HOME" bash "$HERE/task-assign.sh" executor-pane "$ID" "do the thing" 2>&1)
status=$(jq -r '.status' "$CLAUDE_HOME/scheduler/tasks/$ID.json")
assignee=$(jq -r '.assignee' "$CLAUDE_HOME/scheduler/tasks/$ID.json")
if [ "$status" = "assigned" ] && [ "$assignee" = "executor-pane" ]; then
  pass "task_assign"
else
  fail "task_assign" "status=$status assignee=$assignee out=$out"
fi

# --- Test 3: task-status single id ---
out=$(CLAUDE_HOME="$CLAUDE_HOME" bash "$HERE/task-status.sh" "$ID" 2>&1)
if echo "$out" | jq -e ".id == \"$ID\"" >/dev/null 2>&1; then pass "task_status_single"
else fail "task_status_single" "json check failed: $out"; fi

# --- Test 4: task-status active filter ---
out=$(CLAUDE_HOME="$CLAUDE_HOME" bash "$HERE/task-status.sh" 2>&1)
if echo "$out" | grep -qF "$ID"; then pass "task_status_active"
else fail "task_status_active" "id not in active view: $out"; fi

# --- Test 5: task-done updates ledger + tries to ack ---
out=$(CLAUDE_HOME="$CLAUDE_HOME" bash "$HERE/task-done.sh" "$ID" "all done" 2>&1)
status=$(jq -r '.status' "$CLAUDE_HOME/scheduler/tasks/$ID.json")
hist_last=$(jq -r '.history[-1].event' "$CLAUDE_HOME/scheduler/tasks/$ID.json")
if [ "$status" = "done" ] && [ "$hist_last" = "done" ]; then pass "task_done"
else fail "task_done" "status=$status hist=$hist_last out=$out"; fi

# --- Test 6: task-block on a fresh task ---
out=$(CLAUDE_HOME="$CLAUDE_HOME" bash "$HERE/task-new.sh" "smoke-task-2" 2>&1)
ID2=$(echo "$out" | awk '/Created task:/ {print $3}')
out=$(CLAUDE_HOME="$CLAUDE_HOME" bash "$HERE/task-block.sh" "$ID2" "waiting on upstream" 2>&1)
status=$(jq -r '.status' "$CLAUDE_HOME/scheduler/tasks/$ID2.json")
if [ "$status" = "blocked" ]; then pass "task_block"
else fail "task_block" "status=$status out=$out"; fi

# --- Test 7: tasks-clean dry-run finds done task with --older-than 0 ---
out=$(CLAUDE_HOME="$CLAUDE_HOME" bash "$HERE/tasks-clean.sh" --older-than 0 --status done 2>&1)
if echo "$out" | grep -q "DRY-RUN" && echo "$out" | grep -qF "$ID"; then pass "tasks_clean_dry_run"
else fail "tasks_clean_dry_run" "no dry-run match; out=$out"; fi

# --- Test 8: tasks-clean --apply actually deletes ---
out=$(CLAUDE_HOME="$CLAUDE_HOME" bash "$HERE/tasks-clean.sh" --older-than 0 --status done --apply 2>&1)
if [ ! -f "$CLAUDE_HOME/scheduler/tasks/$ID.json" ]; then pass "tasks_clean_apply"
else fail "tasks_clean_apply" "file still present; out=$out"; fi

# --- Test 9: scheduler-doctor runs without error ---
if CLAUDE_HOME="$CLAUDE_HOME" bash "$HERE/scheduler-doctor.sh" >/dev/null 2>&1; then
  pass "scheduler_doctor"
else
  fail "scheduler_doctor" "doctor exited non-zero"
fi

# --- Test 10: invalid task id rejected ---
out=$(CLAUDE_HOME="$CLAUDE_HOME" bash "$HERE/task-status.sh" "bad/id" 2>&1 || true)
if echo "$out" | grep -q "invalid task id"; then
  pass "invalid_id_rejected"
else
  fail "invalid_id_rejected" "did not reject bad id; out=$out"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
