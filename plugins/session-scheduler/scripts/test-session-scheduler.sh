#!/usr/bin/env bash
# test-session-scheduler.sh — smoke test for the ledger ops.
# Uses an isolated $CLAUDE_HOME so it doesn't touch the real ledger.
# Does NOT exercise session-chat dispatch (covered separately); stubs it.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP=$(mktemp -d -t session-scheduler-test-XXXXXX)
export SESSION_SCHEDULER_HOME="$TMP/scheduler"
mkdir -p "$SESSION_SCHEDULER_HOME"

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

echo "=== session-scheduler tests (SESSION_SCHEDULER_HOME=$SESSION_SCHEDULER_HOME) ==="

# --- Test 1: task-new ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "smoke-task-1" --meta foo=bar 2>&1)
ID=$(echo "$out" | awk '/Created task:/ {print $3}')
if [ -n "$ID" ] && [ -f "$SESSION_SCHEDULER_HOME/tasks/$ID.json" ]; then
  status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$ID.json")
  meta_foo=$(jq -r '.meta.foo' "$SESSION_SCHEDULER_HOME/tasks/$ID.json")
  if [ "$status" = "created" ] && [ "$meta_foo" = "bar" ]; then pass "task_new"
  else fail "task_new" "wrong status/meta: status=$status foo=$meta_foo"; fi
else
  fail "task_new" "no id parsed or file missing; out=$out"
fi

# --- Test 2: task-assign (with stubbed dispatch) ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" executor-pane "$ID" "do the thing" 2>&1)
status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$ID.json")
assignee=$(jq -r '.assignee' "$SESSION_SCHEDULER_HOME/tasks/$ID.json")
if [ "$status" = "assigned" ] && [ "$assignee" = "executor-pane" ]; then
  pass "task_assign"
else
  fail "task_assign" "status=$status assignee=$assignee out=$out"
fi

# --- Test 3: task-status single id ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-status.sh" "$ID" 2>&1)
if echo "$out" | jq -e ".id == \"$ID\"" >/dev/null 2>&1; then pass "task_status_single"
else fail "task_status_single" "json check failed: $out"; fi

# --- Test 4: task-status active filter ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-status.sh" 2>&1)
if echo "$out" | grep -qF "$ID"; then pass "task_status_active"
else fail "task_status_active" "id not in active view: $out"; fi

# --- Test 5: task-done updates ledger + tries to ack ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-done.sh" "$ID" "all done" 2>&1)
status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$ID.json")
hist_last=$(jq -r '.history[-1].event' "$SESSION_SCHEDULER_HOME/tasks/$ID.json")
if [ "$status" = "done" ] && [ "$hist_last" = "done" ]; then pass "task_done"
else fail "task_done" "status=$status hist=$hist_last out=$out"; fi

# --- Test 6: task-block on a fresh task ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "smoke-task-2" 2>&1)
ID2=$(echo "$out" | awk '/Created task:/ {print $3}')
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-block.sh" "$ID2" "waiting on upstream" 2>&1)
status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$ID2.json")
if [ "$status" = "blocked" ]; then pass "task_block"
else fail "task_block" "status=$status out=$out"; fi

# --- Test 7: tasks-clean dry-run finds done task with --older-than 0 ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/tasks-clean.sh" --older-than 0 --status done 2>&1)
if echo "$out" | grep -q "DRY-RUN" && echo "$out" | grep -qF "$ID"; then pass "tasks_clean_dry_run"
else fail "tasks_clean_dry_run" "no dry-run match; out=$out"; fi

# --- Test 8: tasks-clean --apply actually deletes ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/tasks-clean.sh" --older-than 0 --status done --apply 2>&1)
if [ ! -f "$SESSION_SCHEDULER_HOME/tasks/$ID.json" ]; then pass "tasks_clean_apply"
else fail "tasks_clean_apply" "file still present; out=$out"; fi

# --- Test 9: scheduler-doctor runs without error ---
if SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/scheduler-doctor.sh" >/dev/null 2>&1; then
  pass "scheduler_doctor"
else
  fail "scheduler_doctor" "doctor exited non-zero"
fi

# --- Test 10: invalid task id rejected ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-status.sh" "bad/id" 2>&1 || true)
if echo "$out" | grep -q "invalid task id"; then
  pass "invalid_id_rejected"
else
  fail "invalid_id_rejected" "did not reject bad id; out=$out"
fi

# --- Test 11: illegal transition rejected (created -> done) ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "smoke-task-3" 2>&1)
ID3=$(echo "$out" | awk '/Created task:/ {print $3}')
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-done.sh" "$ID3" "premature" 2>&1)
rc=$?
status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$ID3.json")
if [ "$rc" -ne 0 ] && [ "$status" = "created" ] && echo "$out" | grep -q "illegal status transition"; then
  pass "illegal_transition_rejected"
else
  fail "illegal_transition_rejected" "rc=$rc status=$status out=$out"
fi

# --- Test 12: forced transition records 'forced' in history note ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-done.sh" "$ID3" --force "override" 2>&1)
status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$ID3.json")
hist_note=$(jq -r '.history[-1].note' "$SESSION_SCHEDULER_HOME/tasks/$ID3.json")
if [ "$status" = "done" ] && echo "$hist_note" | grep -q "forced"; then
  pass "forced_transition"
else
  fail "forced_transition" "status=$status note=$hist_note out=$out"
fi

# --- Test 13: review flow (assign -> review -> done) + started_at/duration ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "smoke-task-review" 2>&1)
ID4=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$ID4" "do reviewable work" >/dev/null 2>&1
started=$(jq -r '.started_at // empty' "$SESSION_SCHEDULER_HOME/tasks/$ID4.json")
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-review.sh" "$ID4" "commit abc1234" 2>&1)
status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$ID4.json")
hist_event=$(jq -r '.history[-1].event' "$SESSION_SCHEDULER_HOME/tasks/$ID4.json")
if [ -n "$started" ] && [ "$status" = "review" ] && [ "$hist_event" = "review" ]; then
  out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-done.sh" "$ID4" "approved" 2>&1)
  status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$ID4.json")
  dur=$(jq -r '.duration_seconds // empty' "$SESSION_SCHEDULER_HOME/tasks/$ID4.json")
  if [ "$status" = "done" ] && [ -n "$dur" ] && [ "$dur" -ge 0 ] 2>/dev/null; then
    pass "review_flow"
  else
    fail "review_flow" "after done: status=$status duration=$dur out=$out"
  fi
else
  fail "review_flow" "started_at=$started status=$status event=$hist_event out=$out"
fi

# --- Test 14: review requires a note ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "smoke-task-review-2" 2>&1)
ID5=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$ID5" "work" >/dev/null 2>&1
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-review.sh" "$ID5" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "note required\|Usage"; then
  pass "review_note_required"
else
  fail "review_note_required" "rc=$rc out=$out"
fi

# --- Test 15: depends_on gating ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "dep-task" 2>&1)
DEP=$(echo "$out" | awk '/Created task:/ {print $3}')
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "gated-task" --depends-on "$DEP" 2>&1)
GATED=$(echo "$out" | awk '/Created task:/ {print $3}')
deps_stored=$(jq -r '.depends_on[0] // empty' "$SESSION_SCHEDULER_HOME/tasks/$GATED.json" 2>/dev/null)
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$GATED" "gated work" 2>&1)
rc=$?
status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$GATED.json")
if [ "$deps_stored" = "$DEP" ] && [ "$rc" -ne 0 ] && [ "$status" = "created" ] && echo "$out" | grep -q "unmet dependencies" && echo "$out" | grep -qF "$DEP"; then
  # complete the dependency, then the assign must succeed
  SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$DEP" "dep work" >/dev/null 2>&1
  SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-done.sh" "$DEP" "dep done" >/dev/null 2>&1
  out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$GATED" "gated work" 2>&1)
  status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$GATED.json")
  if [ "$status" = "assigned" ]; then
    pass "depends_on_gating"
  else
    fail "depends_on_gating" "post-dep-done assign failed: status=$status out=$out"
  fi
else
  fail "depends_on_gating" "deps=$deps_stored rc=$rc status=$status out=$out"
fi

# --- Test 16: --depends-on rejects nonexistent task id ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "bad-deps" --depends-on "no-such-task-id" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "does not exist"; then
  pass "depends_on_missing_rejected"
else
  fail "depends_on_missing_rejected" "rc=$rc out=$out"
fi

# --- Test 17: eta stored + OVERDUE flag ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "eta-task" --stage execute 2>&1)
ETA_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$ETA_ID" --eta 5 "timed work" >/dev/null 2>&1
eta_at=$(jq -r '.eta_at // empty' "$SESSION_SCHEDULER_HOME/tasks/$ETA_ID.json")
if [ -n "$eta_at" ]; then
  # Rewrite eta_at into the past, then the status view must flag OVERDUE.
  jq '.eta_at = "2020-01-01T00:00:00Z"' "$SESSION_SCHEDULER_HOME/tasks/$ETA_ID.json" > "$SESSION_SCHEDULER_HOME/tasks/$ETA_ID.json.tmp" \
    && mv "$SESSION_SCHEDULER_HOME/tasks/$ETA_ID.json.tmp" "$SESSION_SCHEDULER_HOME/tasks/$ETA_ID.json"
  out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-status.sh" 2>&1)
  if echo "$out" | grep -F "$ETA_ID" | grep -q "OVERDUE"; then
    pass "eta_overdue_flag"
  else
    fail "eta_overdue_flag" "no OVERDUE flag; out=$out"
  fi
else
  fail "eta_overdue_flag" "eta_at not stored"
fi

# --- Test 18: STALE flag for assigned task not updated recently ---
jq '.updated_at = "2020-01-01T00:00:00Z"' "$SESSION_SCHEDULER_HOME/tasks/$ETA_ID.json" > "$SESSION_SCHEDULER_HOME/tasks/$ETA_ID.json.tmp" \
  && mv "$SESSION_SCHEDULER_HOME/tasks/$ETA_ID.json.tmp" "$SESSION_SCHEDULER_HOME/tasks/$ETA_ID.json"
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_SCHEDULER_STALE_MINUTES=30 bash "$HERE/task-status.sh" 2>&1)
if echo "$out" | grep -F "$ETA_ID" | grep -q "STALE"; then
  pass "stale_flag"
else
  fail "stale_flag" "no STALE flag; out=$out"
fi

# --- Test 19: task-board renders groups + totals ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-board.sh" 2>&1)
if echo "$out" | grep -q "Stage: execute" \
  && echo "$out" | grep -q "Stage: (none)" \
  && echo "$out" | grep -qF "$ETA_ID" \
  && echo "$out" | grep -q "OVERDUE" \
  && echo "$out" | grep -qE '[0-9]+ active: .*assigned'; then
  pass "task_board_renders"
else
  fail "task_board_renders" "board output missing pieces; out=$out"
fi

# --- Test 20: task-status --by-stage groups output ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-status.sh" --by-stage 2>&1)
if echo "$out" | grep -q "Stage: execute" && echo "$out" | grep -qF "$ETA_ID"; then
  pass "task_status_by_stage"
else
  fail "task_status_by_stage" "by-stage output missing pieces; out=$out"
fi

# --- Test 21: --context attaches snapshot to prompt + meta ---
CTX_DIR="$TMP/contexts"
mkdir -p "$CTX_DIR"
echo "# shared context for ProjectA" > "$CTX_DIR/ctx-1.md"
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "ctx-task" 2>&1)
CTX_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CONTEXT_HOME="$CTX_DIR" bash "$HERE/task-assign.sh" worker-1 "$CTX_ID" --context ctx-1 "context work" 2>&1)
prompt_file="$SESSION_SCHEDULER_HOME/prompts/$CTX_ID.md"
meta_ctx=$(jq -r '.meta.context // empty' "$SESSION_SCHEDULER_HOME/tasks/$CTX_ID.json")
if grep -q "## Context" "$prompt_file" 2>/dev/null \
  && grep -q "context-load ctx-1" "$prompt_file" 2>/dev/null \
  && [ "$meta_ctx" = "ctx-1" ]; then
  pass "context_attach"
else
  fail "context_attach" "meta=$meta_ctx out=$out"
fi

# --- Test 22: --context with missing snapshot errors before any side effects ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CONTEXT_HOME="$CTX_DIR" bash "$HERE/task-assign.sh" worker-1 "$ID3" --force --context no-such-ctx "work" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "not found"; then
  pass "context_missing_rejected"
else
  fail "context_missing_rejected" "rc=$rc out=$out"
fi

# --- Test 23: dispatch failure rolls back a NEW prompt file + ledger untouched ---
FAIL_STUB="$TMP/session-chat-failstub/scripts"
mkdir -p "$FAIL_STUB"
cat > "$FAIL_STUB/dispatch-to-session.sh" <<'STUB'
#!/usr/bin/env bash
echo "stub dispatch failure" >&2
exit 1
STUB
cat > "$FAIL_STUB/send-message.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "$FAIL_STUB/get-my-name.sh" <<'STUB'
#!/usr/bin/env bash
echo "test-orchestrator"
STUB
chmod +x "$FAIL_STUB"/*.sh
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "rollback-task" 2>&1)
RB_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CHAT_ROOT_OVERRIDE="$TMP/session-chat-failstub" bash "$HERE/task-assign.sh" worker-1 "$RB_ID" "doomed work" 2>&1)
rc=$?
status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$RB_ID.json")
if [ "$rc" -ne 0 ] && [ "$status" = "created" ] && [ ! -f "$SESSION_SCHEDULER_HOME/prompts/$RB_ID.md" ]; then
  pass "dispatch_failure_new_prompt_removed"
else
  fail "dispatch_failure_new_prompt_removed" "rc=$rc status=$status prompt_exists=$([ -f "$SESSION_SCHEDULER_HOME/prompts/$RB_ID.md" ] && echo yes || echo no) out=$out"
fi

# --- Test 24: dispatch failure restores a PRE-EXISTING prompt file ---
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$RB_ID" "original prompt body" >/dev/null 2>&1
orig_prompt=$(cat "$SESSION_SCHEDULER_HOME/prompts/$RB_ID.md")
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CHAT_ROOT_OVERRIDE="$TMP/session-chat-failstub" bash "$HERE/task-assign.sh" worker-2 "$RB_ID" "replacement prompt body" 2>&1)
rc=$?
restored_prompt=$(cat "$SESSION_SCHEDULER_HOME/prompts/$RB_ID.md" 2>/dev/null)
assignee=$(jq -r '.assignee' "$SESSION_SCHEDULER_HOME/tasks/$RB_ID.json")
if [ "$rc" -ne 0 ] && [ "$restored_prompt" = "$orig_prompt" ] && [ "$assignee" = "worker-1" ]; then
  pass "dispatch_failure_prompt_restored"
else
  fail "dispatch_failure_prompt_restored" "rc=$rc assignee=$assignee restored_matches=$([ "$restored_prompt" = "$orig_prompt" ] && echo yes || echo no) out=$out"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
