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
chmod 644 "$STUB_DIR"/*.sh

# Version manifest so the stub satisfies the scheduler's session-chat floor
# check (exercises the version-pass path on every dispatch test below).
mkdir -p "$TMP/session-chat-stub/.claude-plugin"
printf '{ "name": "session-chat", "version": "0.17.0" }\n' > "$TMP/session-chat-stub/.claude-plugin/plugin.json"

export SESSION_CHAT_ROOT_OVERRIDE="$TMP/session-chat-stub"

# make_session_chat_stub <dir> <dispatch_rc> <send_rc> <actor_name> [send_sentinel_file]
# Builds a session-chat stub tree at <dir> (version manifest included, so it
# satisfies the floor check) for the lifecycle-ack delivery-ladder tests:
# dispatch-to-session.sh and send-message.sh exit with the given rcs, and
# get-my-name.sh reports <actor_name> (deliberately different from the
# assigner recorded at task-new time, so the ack is actually attempted rather
# than self-skipped). When a sentinel path is given, send-message.sh touches
# it on every invocation, so a test can assert the inline fallback never ran.
make_session_chat_stub() {
  local dir="$1" dispatch_rc="$2" send_rc="$3" actor="$4" sentinel="${5:-}"
  mkdir -p "$dir/scripts" "$dir/.claude-plugin"
  printf '{ "name": "session-chat", "version": "0.17.0" }\n' > "$dir/.claude-plugin/plugin.json"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "stub-dispatched to $1 with $2"' "exit $dispatch_rc" > "$dir/scripts/dispatch-to-session.sh"
  if [ -n "$sentinel" ]; then
    printf '%s\n' '#!/usr/bin/env bash' "touch \"$sentinel\"" 'echo "stub-sent to $1: $2"' "exit $send_rc" > "$dir/scripts/send-message.sh"
  else
    printf '%s\n' '#!/usr/bin/env bash' 'echo "stub-sent to $1: $2"' "exit $send_rc" > "$dir/scripts/send-message.sh"
  fi
  printf '%s\n' '#!/usr/bin/env bash' "echo \"$actor\"" > "$dir/scripts/get-my-name.sh"
  chmod 644 "$dir/scripts"/*.sh
}

echo "=== session-scheduler tests (SESSION_SCHEDULER_HOME=$SESSION_SCHEDULER_HOME) ==="

# Invalid IANA timezone names fail closed before touching the ledger.
if AGENT_PLUGINS_TIME_ZONE=Not/AZone SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" \
  bash "$HERE/task-new.sh" "invalid-timezone" > "$TMP/invalid-timezone.out" 2>&1; then
  fail "invalid_timezone_rejected" "task-new accepted Not/AZone"
elif grep -q "unknown IANA timezone" "$TMP/invalid-timezone.out"; then
  pass "invalid_timezone_rejected"
else
  fail "invalid_timezone_rejected" "unexpected output: $(cat "$TMP/invalid-timezone.out")"
fi

# --- Test 1: task-new ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "smoke-task-1" --meta foo=bar 2>&1)
ID=$(echo "$out" | awk '/Created task:/ {print $3}')
if [ -n "$ID" ] && [ -f "$SESSION_SCHEDULER_HOME/tasks/$ID.json" ]; then
  status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$ID.json")
  meta_foo=$(jq -r '.meta.foo' "$SESSION_SCHEDULER_HOME/tasks/$ID.json")
  created_at=$(jq -r '.created_at' "$SESSION_SCHEDULER_HOME/tasks/$ID.json")
  if [ "$status" = "created" ] && [ "$meta_foo" = "bar" ]; then pass "task_new"
  else fail "task_new" "wrong status/meta: status=$status foo=$meta_foo"; fi
  expected_offset=$(TZ="${AGENT_PLUGINS_TIME_ZONE:-Asia/Kolkata}" date +%z)
  expected_offset="${expected_offset:0:3}:${expected_offset:3:2}"
  if [[ "$created_at" == *"$expected_offset" ]]; then pass "task_new_timezone"
  else fail "task_new_timezone" "created_at=$created_at expected_offset=$expected_offset"; fi
else
  fail "task_new" "no id parsed or file missing; out=$out"
fi

# Fresh offset-bearing timestamps must never be treated as ancient by cleanup.
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/tasks-clean.sh" --older-than 30 2>&1)
if [ -f "$SESSION_SCHEDULER_HOME/tasks/$ID.json" ] && echo "$out" | grep -q "Nothing to clean"; then
  pass "tasks_clean_preserves_fresh_offset_timestamp"
else
  fail "tasks_clean_preserves_fresh_offset_timestamp" "fresh task was selected; out=$out"
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

# --- Test 5: task-done updates ledger + durably acks the assigner via dispatch (happy path) ---
# Stub identity differs from the assigner so the ack is actually attempted.
DONE_ACK_STUB="$TMP/session-chat-doneack"
DONE_ACK_SEND_SENTINEL="$TMP/done-ack-send-called"
make_session_chat_stub "$DONE_ACK_STUB" 0 0 "worker-actor" "$DONE_ACK_SEND_SENTINEL"
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CHAT_ROOT_OVERRIDE="$DONE_ACK_STUB" bash "$HERE/task-done.sh" "$ID" "all done" 2>&1)
status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$ID.json")
hist_last=$(jq -r '.history[-1].event' "$SESSION_SCHEDULER_HOME/tasks/$ID.json")
ack_status=$(jq -r '.meta.last_ack.status // empty' "$SESSION_SCHEDULER_HOME/tasks/$ID.json")
ack_event=$(jq -r '.meta.last_ack.event // empty' "$SESSION_SCHEDULER_HOME/tasks/$ID.json")
ack_target=$(jq -r '.meta.last_ack.target // empty' "$SESSION_SCHEDULER_HOME/tasks/$ID.json")
ack_file=$(jq -r '.meta.last_ack.file // empty' "$SESSION_SCHEDULER_HOME/tasks/$ID.json")
expected_ack_file="$SESSION_SCHEDULER_HOME/prompts/$ID-ack-done.md"
if [ "$status" = "done" ] && [ "$hist_last" = "done" ] \
   && [ "$ack_status" = "dispatched" ] && [ "$ack_event" = "done" ] && [ "$ack_target" = "test-orchestrator" ] \
   && [ "$ack_file" = "$expected_ack_file" ] && [ -f "$expected_ack_file" ] \
   && grep -qF "task $ID (smoke-task-1) done by worker-actor — all done" "$expected_ack_file" \
   && grep -qF "Claude: /session-scheduler:task-status $ID" "$expected_ack_file" \
   && grep -qF "Codex:  \$session-scheduler:task-status $ID" "$expected_ack_file" \
   && [ ! -f "$DONE_ACK_SEND_SENTINEL" ]; then
  pass "task_done"
else
  fail "task_done" "status=$status hist=$hist_last ack_status=$ack_status ack_file=$ack_file out=$out"
fi

# --- Test 6: task-block on a fresh task + durably acks the assigner via dispatch (blocked event) ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "smoke-task-2" 2>&1)
ID2=$(echo "$out" | awk '/Created task:/ {print $3}')
BLOCK_ACK_STUB="$TMP/session-chat-blockack"
BLOCK_ACK_SEND_SENTINEL="$TMP/block-ack-send-called"
make_session_chat_stub "$BLOCK_ACK_STUB" 0 0 "worker-actor" "$BLOCK_ACK_SEND_SENTINEL"
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CHAT_ROOT_OVERRIDE="$BLOCK_ACK_STUB" bash "$HERE/task-block.sh" "$ID2" "waiting on upstream" 2>&1)
status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$ID2.json")
ack_status=$(jq -r '.meta.last_ack.status // empty' "$SESSION_SCHEDULER_HOME/tasks/$ID2.json")
ack_event=$(jq -r '.meta.last_ack.event // empty' "$SESSION_SCHEDULER_HOME/tasks/$ID2.json")
ack_file=$(jq -r '.meta.last_ack.file // empty' "$SESSION_SCHEDULER_HOME/tasks/$ID2.json")
expected_ack_file="$SESSION_SCHEDULER_HOME/prompts/$ID2-ack-blocked.md"
if [ "$status" = "blocked" ] && [ "$ack_status" = "dispatched" ] && [ "$ack_event" = "blocked" ] \
   && [ "$ack_file" = "$expected_ack_file" ] && [ -f "$expected_ack_file" ] \
   && grep -qF "task $ID2 (smoke-task-2) BLOCKED by worker-actor: waiting on upstream" "$expected_ack_file" \
   && [ ! -f "$BLOCK_ACK_SEND_SENTINEL" ]; then
  pass "task_block"
else
  fail "task_block" "status=$status ack_status=$ack_status ack_file=$ack_file out=$out"
fi

# --- Test 6b: durable dispatch fails, inline send succeeds — ack status inline-fallback + single WARN ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "inline-fallback-task" 2>&1)
IF_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$IF_ID" "inline fallback work" >/dev/null 2>&1
INLINE_STUB="$TMP/session-chat-inlineack"
make_session_chat_stub "$INLINE_STUB" 1 0 "worker-actor"
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CHAT_ROOT_OVERRIDE="$INLINE_STUB" bash "$HERE/task-done.sh" "$IF_ID" "finished" 2>&1)
rc=$?
status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$IF_ID.json")
ack_status=$(jq -r '.meta.last_ack.status // empty' "$SESSION_SCHEDULER_HOME/tasks/$IF_ID.json")
ack_file=$(jq -r '.meta.last_ack.file // empty' "$SESSION_SCHEDULER_HOME/tasks/$IF_ID.json")
expected_ack_file="$SESSION_SCHEDULER_HOME/prompts/$IF_ID-ack-done.md"
warn_count=$(echo "$out" | grep -cF "WARN: durable ack dispatch to 'test-orchestrator' failed; ack delivered inline instead.")
if [ "$rc" -eq 0 ] && [ "$status" = "done" ] && [ "$ack_status" = "inline-fallback" ] \
   && [ "$ack_file" = "$expected_ack_file" ] && [ -f "$expected_ack_file" ] \
   && [ "$warn_count" = "1" ] \
   && ! echo "$out" | grep -qF "partial success"; then
  pass "ack_inline_fallback"
else
  fail "ack_inline_fallback" "rc=$rc status=$status ack_status=$ack_status warn_count=$warn_count out=$out"
fi

# --- Test 7: tasks-clean dry-run finds done task with --older-than 0 ---
jq '.updated_at = "2020-01-01T00:00:00Z"' "$SESSION_SCHEDULER_HOME/tasks/$ID.json" > "$SESSION_SCHEDULER_HOME/tasks/$ID.json.tmp" \
  && mv "$SESSION_SCHEDULER_HOME/tasks/$ID.json.tmp" "$SESSION_SCHEDULER_HOME/tasks/$ID.json"
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/tasks-clean.sh" --older-than 0 --status "done" 2>&1)
if echo "$out" | grep -q "DRY-RUN" && echo "$out" | grep -qF "$ID"; then pass "tasks_clean_dry_run"
else fail "tasks_clean_dry_run" "no dry-run match; out=$out"; fi

# --- Test 8: tasks-clean --apply actually deletes ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/tasks-clean.sh" --older-than 0 --status "done" --apply 2>&1)
if [ ! -f "$SESSION_SCHEDULER_HOME/tasks/$ID.json" ]; then pass "tasks_clean_apply"
else fail "tasks_clean_apply" "file still present; out=$out"; fi

# --- Test 9: scheduler-doctor runs clean + accepts 0644 (readable) dispatch script ---
# The stub scripts are mode 0644 (packaged mode), invoked via bash; the doctor
# must report the dispatch script OK via the -f/-r contract, not warn about it.
doc_out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/scheduler-doctor.sh" 2>&1)
doc_rc=$?
if [ "$doc_rc" -eq 0 ] && echo "$doc_out" | grep -q "dispatch script: OK" \
   && ! echo "$doc_out" | grep -qE "dispatch script.*(missing|not readable|not executable)"; then
  pass "scheduler_doctor"
else
  fail "scheduler_doctor" "rc=$doc_rc out=$doc_out"
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

# --- Test 17b: a blocked task with a past eta must NOT show OVERDUE ---
# OVERDUE marks work that is late while still actionable; a blocked task is at
# rest (waiting on an external unblock), so the flag is suppressed until it
# resumes. Regresses the "terminal blocked tasks marked overdue" report.
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "blocked-eta-task" 2>&1)
BLK_ETA_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$BLK_ETA_ID" --eta 5 "timed work" >/dev/null 2>&1
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-block.sh" "$BLK_ETA_ID" "waiting on upstream" >/dev/null 2>&1
jq '.eta_at = "2020-01-01T00:00:00Z"' "$SESSION_SCHEDULER_HOME/tasks/$BLK_ETA_ID.json" > "$SESSION_SCHEDULER_HOME/tasks/$BLK_ETA_ID.json.tmp" \
  && mv "$SESSION_SCHEDULER_HOME/tasks/$BLK_ETA_ID.json.tmp" "$SESSION_SCHEDULER_HOME/tasks/$BLK_ETA_ID.json"
blk_status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$BLK_ETA_ID.json")
blk_row=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-status.sh" --all 2>&1 | grep -F "$BLK_ETA_ID")
if [ "$blk_status" = "blocked" ] && [ -n "$blk_row" ] && ! echo "$blk_row" | grep -q "OVERDUE"; then
  pass "blocked_suppresses_overdue"
else
  fail "blocked_suppresses_overdue" "status=$blk_status row=$blk_row"
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
echo "# shared context for ProjectA" > "$CTX_DIR/ctx_1.md"
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "ctx-task" 2>&1)
CTX_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CONTEXT_HOME="$CTX_DIR" bash "$HERE/task-assign.sh" worker-1 "$CTX_ID" --context ctx_1 "context work" 2>&1)
prompt_file="$SESSION_SCHEDULER_HOME/prompts/$CTX_ID.md"
meta_ctx=$(jq -r '.meta.context // empty' "$SESSION_SCHEDULER_HOME/tasks/$CTX_ID.json")
if grep -q "## Context" "$prompt_file" 2>/dev/null \
  && grep -q "context-load ctx_1" "$prompt_file" 2>/dev/null \
  && [ "$meta_ctx" = "ctx_1" ]; then
  pass "context_attach"
else
  fail "context_attach" "meta=$meta_ctx out=$out"
fi

# --- Test 22: --context with missing snapshot errors before any side effects ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CONTEXT_HOME="$CTX_DIR" bash "$HERE/task-assign.sh" worker-1 "$ID3" --force --context no_such_ctx "work" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "not found"; then
  pass "context_missing_rejected"
else
  fail "context_missing_rejected" "rc=$rc out=$out"
fi

# --- Test 22b: explicit --context names must be canonical snake_case ---
# The knowledge context store only accepts ^[a-z0-9]+(_[a-z0-9]+)*$, so a name
# it would refuse must be rejected here — before any side effect — rather than
# attached and handed to an executor that can never load it.
ctx_reject_ok=yes
ctx_reject_detail=""
for bad in ctx-1 Ctx_1 _ctx1 ctx1_ ctx__1; do
  out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CONTEXT_HOME="$CTX_DIR" bash "$HERE/task-assign.sh" worker-1 "$ID3" --force --context "$bad" "work" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] || ! echo "$out" | grep -q "canonical snake_case"; then
    ctx_reject_ok=no
    ctx_reject_detail="$ctx_reject_detail [$bad rc=$rc out=$out]"
  fi
done
# ... and rejection happens before the prompt file is (re)written or dispatched.
if [ "$ctx_reject_ok" = "yes" ] && [ ! -f "$SESSION_SCHEDULER_HOME/prompts/$ID3.md" ]; then
  pass "context_name_requires_snake_case"
else
  fail "context_name_requires_snake_case" "ok=$ctx_reject_ok$ctx_reject_detail"
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
chmod 644 "$FAIL_STUB"/*.sh
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

# --- Test 25: session-chat version floor is enforced on dispatch ---
LOW_STUB="$TMP/session-chat-lowstub"
mkdir -p "$LOW_STUB/scripts" "$LOW_STUB/.claude-plugin"
cp "$STUB_DIR"/*.sh "$LOW_STUB/scripts/"
printf '{ "name": "session-chat", "version": "0.11.0" }\n' > "$LOW_STUB/.claude-plugin/plugin.json"
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "lowver-task" 2>&1)
LV_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CHAT_ROOT_OVERRIDE="$LOW_STUB" bash "$HERE/task-assign.sh" worker-1 "$LV_ID" "work" 2>&1)
rc=$?
status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$LV_ID.json")
if [ "$rc" -ne 0 ] && [ "$status" = "created" ] && echo "$out" | grep -q "below the required"; then
  pass "version_floor_block"
else
  fail "version_floor_block" "rc=$rc status=$status out=$out"
fi

# --- Test 26: SKIP_VERSION_CHECK override lets a low version through ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CHAT_ROOT_OVERRIDE="$LOW_STUB" SESSION_SCHEDULER_SKIP_VERSION_CHECK=1 bash "$HERE/task-assign.sh" worker-1 "$LV_ID" "work" 2>&1)
status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$LV_ID.json")
if [ "$status" = "assigned" ]; then
  pass "version_floor_override"
else
  fail "version_floor_override" "status=$status out=$out"
fi

# --- Test 27: --reviewer records reviewer + task-review auto-dispatches ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "rev-routed" 2>&1)
RR_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$RR_ID" --reviewer auditor "reviewable work" >/dev/null 2>&1
reviewer=$(jq -r '.reviewer // empty' "$SESSION_SCHEDULER_HOME/tasks/$RR_ID.json")
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-review.sh" "$RR_ID" "commit cafe1234" 2>&1)
if [ "$reviewer" = "auditor" ] && echo "$out" | grep -q "routed to reviewer: auditor" \
   && [ -f "$SESSION_SCHEDULER_HOME/prompts/$RR_ID-review.md" ] \
   && grep -q "Review requested" "$SESSION_SCHEDULER_HOME/prompts/$RR_ID-review.md"; then
  pass "reviewer_routing"
else
  fail "reviewer_routing" "reviewer=$reviewer out=$out"
fi

# --- Test 28: workflow_id recorded + --workflow filter + --by-workflow group ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "wf-a" --workflow flow1 2>&1)
WA_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "wf-b" 2>&1)
WB_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$WB_ID" --workflow flow1 "work b" >/dev/null 2>&1
wa_wf=$(jq -r '.meta.workflow_id // empty' "$SESSION_SCHEDULER_HOME/tasks/$WA_ID.json")
filt=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-status.sh" --workflow flow1 2>&1)
grp=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-status.sh" --by-workflow 2>&1)
if [ "$wa_wf" = "flow1" ] \
   && echo "$filt" | grep -qF "$WA_ID" && echo "$filt" | grep -qF "$WB_ID" \
   && echo "$grp" | grep -q "Workflow: flow1"; then
  pass "workflow_grouping"
else
  fail "workflow_grouping" "wa_wf=$wa_wf filt=$filt grp=$grp"
fi

# --- Test 29: absolute ledger home is embedded in the dispatched prompt ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "abs-home" 2>&1)
AH_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$AH_ID" "portable work" >/dev/null 2>&1
ah_prompt="$SESSION_SCHEDULER_HOME/prompts/$AH_ID.md"
ah_home=$(jq -r '.meta.scheduler_home // empty' "$SESSION_SCHEDULER_HOME/tasks/$AH_ID.json")
abs_expected=$(cd "$SESSION_SCHEDULER_HOME" && pwd -P)
if grep -qF "Shared scheduler home (provenance): $abs_expected" "$ah_prompt" 2>/dev/null \
   && grep -q "inherited" "$ah_prompt" 2>/dev/null \
   && grep -q "relaunch" "$ah_prompt" 2>/dev/null \
   && ! grep -qE '^[[:space:]]*export SESSION_(SCHEDULER|CONTEXT)_HOME' "$ah_prompt" 2>/dev/null \
   && [ "$ah_home" = "$abs_expected" ]; then
  pass "abs_home_propagation"
else
  fail "abs_home_propagation" "home=$ah_home expected=$abs_expected prompt=$(cat "$ah_prompt" 2>/dev/null)"
fi

# --- Test 30: --context auto writes a scheduler-owned handoff (never the knowledge store) ---
# No SESSION_CONTEXT_HOME at all: auto must not need it. A decoy contexts dir
# proves nothing lands there even when one exists.
DECOY_CTX_DIR="$TMP/contexts-decoy"
mkdir -p "$DECOY_CTX_DIR"
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "auto-ctx" --stage execute 2>&1)
AC_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
out=$(env -u SESSION_CONTEXT_HOME SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$AC_ID" --context auto "auto handoff work" 2>&1)
ac_rc=$?
ho_file=$(jq -r '.meta.handoff_file // empty' "$SESSION_SCHEDULER_HOME/tasks/$AC_ID.json")
ho_home=$(jq -r '.meta.handoff_home // empty' "$SESSION_SCHEDULER_HOME/tasks/$AC_ID.json")
ho_ctx=$(jq -r '.meta.context // "absent"' "$SESSION_SCHEDULER_HOME/tasks/$AC_ID.json")
ho_expected_dir="$(cd "$SESSION_SCHEDULER_HOME/handoffs" && pwd -P)/$AC_ID"
ho_name_ok=$(basename "$ho_file" .md | grep -qE '^[0-9a-f]{32}$' && echo yes || echo no)
ho_perms=""
[ -f "$ho_file" ] && ho_perms=$(stat -c '%a' "$ho_file" 2>/dev/null || stat -f '%Lp' "$ho_file" 2>/dev/null)
decoy_count=$(find "$DECOY_CTX_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$ac_rc" = "0" ] && [ -f "$ho_file" ] && [ "$(dirname "$ho_file")" = "$ho_expected_dir" ] \
   && [ "$ho_home" = "$(dirname "$ho_expected_dir")" ] && [ "$ho_ctx" = "absent" ] \
   && [ "$ho_name_ok" = "yes" ] && [ "$ho_perms" = "600" ] && [ "$decoy_count" = "0" ] \
   && grep -q "^# Auto handoff — task $AC_ID" "$ho_file" && grep -q "auto handoff work" "$ho_file" \
   && grep -q "^- stage: execute" "$ho_file" && grep -q "^- status before assignment: created" "$ho_file" \
   && grep -q "Auto handoff (read it first): $ho_file" "$SESSION_SCHEDULER_HOME/prompts/$AC_ID.md" \
   && ! grep -q "context-load" "$SESSION_SCHEDULER_HOME/prompts/$AC_ID.md" \
   && echo "$out" | grep -q "handoff:  $ho_file"; then
  pass "context_auto_scheduler_owned"
else
  fail "context_auto_scheduler_owned" "rc=$ac_rc file=$ho_file home=$ho_home ctx=$ho_ctx name_ok=$ho_name_ok perms=$ho_perms decoy=$decoy_count out=$out"
fi

# --- Test 30a: rollback removes the handoff (and the per-task dir it created) ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "auto-ctx-rb" 2>&1)
AC_RB=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CHAT_ROOT_OVERRIDE="$TMP/session-chat-failstub" bash "$HERE/task-assign.sh" worker-1 "$AC_RB" --context auto "doomed" >/dev/null 2>&1
if [ ! -e "$SESSION_SCHEDULER_HOME/handoffs/$AC_RB" ] \
   && [ "$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$AC_RB.json")" = "created" ] \
   && [ "$(jq -r '.meta.handoff_file // "absent"' "$SESSION_SCHEDULER_HOME/tasks/$AC_RB.json")" = "absent" ]; then
  pass "context_auto_rollback_removes_handoff"
else
  fail "context_auto_rollback_removes_handoff" "$(ls -R "$SESSION_SCHEDULER_HOME/handoffs" 2>&1)"
fi

# --- Test 30b: reassignment mints a NEW handoff; the prior one is never overwritten ---
# A ledger shared with another provider can hold task ids carrying dates or
# hyphens; the nonce filename never derives from the id.
ODD_ID="Report-2026-08-11_1786421913"
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "odd-id-task" 2>&1)
SEED_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
jq --arg id "$ODD_ID" '.id = $id' "$SESSION_SCHEDULER_HOME/tasks/$SEED_ID.json" \
  > "$SESSION_SCHEDULER_HOME/tasks/$ODD_ID.json"
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$ODD_ID" --context auto "odd id work" >/dev/null 2>&1
odd_first=$(jq -r '.meta.handoff_file // empty' "$SESSION_SCHEDULER_HOME/tasks/$ODD_ID.json")
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-2 "$ODD_ID" --context auto "odd id work again" >/dev/null 2>&1
odd_second=$(jq -r '.meta.handoff_file // empty' "$SESSION_SCHEDULER_HOME/tasks/$ODD_ID.json")
odd_nonce_ok=$(basename "$odd_second" .md | grep -qiE 'report|1786421913|2026' && echo no || echo yes)
if [ -f "$odd_first" ] && [ -f "$odd_second" ] && [ "$odd_first" != "$odd_second" ] \
   && [ "$odd_nonce_ok" = "yes" ] && [ "$(dirname "$odd_first")" = "$(dirname "$odd_second")" ] \
   && grep -q "odd id work$" "$odd_first" && grep -q "odd id work again" "$odd_second" \
   && grep -q "^- id: $ODD_ID" "$odd_second" \
   && [ "$(ls "$SESSION_SCHEDULER_HOME/handoffs/$ODD_ID" | wc -l | tr -d ' ')" = "2" ]; then
  pass "context_auto_reassign_never_overwrites"
else
  fail "context_auto_reassign_never_overwrites" "first=$odd_first second=$odd_second nonce_ok=$odd_nonce_ok"
fi

# --- Test 30c: explicit --context NAME still needs the knowledge store and clears handoff keys ---
mkdir -p "$DECOY_CTX_DIR"; printf 'snapshot\n' > "$DECOY_CTX_DIR/real_ctx.md"
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CONTEXT_HOME="$DECOY_CTX_DIR" bash "$HERE/task-assign.sh" worker-3 "$ODD_ID" --context real_ctx "explicit ctx" >/dev/null 2>&1
if [ "$(jq -r '.meta.context // empty' "$SESSION_SCHEDULER_HOME/tasks/$ODD_ID.json")" = "real_ctx" ] \
   && [ "$(jq -r '.meta.handoff_file // "absent"' "$SESSION_SCHEDULER_HOME/tasks/$ODD_ID.json")" = "absent" ] \
   && grep -q "/knowledge:context-load real_ctx" "$SESSION_SCHEDULER_HOME/prompts/$ODD_ID.md"; then
  pass "context_explicit_clears_handoff_keys"
else
  fail "context_explicit_clears_handoff_keys" "$(jq -c .meta "$SESSION_SCHEDULER_HOME/tasks/$ODD_ID.json")"
fi

# --- Test 31: reviewer dispatch failure — NO /send downgrade, stays in review ---
# Stub whose dispatch fails (rc 1) and whose send writes a sentinel if ever
# called. task-review must NOT invoke the send fallback, must keep the task in
# review, must WARN, and must have written a review packet with the original.
REV_FAIL="$TMP/session-chat-revfail"
mkdir -p "$REV_FAIL/scripts" "$REV_FAIL/.claude-plugin"
printf '{ "name": "session-chat", "version": "0.17.0" }\n' > "$REV_FAIL/.claude-plugin/plugin.json"
SENTINEL="$TMP/send-fallback-called"
cat > "$REV_FAIL/scripts/dispatch-to-session.sh" <<'STUB'
#!/usr/bin/env bash
echo "revfail dispatch" >&2
exit 1
STUB
cat > "$REV_FAIL/scripts/send-message.sh" <<STUB
#!/usr/bin/env bash
touch "$SENTINEL"
exit 0
STUB
cat > "$REV_FAIL/scripts/get-my-name.sh" <<'STUB'
#!/usr/bin/env bash
echo "test-orchestrator"
STUB
chmod 644 "$REV_FAIL/scripts"/*.sh
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "rev-fail" 2>&1)
RVF_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$RVF_ID" --reviewer auditor "audit THIS-ORIGINAL-BODY" >/dev/null 2>&1
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CHAT_ROOT_OVERRIDE="$REV_FAIL" bash "$HERE/task-review.sh" "$RVF_ID" "commit beef5678" 2>&1)
rv_status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$RVF_ID.json")
rv_packet="$SESSION_SCHEDULER_HOME/prompts/$RVF_ID-review.md"
if [ "$rv_status" = "review" ] && [ ! -f "$SENTINEL" ] \
   && echo "$out" | grep -q "WARN" \
   && grep -q "Original assignment" "$rv_packet" 2>/dev/null \
   && grep -q "THIS-ORIGINAL-BODY" "$rv_packet" 2>/dev/null; then
  pass "reviewer_dispatch_fail_no_downgrade"
else
  fail "reviewer_dispatch_fail_no_downgrade" "status=$rv_status sentinel=$([ -f "$SENTINEL" ] && echo yes || echo no) out=$out"
fi

# --- Test 32: reviewer dispatch retry on an already-review task (no illegal xition) ---
# First review with the failing stub keeps the task in review + warns; re-running
# /task-review (retry) with a working stub re-dispatches WITHOUT attempting the
# illegal review->review transition.
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "rev-retry" 2>&1)
RTR_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$RTR_ID" --reviewer auditor "retry work" >/dev/null 2>&1
out1=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CHAT_ROOT_OVERRIDE="$REV_FAIL" bash "$HERE/task-review.sh" "$RTR_ID" "sha1" 2>&1)
st1=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$RTR_ID.json")
out2=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-review.sh" "$RTR_ID" "sha1" 2>&1)
st2=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$RTR_ID.json")
if [ "$st1" = "review" ] && [ "$st2" = "review" ] \
   && echo "$out1" | grep -q "WARN" \
   && echo "$out2" | grep -q "routed to reviewer: auditor" \
   && ! echo "$out2" | grep -q "illegal status transition"; then
  pass "reviewer_dispatch_retry"
else
  fail "reviewer_dispatch_retry" "st1=$st1 st2=$st2 out2=$out2"
fi

# --- Test 32b: task-review's assigner ack — durable dispatch happy path (review event) ---
# No --reviewer here, so this isolates the assigner-ack ladder from reviewer routing.
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "review-ack-ok" 2>&1)
RAO_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
REVIEW_ACK_OK="$TMP/session-chat-reviewackok"
REVIEW_ACK_OK_SEND_SENTINEL="$TMP/review-ack-ok-send-called"
make_session_chat_stub "$REVIEW_ACK_OK" 0 0 "worker-actor" "$REVIEW_ACK_OK_SEND_SENTINEL"
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CHAT_ROOT_OVERRIDE="$REVIEW_ACK_OK" bash "$HERE/task-assign.sh" worker-1 "$RAO_ID" "review ack work" >/dev/null 2>&1
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CHAT_ROOT_OVERRIDE="$REVIEW_ACK_OK" bash "$HERE/task-review.sh" "$RAO_ID" "commit reviewack1" 2>&1)
rao_status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$RAO_ID.json")
rao_ack_status=$(jq -r '.meta.last_ack.status // empty' "$SESSION_SCHEDULER_HOME/tasks/$RAO_ID.json")
rao_ack_event=$(jq -r '.meta.last_ack.event // empty' "$SESSION_SCHEDULER_HOME/tasks/$RAO_ID.json")
rao_ack_file=$(jq -r '.meta.last_ack.file // empty' "$SESSION_SCHEDULER_HOME/tasks/$RAO_ID.json")
expected_ack_file="$SESSION_SCHEDULER_HOME/prompts/$RAO_ID-ack-review.md"
if [ "$rao_status" = "review" ] && [ "$rao_ack_status" = "dispatched" ] && [ "$rao_ack_event" = "review" ] \
   && [ "$rao_ack_file" = "$expected_ack_file" ] && [ -f "$expected_ack_file" ] \
   && grep -qF "task $RAO_ID (review-ack-ok) ready for REVIEW by worker-actor: commit reviewack1" "$expected_ack_file" \
   && [ ! -f "$REVIEW_ACK_OK_SEND_SENTINEL" ]; then
  pass "review_ack_dispatched"
else
  fail "review_ack_dispatched" "status=$rao_status ack_status=$rao_ack_status ack_file=$rao_ack_file out=$out"
fi

# --- Test 32c: task-review's assigner ack fails entirely — WARNs but reviewer routing stays independent ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "review-ack-fail" 2>&1)
RAF_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
REVIEW_ACK_FAIL="$TMP/session-chat-reviewackfail"
make_session_chat_stub "$REVIEW_ACK_FAIL" 1 1 "worker-actor"
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$RAF_ID" --reviewer auditor "review ack fail work" >/dev/null 2>&1
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CHAT_ROOT_OVERRIDE="$REVIEW_ACK_FAIL" bash "$HERE/task-review.sh" "$RAF_ID" "commit reviewackfail1" 2>&1)
raf_status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$RAF_ID.json")
raf_ack_status=$(jq -r '.meta.last_ack.status // empty' "$SESSION_SCHEDULER_HOME/tasks/$RAF_ID.json")
raf_hist_count=$(jq -r '[.history[] | select(.event=="review")] | length' "$SESSION_SCHEDULER_HOME/tasks/$RAF_ID.json")
if [ "$raf_status" = "review" ] && [ "$raf_ack_status" = "failed" ] && [ "$raf_hist_count" = "1" ] \
   && echo "$out" | grep -qF "durable ack to assigner" \
   && echo "$out" | grep -qF "Reviewer routing proceeds independently" \
   && echo "$out" | grep -qF "stays in review" \
   && echo "$out" | grep -qF "reviewer dispatch to 'auditor' failed"; then
  pass "review_ack_failed_reviewer_routing_independent"
else
  fail "review_ack_failed_reviewer_routing_independent" "status=$raf_status ack_status=$raf_ack_status hist=$raf_hist_count out=$out"
fi

# --- Test 33: assignment + review packets list BOTH provider forms + provenance contract ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "mixed-prov" 2>&1)
MX_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$MX_ID" --reviewer auditor "mixed work" >/dev/null 2>&1
apf="$SESSION_SCHEDULER_HOME/prompts/$MX_ID.md"
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-review.sh" "$MX_ID" "sha-mixed" >/dev/null 2>&1
rpf="$SESSION_SCHEDULER_HOME/prompts/$MX_ID-review.md"
mx_abs=$(cd "$SESSION_SCHEDULER_HOME" && pwd -P)
if grep -qF "/session-scheduler:task-done $MX_ID" "$apf" && grep -qF "\$session-scheduler:task-done $MX_ID" "$apf" \
   && grep -qF "/session-scheduler:task-review $MX_ID" "$apf" && grep -qF "\$session-scheduler:task-review $MX_ID" "$apf" \
   && grep -qF "/session-scheduler:task-block $MX_ID" "$apf" && grep -qF "\$session-scheduler:task-block $MX_ID" "$apf" \
   && grep -qF "Shared scheduler home (provenance): $mx_abs" "$apf" \
   && grep -qF "/session-scheduler:task-done $MX_ID" "$rpf" && grep -qF "\$session-scheduler:task-done $MX_ID" "$rpf" \
   && grep -qF "/session-scheduler:task-block $MX_ID" "$rpf" && grep -qF "\$session-scheduler:task-block $MX_ID" "$rpf" \
   && grep -qF "Shared scheduler home (provenance): $mx_abs" "$rpf"; then
  pass "mixed_provider_packets"
else
  fail "mixed_provider_packets" "apf/rpf missing dual forms or provenance"
fi

# --- Test 33b: packets carry the inherited-env contract and NO executable env setup ---
env_setup_clean() {
  local f="$1"
  grep -q "inherited" "$f" \
    && grep -q "relaunch" "$f" \
    && ! grep -qE '^[[:space:]]*export SESSION_(SCHEDULER|CONTEXT)_HOME' "$f" \
    && ! grep -qE '(^|[[:space:]])env[[:space:]]+SESSION_(SCHEDULER|CONTEXT)_HOME=' "$f" \
    && ! grep -qE 'SESSION_(SCHEDULER|CONTEXT)_HOME=[^[:space:]]*[[:space:]]+bash([[:space:]]|$)' "$f"
}
if env_setup_clean "$apf" && env_setup_clean "$rpf"; then
  pass "packets_inherited_env_contract"
else
  fail "packets_inherited_env_contract" "apf or rpf missing contract or contains executable env setup"
fi

# --- Test 33c: agent-facing commands/skills carry no executable export/env-prefix instructions ---
doc_stale=""
for doc in "$HERE/../commands"/*.md "$HERE/../skills"/*/SKILL.md; do
  [ -f "$doc" ] || continue
  if grep -qE '^[[:space:]]*export SESSION_(SCHEDULER|CONTEXT)_HOME' "$doc" \
     || grep -qE '(^|[[:space:]])env[[:space:]]+SESSION_(SCHEDULER|CONTEXT)_HOME=' "$doc" \
     || grep -qE 'SESSION_(SCHEDULER|CONTEXT)_HOME=[^[:space:]]*[[:space:]]+bash([[:space:]]|$)' "$doc"; then
    doc_stale="$doc_stale $doc"
  fi
done
if [ -z "$doc_stale" ]; then
  pass "docs_no_executable_export"
else
  fail "docs_no_executable_export" "stale executable-export pattern in:$doc_stale"
fi

# --- Test 33d: assignment + review packets carry the nested-transport contract ---
if grep -qF "Transport contract:" "$apf" && grep -qF "on the first attempt" "$apf" \
   && grep -qF "never rerun task-done or task-block" "$apf" && grep -qF "use --force to repair" "$apf" \
   && grep -qF "never duplicate a delivered packet" "$apf" \
   && grep -qF "Transport contract:" "$rpf" && grep -qF "on the first attempt" "$rpf" \
   && grep -qF "never rerun task-done or task-block" "$rpf"; then
  pass "packets_transport_contract"
else
  fail "packets_transport_contract" "apf or rpf missing transport-contract guidance"
fi

# --- Test 33e: task-done with a totally failed ack (dispatch AND inline both fail) — transition intact + partial-success warning ---
# Stub identity differs from the assigner so the ack is actually attempted, and
# BOTH the durable dispatch and the inline send hard-fail to simulate a fully
# denied transport.
ACK_FAIL="$TMP/session-chat-ackfail"
make_session_chat_stub "$ACK_FAIL" 1 1 "worker-actor"
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "ack-fail-done" 2>&1)
AF_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$AF_ID" "ack-fail work" >/dev/null 2>&1
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CHAT_ROOT_OVERRIDE="$ACK_FAIL" bash "$HERE/task-done.sh" "$AF_ID" "finished" 2>&1)
rc=$?
af_status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$AF_ID.json")
af_ack_status=$(jq -r '.meta.last_ack.status // empty' "$SESSION_SCHEDULER_HOME/tasks/$AF_ID.json")
af_ack_file=$(jq -r '.meta.last_ack.file // empty' "$SESSION_SCHEDULER_HOME/tasks/$AF_ID.json")
if [ "$rc" -eq 0 ] && [ "$af_status" = "done" ] && [ "$af_ack_status" = "failed" ] \
   && [ -f "$af_ack_file" ] \
   && grep -qF "task $AF_ID (ack-fail-done) done by worker-actor — finished" "$af_ack_file" \
   && echo "$out" | grep -qF "partial success" \
   && echo "$out" | grep -qF "durable ack" \
   && echo "$out" | grep -qF "Do NOT rerun task-done" \
   && echo "$out" | grep -qF "use --force to repair"; then
  pass "task_done_partial_success_warning"
else
  fail "task_done_partial_success_warning" "rc=$rc status=$af_status ack_status=$af_ack_status ack_file=$af_ack_file out=$out"
fi

# --- Test 33f: task-block with a totally failed ack (dispatch AND inline both fail) — transition intact + partial-success warning ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "ack-fail-block" 2>&1)
AB_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CHAT_ROOT_OVERRIDE="$ACK_FAIL" bash "$HERE/task-block.sh" "$AB_ID" "upstream denied" 2>&1)
rc=$?
ab_status=$(jq -r '.status' "$SESSION_SCHEDULER_HOME/tasks/$AB_ID.json")
ab_ack_status=$(jq -r '.meta.last_ack.status // empty' "$SESSION_SCHEDULER_HOME/tasks/$AB_ID.json")
ab_ack_file=$(jq -r '.meta.last_ack.file // empty' "$SESSION_SCHEDULER_HOME/tasks/$AB_ID.json")
if [ "$rc" -eq 0 ] && [ "$ab_status" = "blocked" ] && [ "$ab_ack_status" = "failed" ] \
   && [ -f "$ab_ack_file" ] \
   && grep -qF "task $AB_ID (ack-fail-block) BLOCKED by worker-actor: upstream denied" "$ab_ack_file" \
   && echo "$out" | grep -qF "partial success" \
   && echo "$out" | grep -qF "durable ack" \
   && echo "$out" | grep -qF "Do NOT rerun task-block" \
   && echo "$out" | grep -qF "use --force to repair"; then
  pass "task_block_partial_success_warning"
else
  fail "task_block_partial_success_warning" "rc=$rc status=$ab_status ack_status=$ab_ack_status ack_file=$ab_ack_file out=$out"
fi

# --- Test 33g: agent-facing docs carry the first-attempt escalation + non-retry guidance ---
doc_missing=""
for n in task-assign task-review task-done task-block; do
  d="$HERE/../commands/$n.md"
  if ! grep -qF "on the first attempt" "$d" || ! grep -qF "one literal Bash segment" "$d"; then
    doc_missing="$doc_missing $n(escalation)"
  fi
done
for n in task-done task-block; do
  d="$HERE/../commands/$n.md"
  if ! grep -qF "never rerun" "$d" || ! grep -qF "use --force to repair" "$d"; then
    doc_missing="$doc_missing $n(partial-success)"
  fi
done
grep -qF "never duplicate" "$HERE/../commands/task-review.md" || doc_missing="$doc_missing task-review(duplicate)"
grep -qF "Transport contract" "$HERE/../skills/session-scheduler/SKILL.md" || doc_missing="$doc_missing umbrella(contract)"
if [ -z "$doc_missing" ]; then
  pass "docs_transport_escalation_guidance"
else
  fail "docs_transport_escalation_guidance" "missing:$doc_missing"
fi

# --- Test 34: ledger dirs are 0700 and task/prompt files 0600 (umask 077) ---
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "perm-task" 2>&1)
PM_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$PM_ID" "perm work" >/dev/null 2>&1
d_tasks=$(mode_of "$SESSION_SCHEDULER_HOME/tasks")
d_prompts=$(mode_of "$SESSION_SCHEDULER_HOME/prompts")
f_task=$(mode_of "$SESSION_SCHEDULER_HOME/tasks/$PM_ID.json")
f_prompt=$(mode_of "$SESSION_SCHEDULER_HOME/prompts/$PM_ID.md")
if [ "$d_tasks" = "700" ] && [ "$d_prompts" = "700" ] && [ "$f_task" = "600" ] && [ "$f_prompt" = "600" ]; then
  pass "ledger_perms_owner_only"
else
  fail "ledger_perms_owner_only" "tasks=$d_tasks prompts=$d_prompts task=$f_task prompt=$f_prompt"
fi

# --- Test 35: ensure_dirs migrates a legacy loose tree to 0700/0600 ---
mig_out=$(
  H="$TMP/safe-migrate"
  mkdir -p "$H/tasks" "$H/prompts"
  umask 022
  printf '{}' > "$H/tasks/legacy.json"
  chmod 644 "$H/tasks/legacy.json"; chmod 755 "$H" "$H/tasks" "$H/prompts"
  export SESSION_SCHEDULER_HOME="$H"
  source "$HERE/lib.sh"
  if ensure_dirs; then
    echo "RC0"
    echo "DIR=$(stat -c '%a' "$H/tasks" 2>/dev/null || stat -f '%Lp' "$H/tasks" 2>/dev/null)"
    echo "FILE=$(stat -c '%a' "$H/tasks/legacy.json" 2>/dev/null || stat -f '%Lp' "$H/tasks/legacy.json" 2>/dev/null)"
  fi
)
if echo "$mig_out" | grep -q RC0 && echo "$mig_out" | grep -q "DIR=700" && echo "$mig_out" | grep -q "FILE=600"; then
  pass "ensure_dirs_migrates_legacy"
else
  fail "ensure_dirs_migrates_legacy" "out=$mig_out"
fi

# --- Test 36: ensure_dirs rejects a symlinked root (fail closed via entrypoint) ---
REAL="$TMP/sr-real"; mkdir -p "$REAL"
LNK="$TMP/sr-link"; ln -s "$REAL" "$LNK"
out=$(SESSION_SCHEDULER_HOME="$LNK" bash "$HERE/task-new.sh" "x" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "symlink"; then
  pass "reject_symlink_root"
else
  fail "reject_symlink_root" "rc=$rc out=$out"
fi

# --- Test 37: ensure_dirs rejects a nested symlink under tasks/ ---
NST="$TMP/nested-task"; mkdir -p "$NST/tasks" "$NST/prompts"
ln -s /etc/hosts "$NST/tasks/evil.json"
out=$(SESSION_SCHEDULER_HOME="$NST" bash "$HERE/task-status.sh" --all 2>&1); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "nested symlink"; then
  pass "reject_nested_task_symlink"
else
  fail "reject_nested_task_symlink" "rc=$rc out=$out"
fi

# --- Test 38: ensure_dirs rejects a nested symlink under prompts/ ---
NSP="$TMP/nested-prompt"; mkdir -p "$NSP/tasks" "$NSP/prompts"
ln -s /etc/hosts "$NSP/prompts/evil.md"
out=$(SESSION_SCHEDULER_HOME="$NSP" bash "$HERE/task-status.sh" --all 2>&1); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "nested symlink"; then
  pass "reject_nested_prompt_symlink"
else
  fail "reject_nested_prompt_symlink" "rc=$rc out=$out"
fi

# --- Test 39: ensure_dirs rejects a special (non dir/regular) file ---
SPC="$TMP/special"; mkdir -p "$SPC/tasks" "$SPC/prompts"
mkfifo "$SPC/tasks/pipe" 2>/dev/null
if [ -p "$SPC/tasks/pipe" ]; then
  out=$(SESSION_SCHEDULER_HOME="$SPC" bash "$HERE/task-status.sh" --all 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && echo "$out" | grep -q "special"; then
    pass "reject_special_file"
  else
    fail "reject_special_file" "rc=$rc out=$out"
  fi
else
  pass "reject_special_file"   # mkfifo unavailable; skip cleanly
fi

# --- Test 40: concurrent ensure_dirs init race leaves a valid 0700 tree ---
RACE="$TMP/race"
( SESSION_SCHEDULER_HOME="$RACE" bash "$HERE/task-new.sh" "r1" >/dev/null 2>&1 ) &
( SESSION_SCHEDULER_HOME="$RACE" bash "$HERE/task-new.sh" "r2" >/dev/null 2>&1 ) &
wait
d_mode=$(stat -c '%a' "$RACE/tasks" 2>/dev/null || stat -f '%Lp' "$RACE/tasks" 2>/dev/null)
n_tasks=$(find "$RACE/tasks" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
if [ "$d_mode" = "700" ] && [ "$n_tasks" = "2" ]; then
  pass "ensure_dirs_init_race"
else
  fail "ensure_dirs_init_race" "mode=$d_mode tasks=$n_tasks"
fi

# --- Test 41: successful reviewer dispatch is NOT repeated (no duplicate delivery) ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "rev-nodup" 2>&1)
RND_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$RND_ID" --reviewer auditor "nodup work" >/dev/null 2>&1
out1=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-review.sh" "$RND_ID" "sha-A" 2>&1)
disp1=$(jq -r '.meta.review_dispatched_at // ""' "$SESSION_SCHEDULER_HOME/tasks/$RND_ID.json")
out2=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-review.sh" "$RND_ID" "sha-A" 2>&1)
if echo "$out1" | grep -q "routed to reviewer: auditor" && [ -n "$disp1" ] && [ "$disp1" != "null" ] \
   && echo "$out2" | grep -q "Not re-dispatching" && ! echo "$out2" | grep -q "routed to reviewer"; then
  pass "review_no_duplicate_dispatch"
else
  fail "review_no_duplicate_dispatch" "disp1=$disp1 out1=$out1 out2=$out2"
fi

# Release/reclaim safety under a concurrent rename-release (the ownerless
# lock wedge from CI run 35104849303, and a stale reclaim crossing lock
# generations) is covered by the shared cross-provider suite
# scripts/test-scheduler-locks.py, which drives the REAL helpers with
# injected barriers against both libraries. Hand-replayed shell sequences are
# deliberately not duplicated here: they cannot detect loss of the cd -P
# anchoring and would give false confidence.

# --- Test 42: reassignment clears the review-dispatch marker (fresh cycle) ---
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-2 "$RND_ID" --reviewer auditor --force "reassigned work" >/dev/null 2>&1
disp_after=$(jq -r '.meta.review_dispatched_at // "cleared"' "$SESSION_SCHEDULER_HOME/tasks/$RND_ID.json")
if [ "$disp_after" = "cleared" ] || [ "$disp_after" = "null" ]; then
  pass "reassign_clears_review_marker"
else
  fail "reassign_clears_review_marker" "review_dispatched_at still set: $disp_after"
fi

# --- Test 43: provenance records the raw canonical path (spaces + apostrophe intact,
#     and still no executable export line even for a weird path) ---
WQH="$TMP/sched home's weird"
mkdir -p "$WQH"
out=$(SESSION_SCHEDULER_HOME="$WQH" bash "$HERE/task-new.sh" "wq" 2>&1)
WQ_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$WQH" bash "$HERE/task-assign.sh" worker-1 "$WQ_ID" "wq work" >/dev/null 2>&1
wq_pf="$WQH/prompts/$WQ_ID.md"
wq_abs=$(cd "$WQH" && pwd -P)
if grep -qF "Shared scheduler home (provenance): $wq_abs" "$wq_pf" 2>/dev/null \
   && ! grep -qE '^[[:space:]]*export SESSION_(SCHEDULER|CONTEXT)_HOME' "$wq_pf" 2>/dev/null; then
  pass "assignment_provenance_special_path"
else
  fail "assignment_provenance_special_path" "expected raw path '$wq_abs' in $wq_pf"
fi

# --- Test 44: full upgrade sequence — canonical null + stale root aliases,
#     first dispatch hard-fails, retry succeeds; canonical authoritative, all
#     seven legacy root aliases cleared, review history stays exactly one event ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "stale-alias" 2>&1)
SA_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$SA_ID" --reviewer auditor "stale work" >/dev/null 2>&1
sa_f="$SESSION_SCHEDULER_HOME/tasks/$SA_ID.json"
# First reviewer dispatch HARD-FAILS -> status=review, canonical success null, 1 review event.
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CHAT_ROOT_OVERRIDE="$REV_FAIL" bash "$HERE/task-review.sh" "$SA_ID" "sha1" >/dev/null 2>&1
# Overlay ALL SEVEN stale legacy root aliases (as an upgraded-from-Codex ledger would carry).
jq '.review_dispatched_at="2020-01-01T00:00:00Z" | .review_dispatch_status="delivered" | .review_dispatch_error="old" | .review_dispatch_attempt_at="2020-01-01T00:00:00Z" | .review_last_dispatch_attempt_at="2020-01-01T00:00:00Z" | .review_dispatch_attempts=9 | .review_prompt_file="/old/path.md"' "$sa_f" > "$sa_f.tmp" && mv "$sa_f.tmp" "$sa_f"
st1=$(jq -r '.status' "$sa_f")
canon1=$(jq -r '.meta.review_dispatched_at' "$sa_f")
hist1=$(jq -r '[.history[] | select(.event=="review")] | length' "$sa_f")
# Retry with the WORKING stub -> second attempt succeeds.
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-review.sh" "$SA_ID" "sha2" 2>&1)
canon2=$(jq -r '.meta.review_dispatched_at // "null"' "$sa_f")
cstatus2=$(jq -r '.meta.review_dispatch_status // "null"' "$sa_f")
cerr2=$(jq -r '.meta.review_dispatch_error // "null"' "$sa_f")
hist2=$(jq -r '[.history[] | select(.event=="review")] | length' "$sa_f")
root_aliases=$(jq -r '[.review_dispatched_at,.review_dispatch_status,.review_dispatch_error,.review_dispatch_attempt_at,.review_last_dispatch_attempt_at,.review_dispatch_attempts,.review_prompt_file] | map(select(. != null)) | length' "$sa_f")
if [ "$st1" = "review" ] && [ "$canon1" = "null" ] && [ "$hist1" = "1" ] \
   && echo "$out" | grep -q "routed to reviewer: auditor" \
   && [ "$canon2" != "null" ] && [ "$cstatus2" != "null" ] && [ "$cerr2" = "null" ] \
   && [ "$root_aliases" = "0" ] && [ "$hist2" = "1" ]; then
  pass "review_upgrade_sequence"
else
  fail "review_upgrade_sequence" "st1=$st1 canon1=$canon1 hist1=$hist1 canon2=$canon2 cstatus2=$cstatus2 cerr2=$cerr2 root_aliases=$root_aliases hist2=$hist2 out=$out"
fi

# --- Test 45: inverse — legacy-only success (canonical ABSENT + root aliases)
#     fully normalizes into canonical (status preserved), drops ALL root aliases,
#     suppresses the duplicate, and leaves history + dispatch count unchanged ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "legacy-only" 2>&1)
LO_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$LO_ID" --reviewer auditor "legacy work" >/dev/null 2>&1
lo_f="$SESSION_SCHEDULER_HOME/tasks/$LO_ID.json"
# Truly legacy shape: NO .meta object at all, only root review_* aliases.
jq 'del(.meta) | .status="review"
    | .review_dispatched_at="2026-05-05T00:00:00Z" | .review_dispatch_status="queued"
    | .review_dispatch_attempts=3 | .review_prompt_file="/legacy/pf.md"' "$lo_f" > "$lo_f.tmp" && mv "$lo_f.tmp" "$lo_f"
hist_before=$(jq -r '[.history[] | select(.event=="review")] | length' "$lo_f")
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-review.sh" "$LO_ID" "sha3" 2>&1)
lo_canon=$(jq -r '.meta.review_dispatched_at // "null"' "$lo_f")
lo_status=$(jq -r '.meta.review_dispatch_status // "null"' "$lo_f")
lo_attempts=$(jq -r '.meta.review_dispatch_attempts // "null"' "$lo_f")
lo_pf=$(jq -r '.meta.review_prompt_file // "null"' "$lo_f")
lo_root=$(jq -r '[.review_dispatched_at,.review_dispatch_status,.review_dispatch_error,.review_dispatch_attempt_at,.review_last_dispatch_attempt_at,.review_dispatch_attempts,.review_prompt_file] | map(select(. != null)) | length' "$lo_f")
hist_after=$(jq -r '[.history[] | select(.event=="review")] | length' "$lo_f")
if echo "$out" | grep -q "Not re-dispatching" && ! echo "$out" | grep -q "routed to reviewer" \
   && [ "$lo_canon" = "2026-05-05T00:00:00Z" ] && [ "$lo_status" = "queued" ] \
   && [ "$lo_attempts" = "3" ] && [ "$lo_pf" = "/legacy/pf.md" ] \
   && [ "$lo_root" = "0" ] && [ "$hist_after" = "$hist_before" ]; then
  pass "review_legacy_only_normalizes_and_suppresses"
else
  fail "review_legacy_only_normalizes_and_suppresses" "canon=$lo_canon status=$lo_status attempts=$lo_attempts pf=$lo_pf root=$lo_root hist=$hist_before/$hist_after out=$out"
fi

# --- Test 46: legacy success timestamp with NO status derives 'delivered' ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "legacy-derive" 2>&1)
LD_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$LD_ID" --reviewer auditor "derive work" >/dev/null 2>&1
ld_f="$SESSION_SCHEDULER_HOME/tasks/$LD_ID.json"
jq 'del(.meta.review_dispatched_at, .meta.review_dispatch_status) | .status="review" | .review_dispatched_at="2026-06-06T00:00:00Z"' "$ld_f" > "$ld_f.tmp" && mv "$ld_f.tmp" "$ld_f"
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-review.sh" "$LD_ID" "sha4" 2>&1)
ld_status=$(jq -r '.meta.review_dispatch_status // "null"' "$ld_f")
ld_root=$(jq -r '[.review_dispatched_at,.review_dispatch_status] | map(select(. != null)) | length' "$ld_f")
if echo "$out" | grep -q "Not re-dispatching" && [ "$ld_status" = "delivered" ] && [ "$ld_root" = "0" ]; then
  pass "review_legacy_derives_delivered"
else
  fail "review_legacy_derives_delivered" "status=$ld_status root=$ld_root out=$out"
fi


# --- Test 40: tasks-clean sweeps every artifact a task owns, by exact name ---
CLEAN_HOME="$TMP/clean-scheduler"
mkdir -p "$CLEAN_HOME"
c_out=$(SESSION_SCHEDULER_HOME="$CLEAN_HOME" bash "$HERE/task-new.sh" "old-done" 2>&1)
C_OLD=$(echo "$c_out" | awk '/Created task:/ {print $3}')
c_out=$(SESSION_SCHEDULER_HOME="$CLEAN_HOME" bash "$HERE/task-new.sh" "hyphen-sibling" 2>&1)
C_SIB_SEED=$(echo "$c_out" | awk '/Created task:/ {print $3}')
# A task literally named "<C_OLD>-review" must NOT lose its base prompt when
# <C_OLD> is cleaned (exact names, never <id>-* globs).
C_SIB="${C_OLD}-review"
jq --arg id "$C_SIB" '.id = $id' "$CLEAN_HOME/tasks/$C_SIB_SEED.json" > "$CLEAN_HOME/tasks/$C_SIB.json"
rm -f "$CLEAN_HOME/tasks/$C_SIB_SEED.json"
SESSION_SCHEDULER_HOME="$CLEAN_HOME" bash "$HERE/task-assign.sh" worker-1 "$C_OLD" --context auto "old work" >/dev/null 2>&1
SESSION_SCHEDULER_HOME="$CLEAN_HOME" bash "$HERE/task-assign.sh" worker-1 "$C_SIB" "sibling work" >/dev/null 2>&1
SESSION_SCHEDULER_HOME="$CLEAN_HOME" SESSION_CHAT_ROOT_OVERRIDE="$TMP/session-chat-stub" bash "$HERE/task-done.sh" "$C_OLD" "finished" >/dev/null 2>&1
# Fake packet files the task owns, then age the task.
: > "$CLEAN_HOME/prompts/$C_OLD-ack-done.md"; : > "$CLEAN_HOME/prompts/$C_OLD-ack-review.md"
jq '.updated_at = "2020-01-01T00:00:00+05:30"' "$CLEAN_HOME/tasks/$C_OLD.json" > "$CLEAN_HOME/tasks/$C_OLD.json.tmp" && mv "$CLEAN_HOME/tasks/$C_OLD.json.tmp" "$CLEAN_HOME/tasks/$C_OLD.json"
dry=$(SESSION_SCHEDULER_HOME="$CLEAN_HOME" bash "$HERE/tasks-clean.sh" --older-than 7 2>&1)
SESSION_SCHEDULER_HOME="$CLEAN_HOME" bash "$HERE/tasks-clean.sh" --older-than 7 --apply >/dev/null 2>&1
if echo "$dry" | grep -q "DRY-RUN: would delete 1 task" \
   && [ ! -e "$CLEAN_HOME/tasks/$C_OLD.json" ] && [ ! -e "$CLEAN_HOME/prompts/$C_OLD.md" ] \
   && [ ! -e "$CLEAN_HOME/prompts/$C_OLD-ack-done.md" ] && [ ! -e "$CLEAN_HOME/prompts/$C_OLD-ack-review.md" ] \
   && [ ! -e "$CLEAN_HOME/handoffs/$C_OLD" ] \
   && [ -f "$CLEAN_HOME/tasks/$C_SIB.json" ] && [ -f "$CLEAN_HOME/prompts/$C_SIB.md" ]; then
  pass "clean_sweeps_owned_artifacts_exact_names"
else
  fail "clean_sweeps_owned_artifacts_exact_names" "dry=$dry; $(ls -R "$CLEAN_HOME")"
fi

# --- Test 40a: reverse-dependency guard keeps a referenced prerequisite ---
c_out=$(SESSION_SCHEDULER_HOME="$CLEAN_HOME" bash "$HERE/task-new.sh" "prereq" 2>&1)
C_PRE=$(echo "$c_out" | awk '/Created task:/ {print $3}')
c_out=$(SESSION_SCHEDULER_HOME="$CLEAN_HOME" bash "$HERE/task-new.sh" "dependent" --depends-on "$C_PRE" 2>&1)
C_DEP=$(echo "$c_out" | awk '/Created task:/ {print $3}')
jq '.status = "done" | .updated_at = "2020-01-01T00:00:00+05:30"' "$CLEAN_HOME/tasks/$C_PRE.json" > "$CLEAN_HOME/tasks/$C_PRE.json.tmp" && mv "$CLEAN_HOME/tasks/$C_PRE.json.tmp" "$CLEAN_HOME/tasks/$C_PRE.json"
dry=$(SESSION_SCHEDULER_HOME="$CLEAN_HOME" bash "$HERE/tasks-clean.sh" --older-than 7 --apply 2>&1)
# Control: once the dependent is deleted too, the prerequisite goes.
jq '.updated_at = "2020-01-01T00:00:00+05:30"' "$CLEAN_HOME/tasks/$C_DEP.json" > "$CLEAN_HOME/tasks/$C_DEP.json.tmp" && mv "$CLEAN_HOME/tasks/$C_DEP.json.tmp" "$CLEAN_HOME/tasks/$C_DEP.json"
SESSION_SCHEDULER_HOME="$CLEAN_HOME" bash "$HERE/tasks-clean.sh" --older-than 7 --apply >/dev/null 2>&1
if echo "$dry" | grep -q "kept $C_PRE (referenced by $C_DEP)" && echo "$dry" | grep -q "Nothing to clean" \
   && [ ! -e "$CLEAN_HOME/tasks/$C_PRE.json" ] && [ ! -e "$CLEAN_HOME/tasks/$C_DEP.json" ]; then
  pass "clean_keeps_referenced_prerequisite"
else
  fail "clean_keeps_referenced_prerequisite" "out=$dry; $(ls "$CLEAN_HOME/tasks")"
fi

# --- Test 40b: orphan sweep removes handoffs/prompts with no task, honouring the suffix rule ---
mkdir -p "$CLEAN_HOME/handoffs/ghost"; : > "$CLEAN_HOME/handoffs/ghost/0123456789abcdef0123456789abcdef.md"
: > "$CLEAN_HOME/prompts/ghost.md"; : > "$CLEAN_HOME/prompts/ghost-review.md"
: > "$CLEAN_HOME/prompts/$C_SIB-ack-done.md"   # owned by live task C_SIB — must survive
touch -t 202001010000 "$CLEAN_HOME/handoffs/ghost" "$CLEAN_HOME/prompts/ghost.md" "$CLEAN_HOME/prompts/ghost-review.md" "$CLEAN_HOME/prompts/$C_SIB-ack-done.md"
: > "$CLEAN_HOME/prompts/fresh-orphan.md"        # orphan but NEW — must survive
dry=$(SESSION_SCHEDULER_HOME="$CLEAN_HOME" bash "$HERE/tasks-clean.sh" --older-than 7 2>&1)
SESSION_SCHEDULER_HOME="$CLEAN_HOME" bash "$HERE/tasks-clean.sh" --older-than 7 --apply >/dev/null 2>&1
if echo "$dry" | grep -q "Orphans (no task JSON, older than 7d): 3" \
   && [ ! -e "$CLEAN_HOME/handoffs/ghost" ] && [ ! -e "$CLEAN_HOME/prompts/ghost.md" ] && [ ! -e "$CLEAN_HOME/prompts/ghost-review.md" ] \
   && [ -f "$CLEAN_HOME/prompts/$C_SIB-ack-done.md" ] && [ -f "$CLEAN_HOME/prompts/fresh-orphan.md" ]; then
  pass "clean_orphan_sweep"
else
  fail "clean_orphan_sweep" "dry=$dry; $(ls -R "$CLEAN_HOME")"
fi

# --- Test 41: per-task lock serializes concurrent mutations (no lost update) ---
LOCK_HOME="$TMP/lock-scheduler"
mkdir -p "$LOCK_HOME"
l_out=$(SESSION_SCHEDULER_HOME="$LOCK_HOME" bash "$HERE/task-new.sh" "contended" 2>&1)
L_ID=$(echo "$l_out" | awk '/Created task:/ {print $3}')
# 12 concurrent history appends through the locked lib path; every one must land.
for i in $(seq 1 12); do
  ( SESSION_SCHEDULER_HOME="$LOCK_HOME" bash -c 'source "$1/lib.sh"; task_append_history "$2" "note" "w$3" "n$3"' _ "$HERE" "$L_ID" "$i" ) &
done
wait
l_count=$(jq '[.history[] | select(.event == "note")] | length' "$LOCK_HOME/tasks/$L_ID.json")
# Control: a held lock blocks a writer until timeout (then fails, never writes).
mkdir -p "$LOCK_HOME/locks/$L_ID.lock"; printf '%s\n' "$$" > "$LOCK_HOME/locks/$L_ID.lock/pid"
l_blocked=$(SESSION_SCHEDULER_HOME="$LOCK_HOME" SESSION_SCHEDULER_LOCK_TIMEOUT_SECS=1 bash "$HERE/task-block.sh" "$L_ID" "should wait" 2>&1)
l_rc=$?
rm -rf "$LOCK_HOME/locks/$L_ID.lock"
# Stale lock (dead pid) is reclaimed.
mkdir -p "$LOCK_HOME/locks/$L_ID.lock"; printf '%s\n' "999999" > "$LOCK_HOME/locks/$L_ID.lock/pid"
SESSION_SCHEDULER_HOME="$LOCK_HOME" bash "$HERE/task-block.sh" "$L_ID" "reclaimed" >/dev/null 2>&1
l_status=$(jq -r '.status' "$LOCK_HOME/tasks/$L_ID.json")
if [ "$l_count" = "12" ] && [ "$l_rc" != "0" ] && echo "$l_blocked" | grep -q "could not lock task" \
   && [ "$l_status" = "blocked" ] && [ ! -e "$LOCK_HOME/locks/$L_ID.lock" ]; then
  pass "task_lock_serializes_and_reclaims"
else
  fail "task_lock_serializes_and_reclaims" "count=$l_count blocked_rc=$l_rc status=$l_status out=$l_blocked"
fi

# --- Test 41b: stale-lock reclaim is serialized — many waiters, one dead holder, no double-hold ---
# Every waiter sees the same dead pid at once. Without the reclaim marker +
# recheck, one waiter reclaims and re-acquires while another still deletes the
# "stale" pid file — now the LIVE holder's — and a second holder gets in. Each
# waiter records its own pid while holding the lock and sleeps briefly; any
# overlap shows up as two holders present at once.
RL_HOME="$TMP/reclaim-scheduler"
mkdir -p "$RL_HOME"
rl_out=$(SESSION_SCHEDULER_HOME="$RL_HOME" bash "$HERE/task-new.sh" "reclaim-race" 2>&1)
RL_ID=$(echo "$rl_out" | awk '/Created task:/ {print $3}')
RL_LIB="${SESSION_SCHEDULER_LOCK_TEST_LIB:-$HERE/lib.sh}"
run_reclaim_race() {
  rm -rf "$RL_HOME/locks/$RL_ID.lock" "$RL_HOME/overlap"
  mkdir -p "$RL_HOME/locks/$RL_ID.lock"; printf '%s\n' "999999" > "$RL_HOME/locks/$RL_ID.lock/pid"
  for i in $(seq 1 10); do
    ( SESSION_SCHEDULER_HOME="$RL_HOME" bash -c '
        source "$1"; id="$2"; home="$3"
        task_lock "$id" || exit 9
        # While held: the pid file must be ours, and nobody else may be inside.
        [ "$(cat "$home/locks/$id.lock/pid" 2>/dev/null)" = "$$" ] || touch "$home/overlap"
        [ -e "$home/inside" ] && touch "$home/overlap"
        : > "$home/inside"; sleep 0.05; rm -f "$home/inside"
        task_append_history "$id" "rl" "w" "x" >/dev/null 2>&1 || true
        task_unlock "$id"' _ "$RL_LIB" "$RL_ID" "$RL_HOME" ) &
  done
  wait
}
# task_append_history takes the lock itself, so call it OUTSIDE the held
# section above (non-reentrant); rerun the race so the count check is real.
run_reclaim_race
rl_overlap=$([ -e "$RL_HOME/overlap" ] && echo yes || echo no)
rl_left=$([ -e "$RL_HOME/locks/$RL_ID.lock" ] && echo yes || echo no)
if [ "$rl_overlap" = "no" ] && [ "$rl_left" = "no" ]; then
  pass "task_lock_stale_reclaim_serialized"
else
  fail "task_lock_stale_reclaim_serialized" "overlap=$rl_overlap lock_left=$rl_left"
fi

# --- Test 42: review retry reuses the ORIGINAL note in the audit packet ---
RN_HOME="$TMP/retry-note"
mkdir -p "$RN_HOME"
make_session_chat_stub "$TMP/rn-fail" 1 0 "rn-executor"
make_session_chat_stub "$TMP/rn-ok" 0 0 "rn-executor"
rn_out=$(SESSION_SCHEDULER_HOME="$RN_HOME" bash "$HERE/task-new.sh" "retry-note" --reviewer rn-reviewer 2>&1)
RN_ID=$(echo "$rn_out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$RN_HOME" bash "$HERE/task-assign.sh" rn-executor "$RN_ID" "work" >/dev/null 2>&1
SESSION_SCHEDULER_HOME="$RN_HOME" SESSION_CHAT_ROOT_OVERRIDE="$TMP/rn-fail" bash "$HERE/task-review.sh" "$RN_ID" "sha-original-1234" >/dev/null 2>&1
rn_retry=$(SESSION_SCHEDULER_HOME="$RN_HOME" SESSION_CHAT_ROOT_OVERRIDE="$TMP/rn-ok" bash "$HERE/task-review.sh" "$RN_ID" "retry typo note" 2>&1)
if grep -q "Note (e.g. commit SHA): sha-original-1234" "$RN_HOME/prompts/$RN_ID-review.md" \
   && ! grep -q "retry typo note" "$RN_HOME/prompts/$RN_ID-review.md" \
   && echo "$rn_retry" | grep -q "note: sha-original-1234 (original review note reused on retry)" \
   && [ "$(jq -r '.meta.review_dispatch_status' "$RN_HOME/tasks/$RN_ID.json")" = "delivered" ]; then
  pass "review_retry_reuses_original_note"
else
  fail "review_retry_reuses_original_note" "out=$rn_retry packet=$(grep Note "$RN_HOME/prompts/$RN_ID-review.md")"
fi

# --- Test 43: --mine covers assigner, assignee, and reviewer ---
MINE_HOME="$TMP/mine"
mkdir -p "$MINE_HOME"
make_session_chat_stub "$TMP/mine-stub" 0 0 "me-pane"
m_out=$(SESSION_SCHEDULER_HOME="$MINE_HOME" SESSION_CHAT_ROOT_OVERRIDE="$TMP/session-chat-stub" bash "$HERE/task-new.sh" "assigned-to-me" 2>&1)
M_ASSIGNEE=$(echo "$m_out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$MINE_HOME" SESSION_CHAT_ROOT_OVERRIDE="$TMP/session-chat-stub" bash "$HERE/task-assign.sh" me-pane "$M_ASSIGNEE" "w" >/dev/null 2>&1
m_out=$(SESSION_SCHEDULER_HOME="$MINE_HOME" SESSION_CHAT_ROOT_OVERRIDE="$TMP/session-chat-stub" bash "$HERE/task-new.sh" "reviewed-by-me" --reviewer me-pane 2>&1)
M_REVIEWER=$(echo "$m_out" | awk '/Created task:/ {print $3}')
m_out=$(SESSION_SCHEDULER_HOME="$MINE_HOME" SESSION_CHAT_ROOT_OVERRIDE="$TMP/session-chat-stub" bash "$HERE/task-new.sh" "not-mine" 2>&1)
M_OTHER=$(echo "$m_out" | awk '/Created task:/ {print $3}')
m_out=$(SESSION_SCHEDULER_HOME="$MINE_HOME" SESSION_CHAT_ROOT_OVERRIDE="$TMP/mine-stub" bash "$HERE/task-new.sh" "created-by-me" 2>&1)
M_CREATOR=$(echo "$m_out" | awk '/Created task:/ {print $3}')
mine=$(SESSION_SCHEDULER_HOME="$MINE_HOME" SESSION_CHAT_ROOT_OVERRIDE="$TMP/mine-stub" bash "$HERE/task-status.sh" --mine 2>&1)
pending=$(SESSION_SCHEDULER_HOME="$MINE_HOME" SESSION_CHAT_ROOT_OVERRIDE="$TMP/mine-stub" bash "$HERE/task-status.sh" --pending 2>&1)
if echo "$mine" | grep -q "$M_ASSIGNEE" && echo "$mine" | grep -q "$M_REVIEWER" && echo "$mine" | grep -q "$M_CREATOR" \
   && ! echo "$mine" | grep -q "$M_OTHER" && echo "$mine" | grep -q "3 task(s) shown" \
   && ! echo "$pending" | grep -q "$M_ASSIGNEE" && echo "$pending" | grep -q "3 task(s) shown"; then
  pass "status_mine_all_roles_pending_created_only"
else
  fail "status_mine_all_roles_pending_created_only" "mine=$mine pending=$pending"
fi

# --- Test 44: value-taking flags with no value error out instead of looping ---
f_out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" timeout 5 bash "$HERE/task-assign.sh" worker-1 "$AC_ID" --eta 2>&1); f1=$?
g_out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" timeout 5 bash "$HERE/task-new.sh" "flagless" --stage 2>&1); f2=$?
h_out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" timeout 5 bash "$HERE/tasks-clean.sh" --older-than 2>&1); f3=$?
if [ "$f1" = "1" ] && echo "$f_out" | grep -q -- "--eta requires a value" \
   && [ "$f2" = "1" ] && echo "$g_out" | grep -q -- "--stage requires a value" \
   && [ "$f3" = "1" ] && echo "$h_out" | grep -q -- "--older-than requires a value"; then
  pass "flags_missing_value_error"
else
  fail "flags_missing_value_error" "rc=$f1/$f2/$f3 out=$f_out | $g_out | $h_out"
fi

# --- Test 45: task-new reports failure (non-zero, no success line) when the write fails ---
# ensure_dirs re-locks the tree to 0700 on every call, so an unwritable tasks/
# dir cannot be injected from outside; instead run the real task-new.sh against
# a lib.sh whose task_write fails, and require the script to propagate it.
STUBLIB="$TMP/stublib"
mkdir -p "$STUBLIB"
cp "$HERE/task-new.sh" "$STUBLIB/task-new.sh"
printf '%s\n' "source \"$HERE/lib.sh\"" 'task_write() { echo "stub: write refused" >&2; return 1; }' > "$STUBLIB/lib.sh"
ro_out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$STUBLIB/task-new.sh" "unwritable" 2>&1); ro_rc=$?
# Control: the same copy with the real lib succeeds.
printf '%s\n' "source \"$HERE/lib.sh\"" > "$STUBLIB/lib.sh"
ok_out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$STUBLIB/task-new.sh" "writable" 2>&1); ok_rc=$?
if [ "$ro_rc" != "0" ] && ! echo "$ro_out" | grep -q "Created task:" && echo "$ro_out" | grep -q "task NOT created" \
   && [ "$ok_rc" = "0" ] && echo "$ok_out" | grep -q "Created task:"; then
  pass "task_new_fails_closed_on_write_error"
else
  fail "task_new_fails_closed_on_write_error" "rc=$ro_rc out=$ro_out ctrl_rc=$ok_rc"
fi

# --- Test 46: task_write refuses anything but exactly one JSON object ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "write-guard" 2>&1)
WG_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
WG_FILE="$SESSION_SCHEDULER_HOME/tasks/$WG_ID.json"
WG_BEFORE=$(cksum < "$WG_FILE")
wg_bad=0
for content in "" "not json" "[]" '{"a":1}{"b":2}' '{"a":'; do
  if SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash -c 'source "$1"; task_write "$2" "$3"' wg "$HERE/lib.sh" "$WG_ID" "$content" 2>/dev/null; then
    wg_bad=1
  fi
done
WG_AFTER=$(cksum < "$WG_FILE")
# Control: a valid object is written.
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash -c 'source "$1"; task_write "$2" "$(jq ".name = \"rewritten\"" "$3")"' wg "$HERE/lib.sh" "$WG_ID" "$WG_FILE" 2>/dev/null; wg_ok=$?
if [ -n "$WG_ID" ] && [ "$wg_bad" = 0 ] && [ "$WG_BEFORE" = "$WG_AFTER" ] && [ "$wg_ok" = 0 ] \
   && [ "$(jq -r '.name' "$WG_FILE")" = "rewritten" ] && ! ls "$SESSION_SCHEDULER_HOME/tasks/$WG_ID.json.tmp."* >/dev/null 2>&1; then
  pass "task_write_rejects_non_object_content"
else
  fail "task_write_rejects_non_object_content" "id=$WG_ID bad=$wg_bad before=$WG_BEFORE after=$WG_AFTER ok=$wg_ok"
fi

# --- Test 47: a failed jq during a status flip leaves the task intact ---
# The real task-block.sh runs against a lib.sh whose jq fails only for the
# status-flip filter, the way a jq error would inside task_set_status_unlocked.
JQLIB="$TMP/jqfail"
mkdir -p "$JQLIB"
cp "$HERE/task-block.sh" "$JQLIB/task-block.sh"
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "jq-failure" 2>&1)
JF_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
JF_FILE="$SESSION_SCHEDULER_HOME/tasks/$JF_ID.json"
JF_BEFORE=$(cksum < "$JF_FILE")
printf '%s\n' "source \"$HERE/lib.sh\"" \
  'jq() { case "$*" in *".status = \$status"*) return 5 ;; esac; command jq "$@"; }' > "$JQLIB/lib.sh"
jf_out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CHAT_ROOT_OVERRIDE="$TMP/no-chat" bash "$JQLIB/task-block.sh" "$JF_ID" "jq broke" 2>&1); jf_rc=$?
JF_AFTER=$(cksum < "$JF_FILE")
# Control: the same copy with the real lib performs the transition.
printf '%s\n' "source \"$HERE/lib.sh\"" > "$JQLIB/lib.sh"
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CHAT_ROOT_OVERRIDE="$TMP/no-chat" bash "$JQLIB/task-block.sh" "$JF_ID" "control" >/dev/null 2>&1
if [ -n "$JF_ID" ] && [ "$jf_rc" != 0 ] && [ "$JF_BEFORE" = "$JF_AFTER" ] && echo "$jf_out" | grep -q "NOT marked blocked" \
   && [ "$(jq -r '.status' "$JF_FILE")" = "blocked" ]; then
  pass "status_flip_jq_failure_preserves_task"
else
  fail "status_flip_jq_failure_preserves_task" "id=$JF_ID rc=$jf_rc before=$JF_BEFORE after=$JF_AFTER status=$(jq -r '.status' "$JF_FILE" 2>&1) out=$jf_out"
fi

# --- Tests 48-54: verification-contract routing and guards (0.7.0) ---
# A copy of the scripts with a stub task-contract.sh that records its argv and
# answers `inspect` from a per-task state file, so these tests pin the legacy
# side of the interface without depending on the engine itself.
CT_DIR="$TMP/contract-scripts"
mkdir -p "$CT_DIR"
cp "$HERE"/*.sh "$CT_DIR/"
CT_HOME="$TMP/contract-home"
mkdir -p "$CT_HOME"
CT_LOG="$TMP/contract-argv.log"
CT_STATE="$TMP/contract-state"
mkdir -p "$CT_STATE"
cat > "$CT_DIR/task-contract.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  route) printf '%s\n' "$@" > "$CT_LOG"; echo "stub-route $2"; exit 0 ;;
  inspect)
    state=$(cat "$CT_STATE/$2" 2>/dev/null || echo invalid)
    case "$state" in admitted) rc=0 ;; closed-unadmitted|active) rc=1 ;; *) rc=2 ;; esac
    printf '{"state":"%s"}\n' "$state"; exit "$rc" ;;
esac
exit 2
STUB
export CT_LOG CT_STATE
ct() { SESSION_SCHEDULER_HOME="$CT_HOME" SESSION_CHAT_ROOT_OVERRIDE="$STUB_DIR/.." bash "$CT_DIR/$1" "${@:2}"; }
ct_new() { ct task-new.sh "$1" 2>&1 | awk '/Created task:/ {print $3}'; }
ct_attach() { # simulate an attached contract (the engine's job) directly in the file
  jq '.contract = {"schema_version": 1, "generation": 1}' "$CT_HOME/tasks/$1.json" > "$CT_HOME/tasks/$1.json.tmp" \
    && mv "$CT_HOME/tasks/$1.json.tmp" "$CT_HOME/tasks/$1.json"
}

# 48: every legacy entry point hands a contracted task to the engine verbatim.
CR_ID=$(ct_new "contract-route"); ct_attach "$CR_ID"
CR_BEFORE=$(cksum < "$CT_HOME/tasks/$CR_ID.json")
cr_ok=1
for spec in "task-done.sh|done|$CR_ID|--generation|1|all good" "task-review.sh|review|$CR_ID|--generation|1|sha abc" \
            "task-block.sh|block|$CR_ID|--force|why" "task-assign.sh|assign|exec-pane|$CR_ID|do it"; do
  IFS='|' read -r script op a1 a2 a3 a4 <<< "$spec"
  rm -f "$CT_LOG"
  args=("$a1" "$a2" "$a3"); [ -n "$a4" ] && args+=("$a4")
  out=$(ct "$script" "${args[@]}" 2>&1); rc=$?
  expected=$(printf '%s\n' route "$op" "${args[@]}")
  if [ "$rc" != 0 ] || [ "$(cat "$CT_LOG" 2>/dev/null)" != "$expected" ]; then cr_ok=0; echo "    route mismatch for $script: rc=$rc out=$out" >&2; fi
done
CR_AFTER=$(cksum < "$CT_HOME/tasks/$CR_ID.json")
# Control: an uncontracted task never reaches the engine.
CN_ID=$(ct_new "no-contract"); rm -f "$CT_LOG"
ct task-block.sh "$CN_ID" "legacy reason" >/dev/null 2>&1; cn_rc=$?
if [ "$cr_ok" = 1 ] && [ "$CR_BEFORE" = "$CR_AFTER" ] && [ "$cn_rc" = 0 ] && [ ! -e "$CT_LOG" ] \
   && [ "$(jq -r '.status' "$CT_HOME/tasks/$CN_ID.json")" = "blocked" ]; then
  pass "contract_early_route_hands_off_verbatim"
else
  fail "contract_early_route_hands_off_verbatim" "ok=$cr_ok before=$CR_BEFORE after=$CR_AFTER ctrl_rc=$cn_rc"
fi

# 49: a contracted task with no engine installed fails closed; the file is untouched.
mv "$CT_DIR/task-contract.sh" "$CT_DIR/task-contract.sh.off"
out=$(ct task-done.sh "$CR_ID" --force "closing anyway" 2>&1); ne_rc=$?
mv "$CT_DIR/task-contract.sh.off" "$CT_DIR/task-contract.sh"
if [ "$ne_rc" = 2 ] && echo "$out" | grep -q "task-contract.sh is not installed" \
   && [ "$CR_BEFORE" = "$(cksum < "$CT_HOME/tasks/$CR_ID.json")" ]; then
  pass "contract_without_engine_fails_closed"
else
  fail "contract_without_engine_fails_closed" "rc=$ne_rc out=$out"
fi

# 50: legacy writers re-check under the lock and refuse even when forced, so a
# contract attached after a caller's early check cannot be overwritten.
GL_ID=$(ct_new "guard-legacy"); ct_attach "$GL_ID"
GL_BEFORE=$(cksum < "$CT_HOME/tasks/$GL_ID.json")
gl_out=$(SESSION_SCHEDULER_HOME="$CT_HOME" SESSION_SCHEDULER_FORCE=1 bash -c \
  'source "$1"; task_set_status "$2" done tester forced; a=$?; task_update "$2" ".name = \"x\""; b=$?; echo "rc=$a/$b"' g "$CT_DIR/lib.sh" "$GL_ID" 2>&1)
GL_AFTER=$(cksum < "$CT_HOME/tasks/$GL_ID.json")
# Control: the same calls succeed on an uncontracted task.
GC_ID=$(ct_new "guard-control")
gc_out=$(SESSION_SCHEDULER_HOME="$CT_HOME" bash -c \
  'source "$1"; task_set_status "$2" blocked tester ok; a=$?; task_update "$2" ".name = \"x\""; b=$?; echo "rc=$a/$b"' g "$CT_DIR/lib.sh" "$GC_ID" 2>&1)
if echo "$gl_out" | grep -q "rc=1/1" && echo "$gl_out" | grep -q "has a verification contract" \
   && [ "$GL_BEFORE" = "$GL_AFTER" ] && echo "$gc_out" | grep -q "rc=0/0"; then
  pass "contract_legacy_writers_refuse_under_lock"
else
  fail "contract_legacy_writers_refuse_under_lock" "contracted=$gl_out control=$gc_out"
fi

# 51: a contracted dependency counts only when admitted, and --force cannot skip it.
DP_DEP=$(ct_new "contract-dep"); ct_attach "$DP_DEP"
jq '.status = "done"' "$CT_HOME/tasks/$DP_DEP.json" > "$CT_HOME/tasks/$DP_DEP.json.tmp" && mv "$CT_HOME/tasks/$DP_DEP.json.tmp" "$CT_HOME/tasks/$DP_DEP.json"
DP_ID=$(ct task-new.sh "dependent" --depends-on "$DP_DEP" 2>&1 | awk '/Created task:/ {print $3}')
echo closed-unadmitted > "$CT_STATE/$DP_DEP"
dp_out=$(ct task-assign.sh exec-pane "$DP_ID" --force "go" 2>&1); dp_rc=$?
dp_status=$(jq -r '.status' "$CT_HOME/tasks/$DP_ID.json")
echo admitted > "$CT_STATE/$DP_DEP"
dp_ok=$(SESSION_SCHEDULER_HOME="$CT_HOME" bash -c 'source "$1"; unadmitted_contract_deps "$2"' g "$CT_DIR/lib.sh" "$DP_ID" 2>&1)
rm -f "$CT_STATE/$DP_DEP"
dp_missing=$(SESSION_SCHEDULER_HOME="$CT_HOME" bash -c 'source "$1"; unadmitted_contract_deps "$2"' g "$CT_DIR/lib.sh" "$DP_ID" 2>&1)
# With the engine absent, an "admitted" state file must not count.
echo admitted > "$CT_STATE/$DP_DEP"
mv "$CT_DIR/task-contract.sh" "$CT_DIR/task-contract.sh.off"
dp_noengine=$(SESSION_SCHEDULER_HOME="$CT_HOME" bash -c 'source "$1"; unadmitted_contract_deps "$2"' g "$CT_DIR/lib.sh" "$DP_ID" 2>&1)
mv "$CT_DIR/task-contract.sh.off" "$CT_DIR/task-contract.sh"
rm -f "$CT_STATE/$DP_DEP"
if [ -n "$DP_ID" ] && [ "$dp_rc" != 0 ] && echo "$dp_out" | grep -q "closed-unadmitted" && [ "$dp_status" = "created" ] \
   && [ -z "$dp_ok" ] && [ "$dp_missing" = "$DP_DEP (invalid)" ] && [ "$dp_noengine" = "$DP_DEP (invalid)" ]; then
  pass "contract_dependency_requires_admission_even_forced"
else
  fail "contract_dependency_requires_admission_even_forced" "id=$DP_ID rc=$dp_rc status=$dp_status out=$dp_out admitted=[$dp_ok] invalid=[$dp_missing] noengine=[$dp_noengine]"
fi

# 52: status flags carry the admission state of contracted tasks only.
echo closed-unadmitted > "$CT_STATE/$DP_DEP"
fl_c=$(SESSION_SCHEDULER_HOME="$CT_HOME" bash -c 'source "$1"; task_flags "$(task_path "$2")"' g "$CT_DIR/lib.sh" "$DP_DEP" 2>&1)
fl_l=$(SESSION_SCHEDULER_HOME="$CT_HOME" bash -c 'source "$1"; task_flags "$(task_path "$2")"' g "$CT_DIR/lib.sh" "$GC_ID" 2>&1)
if [ "$fl_c" = "CONTRACT:closed-unadmitted" ] && [ "$fl_l" = "-" ]; then
  pass "contract_state_in_status_flags"
else
  fail "contract_state_in_status_flags" "contracted=$fl_c legacy=$fl_l"
fi

# 53: cleanup retains every contracted task (any age/status) and still deletes legacy ones.
for id in "$DP_DEP" "$GC_ID"; do
  jq '.updated_at = "2020-01-01T00:00:00+05:30"' "$CT_HOME/tasks/$id.json" > "$CT_HOME/tasks/$id.json.tmp" && mv "$CT_HOME/tasks/$id.json.tmp" "$CT_HOME/tasks/$id.json"
done
# DP_ID depends on DP_DEP; drop that edge so only the contract can keep DP_DEP.
jq '.depends_on = []' "$CT_HOME/tasks/$DP_ID.json" > "$CT_HOME/tasks/$DP_ID.json.tmp" && mv "$CT_HOME/tasks/$DP_ID.json.tmp" "$CT_HOME/tasks/$DP_ID.json"
cl_out=$(ct tasks-clean.sh --older-than 30 --apply 2>&1); cl_rc=$?
if [ "$cl_rc" = 0 ] && [ -f "$CT_HOME/tasks/$DP_DEP.json" ] && [ ! -e "$CT_HOME/tasks/$GC_ID.json" ] \
   && echo "$cl_out" | grep -q "kept $DP_DEP (verification contract retained)" && [ -z "$(ls -A "$CT_HOME/locks")" ]; then
  pass "contract_tasks_survive_cleanup"
else
  fail "contract_tasks_survive_cleanup" "rc=$cl_rc out=$cl_out locks=$(ls -A "$CT_HOME/locks")"
fi

# 54: doctor reports contracted tasks closed without admission.
dr_out=$(SESSION_SCHEDULER_HOME="$CT_HOME" bash "$CT_DIR/scheduler-doctor.sh" 2>&1)
if echo "$dr_out" | grep -q "contracts: .*contracted task" && echo "$dr_out" | grep -q "closed-unadmitted"; then
  pass "contract_doctor_reports_unadmitted"
else
  fail "contract_doctor_reports_unadmitted" "$(echo "$dr_out" | grep -A4 contracts)"
fi

# --- Tier 1.2a: task ids are task-<epoch>-<8hex> from urandom only; creation is
#     exclusive (O_EXCL); legacy 8-hex ids stay valid. ---
ID_HOME="$TMP/id-home"; mkdir -p "$ID_HOME"
ID_SHIM="$TMP/id-shim"; mkdir -p "$ID_SHIM"
REAL_DATE=$(command -v date)
id_new() { SESSION_SCHEDULER_HOME="$ID_HOME" bash "$HERE/task-new.sh" "$@" 2>&1; }
id_count() { find "$ID_HOME/tasks" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
od_shim() { printf '#!/bin/sh\n%s\n' "$1" > "$ID_SHIM/od"; chmod +x "$ID_SHIM/od"; }
rm_shim() { rm -f "$ID_SHIM/od" "$ID_SHIM/date"; }

# 55: new ids match task-<epoch>-<8hex>, resolve through the normal readers, and
#     a legacy bare 8-hex id is still accepted by the same readers.
n_out=$(id_new "fmt-task"); n_id=$(echo "$n_out" | awk '/Created task:/ {print $3}')
n_status=$(SESSION_SCHEDULER_HOME="$ID_HOME" bash "$HERE/task-status.sh" "$n_id" 2>&1); n_status_rc=$?
LEG_ID=deadbeef
jq --arg id "$LEG_ID" '.id = $id | .name = "legacy-8hex"' "$ID_HOME/tasks/$n_id.json" > "$ID_HOME/tasks/$LEG_ID.json"
l_status=$(SESSION_SCHEDULER_HOME="$ID_HOME" bash "$HERE/task-status.sh" "$LEG_ID" 2>&1); l_status_rc=$?
n_id2=$(id_new "fmt-task-2" | awk '/Created task:/ {print $3}')
if [[ "$n_id" =~ ^task-[0-9]+-[a-f0-9]{8}$ ]] && [[ "$n_id2" =~ ^task-[0-9]+-[a-f0-9]{8}$ ]] && [ "$n_id" != "$n_id2" ] \
   && [ -f "$ID_HOME/tasks/$n_id.json" ] && [ "$(jq -r .id "$ID_HOME/tasks/$n_id.json")" = "$n_id" ] \
   && [ "$n_status_rc" = 0 ] && echo "$n_status" | grep -qF "$n_id" \
   && [ "$l_status_rc" = 0 ] && echo "$l_status" | grep -q "legacy-8hex"; then
  pass "task_id_format_epoch_hex_and_legacy_ids_valid"
else
  fail "task_id_format_epoch_hex_and_legacy_ids_valid" "id=$n_id id2=$n_id2 status_rc=$n_status_rc legacy_rc=$l_status_rc out=$n_out"
fi

# 56: no urandom (od fails / short read / malformed) -> task-new fails closed
#     with nothing created; the control (real od) creates a task.
ur_bad=""
for variant in 'exit 1' 'printf " de ad\n"' 'printf " zz zz zz zz\n"' 'printf " DE AD BE EF\n"'; do
  od_shim "$variant"
  before=$(id_count)
  v_out=$(PATH="$ID_SHIM:$PATH" id_new "no-urandom"); v_rc=$?
  after=$(id_count)
  { [ "$v_rc" != 0 ] && ! echo "$v_out" | grep -q 'Created task:' && echo "$v_out" | grep -q 'could not generate a task id' && [ "$before" = "$after" ]; } \
    || ur_bad="$ur_bad [$variant rc=$v_rc before=$before after=$after out=$v_out]"
done
# control: a well-formed shim output is accepted (the refusals above are not a blanket failure)
od_shim 'printf " 0a 1b 2c 3d\n"'
c_out=$(PATH="$ID_SHIM:$PATH" id_new "urandom-control"); c_id=$(echo "$c_out" | awk '/Created task:/ {print $3}')
[[ "$c_id" =~ ^task-[0-9]+-0a1b2c3d$ ]] || ur_bad="$ur_bad [control id=$c_id out=$c_out]"
# no od on PATH at all
NO_OD="$TMP/no-od-bin"; mkdir -p "$NO_OD"
# every executable the script needs (system dirs + jq's dir) EXCEPT od
for d in /bin /usr/bin "$(dirname "$(command -v jq)")"; do
  for f in "$d"/*; do
    n=$(basename "$f")
    [ "$n" != od ] && [ -x "$f" ] && [ ! -e "$NO_OD/$n" ] && ln -s "$f" "$NO_OD/$n" 2>/dev/null
  done
done
[ ! -e "$NO_OD/od" ] || ur_bad="$ur_bad [no-od fixture still has od]"
nb=$(id_count)
no_out=$(SESSION_SCHEDULER_HOME="$ID_HOME" PATH="$NO_OD" "$BASH" "$HERE/task-new.sh" "no-od" 2>&1); no_rc=$?
{ [ "$no_rc" != 0 ] && echo "$no_out" | grep -q 'could not generate a task id' && [ "$(id_count)" = "$nb" ]; } || ur_bad="$ur_bad [no-od rc=$no_rc out=$no_out]"
rm_shim
if [ -z "$ur_bad" ]; then
  pass "task_new_fails_closed_without_urandom"
else
  fail "task_new_fails_closed_without_urandom" "$ur_bad"
fi

# 57: exclusive creation — a pre-existing file (or symlink) at the target is
#     refused and left untouched; control: the same id on a free path is created.
od_shim 'printf " de ad be ef\n"'
printf '#!/bin/sh\nif [ "$1" = "+%%s" ]; then echo 1700000000; else exec %s "$@"; fi\n' "$REAL_DATE" > "$ID_SHIM/date"; chmod +x "$ID_SHIM/date"
COL_ID="task-1700000000-deadbeef"
COL_FILE="$ID_HOME/tasks/$COL_ID.json"
rm -f "$COL_FILE"
printf 'PRE-EXISTING-SENTINEL\n' > "$COL_FILE"
ex_bad=""
c1_out=$(PATH="$ID_SHIM:$PATH" id_new "collides"); c1_rc=$?
{ [ "$c1_rc" != 0 ] && ! echo "$c1_out" | grep -q 'Created task:' && echo "$c1_out" | grep -q 'already exists' \
  && [ "$(cat "$COL_FILE")" = "PRE-EXISTING-SENTINEL" ]; } || ex_bad="$ex_bad [file rc=$c1_rc out=$c1_out content=$(cat "$COL_FILE")]"
# symlink at the path: refused, and nothing is created through it
rm -f "$COL_FILE"; ln -s "$TMP/symlink-victim.json" "$COL_FILE"
c2_out=$(PATH="$ID_SHIM:$PATH" id_new "collides-symlink"); c2_rc=$?
{ [ "$c2_rc" != 0 ] && ! echo "$c2_out" | grep -q 'Created task:' && [ -L "$COL_FILE" ] && [ ! -e "$TMP/symlink-victim.json" ]; } \
  || ex_bad="$ex_bad [symlink rc=$c2_rc out=$c2_out victim=$([ -e "$TMP/symlink-victim.json" ] && echo created || echo none)]"
# control: free path -> created with exactly this id and valid JSON
rm -f "$COL_FILE"
c3_out=$(PATH="$ID_SHIM:$PATH" id_new "no-collision"); c3_rc=$?
{ [ "$c3_rc" = 0 ] && echo "$c3_out" | grep -q "Created task: $COL_ID" && [ "$(jq -r .name "$COL_FILE")" = "no-collision" ]; } \
  || ex_bad="$ex_bad [control rc=$c3_rc out=$c3_out]"
# a second creation of the same id after the control is now refused, original intact
PATH="$ID_SHIM:$PATH" id_new "collides-again" >/dev/null; c4_rc=$?
{ [ "$c4_rc" != 0 ] && [ "$(jq -r .name "$COL_FILE")" = "no-collision" ]; } || ex_bad="$ex_bad [recollide rc=$c4_rc name=$(jq -r .name "$COL_FILE" 2>/dev/null)]"
rm_shim
# the library write: "create" refuses an existing target; the default replace path still updates
lw=$(SESSION_SCHEDULER_HOME="$ID_HOME" bash -c '
  source "$1"; id=lib-excl-1
  task_write "$id" "{\"id\":\"$id\",\"v\":1}" create; echo "FIRST=$?"
  task_write "$id" "{\"id\":\"$id\",\"v\":2}" create 2>/dev/null; echo "SECOND=$?"
  echo "AFTER_CREATE=$(jq -r .v "$(task_path "$id")")"
  task_write "$id" "{\"id\":\"$id\",\"v\":3}"; echo "UPDATE=$?"
  echo "AFTER_UPDATE=$(jq -r .v "$(task_path "$id")")"' _ "$HERE/lib.sh")
{ echo "$lw" | grep -qx 'FIRST=0' && echo "$lw" | grep -qx 'SECOND=1' && echo "$lw" | grep -qx 'AFTER_CREATE=1' \
  && echo "$lw" | grep -qx 'UPDATE=0' && echo "$lw" | grep -qx 'AFTER_UPDATE=3'; } || ex_bad="$ex_bad [lib $lw]"
if [ -z "$ex_bad" ]; then
  pass "task_new_exclusive_create_refuses_collision"
else
  fail "task_new_exclusive_create_refuses_collision" "$ex_bad"
fi

# --- Review fixes R3/R5 (scheduler) ---
# R3: a failing od with plausible output must not yield a task id, whatever the
#     caller's pipefail setting; control: the same output with exit 0 is accepted.
r3s_bad=""
od_shim 'printf " de ad be ef\n"; exit 1'
before=$(id_count)
r3a_out=$(PATH="$ID_SHIM:$PATH" id_new "failing-od"); r3a_rc=$?
lg=$(PATH="$ID_SHIM:$PATH" bash -c 'source "$1"; id=$(generate_task_id); echo "$?|$id"' _ "$HERE/lib.sh")
{ [ "$r3a_rc" != 0 ] && ! echo "$r3a_out" | grep -q 'Created task:' && echo "$r3a_out" | grep -q 'could not generate a task id' \
  && [ "$(id_count)" = "$before" ] && [ "$lg" = "1|" ]; } || r3s_bad="$r3s_bad [failing-od rc=$r3a_rc out=$r3a_out lib=$lg]"
od_shim 'printf " de ad be ef\n"; exit 0'
r3b_out=$(PATH="$ID_SHIM:$PATH" id_new "ok-od"); r3b_rc=$?
lg=$(PATH="$ID_SHIM:$PATH" bash -c 'source "$1"; id=$(generate_task_id); echo "$?|$id"' _ "$HERE/lib.sh")
{ [ "$r3b_rc" = 0 ] && echo "$r3b_out" | grep -qE 'Created task: task-[0-9]+-deadbeef$' && [[ "$lg" =~ ^0\|task-[0-9]+-deadbeef$ ]]; } \
  || r3s_bad="$r3s_bad [control rc=$r3b_rc out=$r3b_out lib=$lg]"
rm_shim
if [ -z "$r3s_bad" ]; then
  pass "task_new_failing_od_with_output_fails_closed"
else
  fail "task_new_failing_od_with_output_fails_closed" "$r3s_bad"
fi

# R5: task creation never exposes an empty/partial/multi-link file at the final
#     path, never replaces, and is exclusive among concurrent creators.
#     Crash instrumentation is EXTERNAL to the code under test: BASH_ENV loads a
#     DEBUG trap (set -T, so functions inherit it) that SIGKILLs the shell when
#     task_write reaches a chosen boundary, recognised only by BASH_COMMAND:
#       before-fill      the command that writes the JSON content to a file
#       before-publish   the mv/ln that publishes it under its final name
#       after-publish    the first command run after that mv/ln
#     It records the boundary in a marker file, then SIGKILLs the whole process
#     group. Each trial runs task-new as the leader of its own session via python
#     (start_new_session), whose returncode of -9 is the proof of death by SIGKILL;
#     the trial also needs the marker, or it is reported as not proven.
R5_TRAP="$TMP/r5-crash-trap.sh"
cat > "$R5_TRAP" <<'TRAP'
set -T
__r5_after=0
__r5_kill() {
  case " ${FUNCNAME[*]} " in *" task_write "*) ;; *) return 0 ;; esac
  local c="$BASH_COMMAND" hit=""
  if [ "$__r5_after" = 1 ]; then hit=after-publish
  else
    case "$c" in
      'printf '*'$json'*'>'*) hit=before-fill ;;   # bash may print a redirect as 1>&3
      'mv '*|'ln '*) __r5_after=1; hit=before-publish ;;
    esac
  fi
  if [ -n "$hit" ] && [ "$hit" = "${R5_CRASH_AT:-}" ]; then
    printf '%s\n' "$hit" > "$R5_MARK"
    kill -KILL 0   # the whole process group: the shell and any subshell it is running in
  fi
  return 0
}
[ -n "${R5_CRASH_AT:-}" ] && trap '__r5_kill' DEBUG
TRAP
R5_ID="task-1700000002-0badf00d"
od_shim 'printf " 0b ad f0 0d\n"'
printf '#!/bin/sh\nif [ "$1" = "+%%s" ]; then echo 1700000002; else exec %s "$@"; fi\n' "$REAL_DATE" > "$ID_SHIM/date"; chmod +x "$ID_SHIM/date"
r5_nlink() { stat -c '%h' "$1" 2>/dev/null || stat -f '%l' "$1" 2>/dev/null; }
r5_home() { cd -P "$(mktemp -d "$TMP/r5-home.XXXXXX")" && pwd -P; }
r5_tmp_count() { find "$1/tasks" -maxdepth 1 -name '*.tmp.*' 2>/dev/null | wc -l | tr -d ' '; }
# r5_invariant <home>: final path absent, OR complete valid JSON with link count 1;
# both readers keep working (the contract reader must get PAST the file checks).
r5_invariant() {
  local home="$1" f="$1/tasks/$R5_ID.json" out
  if [ -e "$f" ] || [ -L "$f" ]; then
    [ -f "$f" ] && [ ! -L "$f" ] || { echo "not-regular"; return 1; }
    [ "$(r5_nlink "$f")" = 1 ] || { echo "nlink=$(r5_nlink "$f")"; return 1; }
    jq -e --arg id "$R5_ID" 'type == "object" and .id == $id' "$f" >/dev/null 2>&1 || { echo "partial-or-invalid-json(size=$(wc -c < "$f" | tr -d ' '))"; return 1; }
    out=$(SESSION_SCHEDULER_HOME="$home" python3 -B "$HERE/task-contract.py" inspect "$R5_ID" 2>&1)
    echo "$out" | grep -q 'missing or unsupported contract' || { echo "contract-reader: $out"; return 1; }
  fi
  SESSION_SCHEDULER_HOME="$home" bash "$HERE/task-status.sh" --all >/dev/null 2>&1 || { echo "task-status-failed"; return 1; }
  return 0
}
r5_bad=""
for boundary in before-fill before-publish after-publish; do
  th=$(r5_home); mark="$th/crash.mark"
  rc=$(PATH="$ID_SHIM:$PATH" SESSION_SCHEDULER_HOME="$th" BASH_ENV="$R5_TRAP" R5_CRASH_AT="$boundary" R5_MARK="$mark" \
    python3 -B -I -c 'import subprocess, sys
print(subprocess.run(sys.argv[1:], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode)' \
    bash "$HERE/task-new.sh" crashes 2>/dev/null)
  if [ "$rc" != -9 ] || [ "$(cat "$mark" 2>/dev/null)" != "$boundary" ]; then
    r5_bad="$r5_bad [$boundary: SIGKILL not proven rc=$rc mark=$(cat "$mark" 2>/dev/null)]"; continue
  fi
  inv=$(r5_invariant "$th") || r5_bad="$r5_bad [$boundary: invariant violated after proven SIGKILL: $inv]"
  # recovery: a plain creation afterwards still works when the id is not taken (a stale lock is reclaimed)
  if [ ! -e "$th/tasks/$R5_ID.json" ]; then
    rec=$(PATH="$ID_SHIM:$PATH" SESSION_SCHEDULER_HOME="$th" bash "$HERE/task-new.sh" "recovers" 2>&1) \
      && echo "$rec" | grep -q 'Created task:' || r5_bad="$r5_bad [$boundary: recovery failed: $rec]"
  fi
done
# control: the same trap loaded but never armed (no R5_CRASH_AT) = uninstrumented normal creation
th=$(r5_home)
nc_out=$(PATH="$ID_SHIM:$PATH" SESSION_SCHEDULER_HOME="$th" bash "$HERE/task-new.sh" "normal" 2>&1); nc_rc=$?
{ [ "$nc_rc" = 0 ] && echo "$nc_out" | grep -q "Created task: $R5_ID" && r5_invariant "$th" >/dev/null && [ "$(jq -r .name "$th/tasks/$R5_ID.json")" = normal ] \
  && [ "$(r5_tmp_count "$th")" = 0 ] && [ ! -e "$th/locks/$R5_ID.lock" ]; } || r5_bad="$r5_bad [normal creation rc=$nc_rc out=$nc_out]"
# forced collision: refused, existing bytes identical, no temp, lock released (file, symlink and directory forms)
cp "$th/tasks/$R5_ID.json" "$th/before.json"
co_out=$(PATH="$ID_SHIM:$PATH" SESSION_SCHEDULER_HOME="$th" bash "$HERE/task-new.sh" "collides" 2>&1); co_rc=$?
{ [ "$co_rc" != 0 ] && echo "$co_out" | grep -q 'already exists' && ! echo "$co_out" | grep -q 'Created task:' && cmp -s "$th/tasks/$R5_ID.json" "$th/before.json" \
  && [ "$(r5_tmp_count "$th")" = 0 ] && [ ! -e "$th/locks/$R5_ID.lock" ]; } || r5_bad="$r5_bad [collision rc=$co_rc out=$co_out]"
rm -f "$th/tasks/$R5_ID.json"; ln -s "$th/elsewhere.json" "$th/tasks/$R5_ID.json"
PATH="$ID_SHIM:$PATH" SESSION_SCHEDULER_HOME="$th" bash "$HERE/task-new.sh" "collides-symlink" >/dev/null 2>&1; cs_rc=$?
{ [ "$cs_rc" != 0 ] && [ -L "$th/tasks/$R5_ID.json" ] && [ ! -e "$th/elsewhere.json" ] && [ "$(r5_tmp_count "$th")" = 0 ] && [ ! -e "$th/locks/$R5_ID.lock" ]; } || r5_bad="$r5_bad [symlink collision rc=$cs_rc]"
rm -f "$th/tasks/$R5_ID.json"; mkdir "$th/tasks/$R5_ID.json"
PATH="$ID_SHIM:$PATH" SESSION_SCHEDULER_HOME="$th" bash "$HERE/task-new.sh" "collides-dir" >/dev/null 2>&1; cd_rc=$?
{ [ "$cd_rc" != 0 ] && [ -z "$(ls -A "$th/tasks/$R5_ID.json")" ] && [ "$(r5_tmp_count "$th")" = 0 ] && [ ! -e "$th/locks/$R5_ID.lock" ]; } || r5_bad="$r5_bad [dir collision rc=$cd_rc]"
# the same collision refusal at the library boundary (independent of id generation)
lh=$(r5_home); mkdir -p "$lh/tasks" "$lh/locks"; chmod 700 "$lh" "$lh/tasks" "$lh/locks"
printf '{"id":"lib-col","keep":true}\n' > "$lh/tasks/lib-col.json"; cp "$lh/tasks/lib-col.json" "$lh/lib-before.json"
lc_out=$(SESSION_SCHEDULER_HOME="$lh" bash -c 'source "$1"; task_write lib-col "{\"id\":\"lib-col\",\"keep\":false}" create' _ "$HERE/lib.sh" 2>&1); lc_rc=$?
SESSION_SCHEDULER_HOME="$lh" bash -c 'source "$1"; task_write lib-free "{\"id\":\"lib-free\"}" create' _ "$HERE/lib.sh" >/dev/null 2>&1; lf_rc=$?
{ [ "$lc_rc" != 0 ] && echo "$lc_out" | grep -q 'already exists' && cmp -s "$lh/tasks/lib-col.json" "$lh/lib-before.json" && [ "$(r5_tmp_count "$lh")" = 0 ] \
  && [ ! -e "$lh/locks/lib-col.lock" ] && [ "$lf_rc" = 0 ] && [ "$(r5_nlink "$lh/tasks/lib-free.json")" = 1 ] && jq -e '.id == "lib-free"' "$lh/tasks/lib-free.json" >/dev/null 2>&1; } \
  || r5_bad="$r5_bad [lib collision rc=$lc_rc out=$lc_out free_rc=$lf_rc]"
# concurrent creators of the SAME id: exactly one wins, its bytes survive, the loser fails cleanly
for round in 1 2 3 4 5 6; do
  th=$(r5_home); mkdir -p "$th/tasks" "$th/locks"; chmod 700 "$th" "$th/tasks" "$th/locks"
  go="$th/go"; cid="conc-$round"
  for who in A B; do
    ( until [ -e "$go" ]; do :; done
      SESSION_SCHEDULER_HOME="$th" bash -c 'source "$1"; task_write "$2" "$3" create' _ "$HERE/lib.sh" "$cid" "{\"id\":\"$cid\",\"who\":\"$who\"}" >"$th/out.$who" 2>&1
      echo $? > "$th/rc.$who" ) &
  done
  sleep 0.2; touch "$go"; wait
  wins=0; [ "$(cat "$th/rc.A")" = 0 ] && wins=$((wins + 1)); [ "$(cat "$th/rc.B")" = 0 ] && wins=$((wins + 1))
  winner=$(jq -r .who "$th/tasks/$cid.json" 2>/dev/null)
  { [ "$wins" = 1 ] && [ "$(cat "$th/rc.$winner")" = 0 ] && [ "$(cat "$th/tasks/$cid.json")" = "{\"id\":\"$cid\",\"who\":\"$winner\"}" ] \
    && [ "$(r5_nlink "$th/tasks/$cid.json")" = 1 ] && [ "$(r5_tmp_count "$th")" = 0 ] && [ ! -e "$th/locks/$cid.lock" ] \
    && grep -q 'already exists' "$th/out.$([ "$winner" = A ] && echo B || echo A)"; } \
    || r5_bad="$r5_bad [concurrent round $round: wins=$wins winner=$winner rcA=$(cat "$th/rc.A") rcB=$(cat "$th/rc.B") loser=$(cat "$th/out.$([ "$winner" = A ] && echo B || echo A)" 2>/dev/null)]"
done
rm_shim
if [ -z "$r5_bad" ]; then
  pass "task_create_crash_safe_exclusive_and_concurrent"
else
  fail "task_create_crash_safe_exclusive_and_concurrent" "$r5_bad"
fi

# --- Tier 1.2b-min: one complete verdict event (--note-file) ---
# Fixture: a hybrid session-chat root. The REAL lib.sh, get-my-name.sh and
# own-draft-check.sh are copied from the session-chat source tree next to
# stubbed dispatch/send scripts (recording every call) and a version manifest.
# Identity comes from SESSION_CHAT_PANE_NAME, the mailbox from
# SESSION_CHAT_TARGET_MESSAGES_DIR. Only the reviewer's own draft is eligible.
VD_ROOT="$(cd "$TMP" && pwd -P)/vd"; mkdir -p "$VD_ROOT"
VD_CHAT_SRC="$HERE/../../session-chat/scripts"
VD_HOME="$VD_ROOT/scheduler"; mkdir -p "$VD_HOME"
VD_MSGS="$VD_ROOT/messages"; VD_LOG="$VD_ROOT/log"; mkdir -p "$VD_LOG"
mkdir -p "$VD_MSGS/drafts/reviewer-1" "$VD_MSGS/drafts/other-1"
chmod 700 "$VD_MSGS" "$VD_MSGS/drafts" "$VD_MSGS/drafts/reviewer-1" "$VD_MSGS/drafts/other-1"
vd_chat_root() { # vd_chat_root <dir> [with-helper|no-helper]
  local d="$1"
  mkdir -p "$d/scripts" "$d/.claude-plugin"
  printf '{ "name": "session-chat", "version": "0.17.0" }\n' > "$d/.claude-plugin/plugin.json"
  cp "$VD_CHAT_SRC/lib.sh" "$d/scripts/" 2>/dev/null
  # Identity stub: the real get-my-name.sh needs tmux; the real lib.sh (used by
  # own-draft-check.sh) honours the same SESSION_CHAT_PANE_NAME.
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "${SESSION_CHAT_PANE_NAME:-}"' > "$d/scripts/get-my-name.sh"
  [ "${2:-with-helper}" = with-helper ] && cp "$VD_CHAT_SRC/own-draft-check.sh" "$d/scripts/" 2>/dev/null
  cat > "$d/scripts/dispatch-to-session.sh" <<'STUB'
#!/usr/bin/env bash
# Recording stub. VD_MODE: delivered | queued | queued3 | fail.
n=$(( $(ls "$VD_LOG"/dispatch-*.md 2>/dev/null | wc -l) + 1 ))
cp "$2" "$VD_LOG/dispatch-$n.md"; echo "$1" >> "$VD_LOG/dispatch.log"
[ -n "${VD_MUTATE:-}" ] && printf 'edited\n' >> "$VD_MUTATE"
if [ -n "${VD_REPLACE:-}" ]; then printf 'replaced body\n' > "$VD_REPLACE.new"; mv -f "$VD_REPLACE.new" "$VD_REPLACE"; fi
[ -n "${VD_ERR_OUT:-}" ] && printf '%s\n' "$VD_ERR_OUT" >&2
case "${VD_MODE:-delivered}" in
  delivered) echo "Dispatched task to '$1'"; [ -n "${VD_ID_OUT-x}" ] && printf '%s\n' "${VD_ID_OUT-Message id: aaaaaaaaaaaaaaaa}"; exit 0 ;;
  queued)    echo "Queued dispatch to '$1' — recipient was busy; it will arrive on their next turn."; echo "Message id: bbbbbbbbbbbbbbbb"; exit 0 ;;
  queued3)   echo "Message id: cccccccccccccccc"; exit 3 ;;
  *)         echo "stub hard failure" >&2; exit 1 ;;
esac
STUB
  cat > "$d/scripts/send-message.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "$VD_LOG/send.log"
exit "${VD_SEND_RC:-0}"
STUB
  chmod 644 "$d/scripts"/*.sh
}
VD_CHAT="$VD_ROOT/chat"; vd_chat_root "$VD_CHAT" with-helper
VD_CHAT_NOHELPER="$VD_ROOT/chat-old"; vd_chat_root "$VD_CHAT_NOHELPER" no-helper
VD_CHAT_NOID="$VD_ROOT/chat-noid"; vd_chat_root "$VD_CHAT_NOID" with-helper
VD_SCRIPTS="${VD_SCRIPTS:-$HERE}"
vd() { # vd <pane> <script> args... (clean per-call environment; extra settings via env prefix on the call)
  local pane="$1" script="$2"; shift 2
  SESSION_SCHEDULER_HOME="$VD_HOME" SESSION_CHAT_ROOT_OVERRIDE="${VD_CHAT_USE:-$VD_CHAT}" SESSION_CHAT_PANE_NAME="$pane" \
    SESSION_CHAT_TARGET_MESSAGES_DIR="$VD_MSGS" VD_LOG="$VD_LOG" bash "$VD_SCRIPTS/$script" "$@"
}
vd_task() { # vd_task [assigned|review] -> prints the id of a fresh task (assigner master-1, reviewer reviewer-1)
  local id
  id=$(vd master-1 task-new.sh "vd-task" --reviewer reviewer-1 2>&1 | awk '/Created task:/ {print $3}')
  vd master-1 task-assign.sh executor-1 "$id" "do it" >/dev/null 2>&1
  [ "${1:-assigned}" = review ] && vd executor-1 task-review.sh "$id" "sha abc" >/dev/null 2>&1
  printf '%s' "$id"
}
vd_draft() { # vd_draft <pane> <name> <content> -> path
  local f="$VD_MSGS/drafts/$1/$2"
  printf '%s' "$3" > "$f"; printf '%s' "$f"
}
vd_tf() { printf '%s/tasks/%s.json' "$VD_HOME" "$1"; }
vd_artifacts() { local n=0 f; for f in "$VD_HOME/prompts/$1"-verdict-????????????????.md; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
# shellcheck disable=SC2163  # each argument is a VAR=value assignment to export
vd_env_export() { local a; for a in "$@"; do export "$a"; done; }
vd_ndisp() { [ -e "$VD_LOG/dispatch.log" ] && wc -l < "$VD_LOG/dispatch.log" | tr -d ' '; return 0; }
vd_reset_log() { rm -f "$VD_LOG"/dispatch-*.md "$VD_LOG/dispatch.log" "$VD_LOG/send.log"; }
vd_sha() { shasum -a 256 < "$1" | awk '{print $1}'; }
vd_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
vd_unchanged() { # vd_unchanged <id> <status>: not transitioned, no event, no artifact, nothing sent
  [ "$(jq -r .status "$(vd_tf "$1")")" = "$2" ] && [ "$(jq -r '(.meta.verdict_events // {}) | length' "$(vd_tf "$1")")" = 0 ] \
    && [ "$(vd_artifacts "$1")" = 0 ] && [ ! -e "$VD_LOG/dispatch.log" ] && [ ! -e "$VD_LOG/send.log" ]
}
# Multi-line, non-ASCII body whose first line is far beyond the 200-byte excerpt bound.
VD_LINE1=$(printf 'Verdict-é%.0s' $(seq 1 60))
VD_BODY=$(printf '%s\nsecond line: $(touch %s/PWNED) `id`\n\nthird paragraph — ünïcode ✓\n' "$VD_LINE1" "$VD_ROOT")

# V1-V3: ordinary done and block record ONE event atomically with the transition,
# keep the full body in a digest-bound 0600 artifact, send ONE [task][event]
# notification with the full body and no [re:] token, and consume the draft.
vd_reset_log
VD_ID=$(vd_task review)
VD_R=$(jq -r '.meta.review_request_msg_id' "$(vd_tf "$VD_ID")")
VD_DRAFT=$(vd_draft reviewer-1 done-1.md "$VD_BODY")
VD_DRAFT_SHA=$(vd_sha "$VD_DRAFT")
vd_reset_log
vd_done_out=$(vd reviewer-1 task-done.sh "$VD_ID" --note-file "$VD_DRAFT" 2>&1); vd_done_rc=$?
VD_F=$(vd_tf "$VD_ID")
VD_EV=$(jq -r '.meta.verdict_events | keys[0]' "$VD_F")
VD_ART="$VD_HOME/prompts/$VD_ID-verdict-$VD_EV.md"
vd_hist=$(jq -r '.history[-1].note' "$VD_F")
vd_excerpt="${vd_hist%% (verdict *}"
vd_bad=""
[ "$vd_done_rc" = 0 ] || vd_bad="$vd_bad [rc=$vd_done_rc out=$vd_done_out]"
[ "$(jq -r .status "$VD_F")" = "done" ] && [ "$(jq -r '.meta.verdict_events | length' "$VD_F")" = 1 ] || vd_bad="$vd_bad [status/event count]"
[[ "$VD_EV" =~ ^[a-f0-9]{16}$ ]] || vd_bad="$vd_bad [event id $VD_EV]"
[ -f "$VD_ART" ] && [ "$(vd_mode "$VD_ART")" = 600 ] && [ "$(vd_sha "$VD_ART")" = "$VD_DRAFT_SHA" ] && cmp -s "$VD_ART" <(printf '%s' "$VD_BODY") \
  || vd_bad="$vd_bad [artifact/sha/mode]"
jq -e --arg ev "$VD_EV" --arg art "$VD_ART" --arg sha "$VD_DRAFT_SHA" --arg r "$VD_R" '
  .meta.verdict_events[$ev] | .schema == 1 and .event_id == $ev and .transition == "done" and .actor == "reviewer-1"
  and .route_to == "master-1" and .request_msg_id == $r and .generation == null and .artifact == $art and .artifact_sha256 == $sha
  and (.created_at | length) > 0 and .notification.state == "delivered"' "$VD_F" >/dev/null 2>&1 || vd_bad="$vd_bad [event record: $(jq -c ".meta.verdict_events" "$VD_F")]"
[ "$VD_R" = "aaaaaaaaaaaaaaaa" ] || vd_bad="$vd_bad [request id $VD_R]"
# bounded excerpt (<=200 bytes, valid UTF-8, from line 1) plus the artifact pointer
[ "${#vd_excerpt}" -gt 0 ] && [ "$(printf '%s' "$vd_excerpt" | wc -c | tr -d ' ')" -le 200 ] && printf '%s' "$vd_excerpt" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 \
  && [[ "$VD_LINE1" == "${vd_excerpt%...}"* ]] && [ "$vd_hist" = "$vd_excerpt (verdict $VD_ART sha256:$VD_DRAFT_SHA)" ] || vd_bad="$vd_bad [history note: $vd_hist]"
# exactly one notification, to the assigner, with the full body; no [re:]; no inline send
[ "$(wc -l < "$VD_LOG/dispatch.log" | tr -d ' ')" = 1 ] && [ "$(cat "$VD_LOG/dispatch.log")" = master-1 ] || vd_bad="$vd_bad [dispatch count]"
VD_N="$VD_LOG/dispatch-1.md"
[[ "$(head -1 "$VD_N")" == "[task:$VD_ID] [event:$VD_EV] Verdict-é"* ]] && [ -z "$(sed -n 2p "$VD_N")" ] \
  && grep -qF 'second line: $(touch' "$VD_N" && grep -qF 'third paragraph — ünïcode ✓' "$VD_N" \
  && grep -qF "task-status $VD_ID" "$VD_N" && ! grep -qF '[re:' "$VD_N" && [ ! -e "$VD_LOG/send.log" ] || vd_bad="$vd_bad [notification body: $(head -3 "$VD_N")]"
[ ! -e "$VD_ROOT/PWNED" ] || vd_bad="$vd_bad [body executed]"
# the draft was consumed after the commit
[ ! -e "$VD_DRAFT" ] && echo "$vd_done_out" | grep -qF "Removed delivered draft" || vd_bad="$vd_bad [draft not consumed: $vd_done_out]"
# a rerun of task-done is refused as today: no replay, no second event or notification
vd_reset_log; VD_DRAFT2=$(vd_draft reviewer-1 done-2.md "second try")
vd reviewer-1 task-done.sh "$VD_ID" --note-file "$VD_DRAFT2" >/dev/null 2>&1; vd_rr=$?
{ [ "$vd_rr" != 0 ] && [ "$(jq -r '.meta.verdict_events | length' "$VD_F")" = 1 ] && [ "$(vd_artifacts "$VD_ID")" = 1 ] && [ ! -e "$VD_LOG/dispatch.log" ] && [ -f "$VD_DRAFT2" ]; } \
  || vd_bad="$vd_bad [rerun not refused cleanly rc=$vd_rr]"
rm -f "$VD_DRAFT2"
if [ -z "$vd_bad" ]; then pass "verdict_note_file_done_records_event_artifact_and_one_notification"
else fail "verdict_note_file_done_records_event_artifact_and_one_notification" "$vd_bad"; fi

# task-block --note-file: same event shape (transition blocked, same route), no [re:].
vd_reset_log
VD_ID=$(vd_task review); vd_reset_log
VD_DRAFT=$(vd_draft reviewer-1 block-1.md $'Rejected: missing tests\nDetail line two\n')
vd_blk_out=$(vd reviewer-1 task-block.sh "$VD_ID" --note-file "$VD_DRAFT" 2>&1); vd_blk_rc=$?
VD_F=$(vd_tf "$VD_ID"); VD_EV=$(jq -r '.meta.verdict_events | keys[0]' "$VD_F")
vd_bad=""
{ [ "$vd_blk_rc" = 0 ] && [ "$(jq -r .status "$VD_F")" = blocked ] && [ "$(jq -r '.meta.verdict_events | length' "$VD_F")" = 1 ]; } || vd_bad="$vd_bad [rc=$vd_blk_rc out=$vd_blk_out]"
jq -e --arg ev "$VD_EV" '.meta.verdict_events[$ev] | .transition == "blocked" and .route_to == "master-1" and .notification.state == "delivered" and .request_msg_id == "aaaaaaaaaaaaaaaa"' "$VD_F" >/dev/null 2>&1 || vd_bad="$vd_bad [event]"
[ "$(jq -r '.history[-1].note' "$VD_F")" = "Rejected: missing tests (verdict $VD_HOME/prompts/$VD_ID-verdict-$VD_EV.md sha256:$(vd_sha "$VD_HOME/prompts/$VD_ID-verdict-$VD_EV.md"))" ] || vd_bad="$vd_bad [history]"
{ [ "$(wc -l < "$VD_LOG/dispatch.log" | tr -d ' ')" = 1 ] && [[ "$(head -1 "$VD_LOG/dispatch-1.md")" == "[task:$VD_ID] [event:$VD_EV] Rejected: missing tests" ]] \
  && grep -qF 'Detail line two' "$VD_LOG/dispatch-1.md" && ! grep -qF '[re:' "$VD_LOG/dispatch-1.md" && [ ! -d "$VD_DRAFT" ] && [ ! -e "$VD_DRAFT" ]; } || vd_bad="$vd_bad [notification/draft]"
# an inline note given with --note-file replaces only the history excerpt; the full file is still the body
VD_ID=$(vd_task assigned); vd_reset_log
VD_DRAFT=$(vd_draft reviewer-1 block-2.md $'FILE BODY first line\nmore\n')
vd reviewer-1 task-block.sh "$VD_ID" --note-file "$VD_DRAFT" "short summary" >/dev/null 2>&1; vd_il_rc=$?
{ [ "$vd_il_rc" = 0 ] && jq -r '.history[-1].note' "$(vd_tf "$VD_ID")" | grep -q '^short summary (verdict ' && grep -qF 'FILE BODY first line' "$VD_LOG/dispatch-1.md" && grep -qF 'more' "$VD_LOG/dispatch-1.md"; } || vd_bad="$vd_bad [inline+file rc=$vd_il_rc]"
if [ -z "$vd_bad" ]; then pass "verdict_note_file_block_records_event_and_notification"
else fail "verdict_note_file_block_records_event_and_notification" "$vd_bad"; fi

# V3 queued: a durable queued outcome (real dispatch prints "Queued dispatch" and
# exits 0; a defensive rc 3 is also accepted) is recorded as queued, with no
# inline fallback and no resend. The delivered case above is the control.
vd_bad=""
for variant in queued queued3; do
  VD_ID=$(vd_task review); vd_reset_log
  VD_DRAFT=$(vd_draft reviewer-1 q-$variant.md "queued verdict ($variant)")
  VD_MODE=$variant vd reviewer-1 task-done.sh "$VD_ID" --note-file "$VD_DRAFT" >/dev/null 2>&1; q_rc=$?
  VD_F=$(vd_tf "$VD_ID")
  { [ "$q_rc" = 0 ] && [ "$(jq -r '.meta.verdict_events | to_entries[0].value.notification.state' "$VD_F")" = queued ] \
    && [ "$(wc -l < "$VD_LOG/dispatch.log" | tr -d ' ')" = 1 ] && [ ! -e "$VD_LOG/send.log" ] && [ ! -e "$VD_DRAFT" ]; } \
    || vd_bad="$vd_bad [$variant rc=$q_rc state=$(jq -c '.meta.verdict_events' "$VD_F") dispatches=$(cat "$VD_LOG/dispatch.log" 2>/dev/null | wc -l) send=$([ -e "$VD_LOG/send.log" ] && echo yes)]"
done
if [ -z "$vd_bad" ]; then pass "verdict_notification_queued_recorded_without_fallback"
else fail "verdict_notification_queued_recorded_without_fallback" "$vd_bad"; fi

# V3 hard failure: durable dispatch fails -> ONE bounded inline pointer
# (<= SESSION_CHAT_SEND_MAX_LEN) naming the event and the task-status recovery;
# outcome inline-fallback. If the inline send fails too the outcome is failed and
# the transition stays committed (partial-success warning). Delivered = control.
vd_bad=""
VD_ID=$(vd_task review); vd_reset_log
VD_LONG=$(printf 'LongLine-é%.0s' $(seq 1 80))
VD_DRAFT=$(vd_draft reviewer-1 hardfail.md "$VD_LONG"$'\nbody continues\n')
hf_out=$(VD_MODE=fail SESSION_CHAT_SEND_MAX_LEN=300 vd reviewer-1 task-done.sh "$VD_ID" --note-file "$VD_DRAFT" 2>&1); hf_rc=$?
VD_F=$(vd_tf "$VD_ID"); VD_EV=$(jq -r '.meta.verdict_events | keys[0]' "$VD_F")
hf_ptr=$(cat "$VD_LOG/send.log" 2>/dev/null)
{ [ "$hf_rc" = 0 ] && [ "$(jq -r .status "$VD_F")" = "done" ] && [ "$(jq -r ".meta.verdict_events[\"$VD_EV\"].notification.state" "$VD_F")" = inline-fallback ] \
  && [ "$(wc -l < "$VD_LOG/send.log" | tr -d ' ')" = 1 ] && [ "$(printf '%s' "$hf_ptr" | wc -c | tr -d ' ')" -le 300 ] \
  && [[ "$hf_ptr" == "[task:$VD_ID] [event:$VD_EV] LongLine-é"* ]] && [[ "$hf_ptr" == *" — full verdict recorded: task-status $VD_ID" ]] \
  && ! printf '%s' "$hf_ptr" | grep -qF 'body continues' && echo "$hf_out" | grep -qi 'duplicate pointer is possible' && [ ! -e "$VD_DRAFT" ]; } \
  || vd_bad="$vd_bad [pointer rc=$hf_rc state=$(jq -c '.meta.verdict_events' "$VD_F") ptr=$hf_ptr out=$hf_out]"
VD_ID=$(vd_task review); vd_reset_log
VD_DRAFT=$(vd_draft reviewer-1 hardfail2.md "both transports fail")
hf2_out=$(VD_MODE=fail VD_SEND_RC=1 vd reviewer-1 task-done.sh "$VD_ID" --note-file "$VD_DRAFT" 2>&1); hf2_rc=$?
VD_F=$(vd_tf "$VD_ID")
{ [ "$hf2_rc" = 0 ] && [ "$(jq -r .status "$VD_F")" = "done" ] && [ "$(jq -r '.meta.verdict_events | to_entries[0].value.notification.state' "$VD_F")" = failed ] \
  && echo "$hf2_out" | grep -q 'partial success' && echo "$hf2_out" | grep -q 'Do NOT rerun task-done'; } \
  || vd_bad="$vd_bad [both-fail rc=$hf2_rc out=$hf2_out]"
if [ -z "$vd_bad" ]; then pass "verdict_hard_dispatch_failure_bounded_pointer_fallback"
else fail "verdict_hard_dispatch_failure_bounded_pointer_fallback" "$vd_bad"; fi

# V2: every note-file refusal happens BEFORE any transition: the task is untouched,
# no artifact, no notification, the draft stays. Each refusal case is followed by a
# valid own draft on a fresh task in the same fixture (the positive control).
vd_bad=""
vd_refuse() { # vd_refuse <label> <path> [VAR=val ...]: run task-done --note-file on a fresh task
  local label="$1" path="$2" id out rc; shift 2
  id=$(vd_task assigned); vd_reset_log
  out=$( ( vd_env_export "$@"; vd reviewer-1 task-done.sh "$id" --note-file "$path" ) 2>&1 ); rc=$?
  VD_LAST_OUT="$out"; VD_LAST_ID="$id"; VD_LAST_RC="$rc"
}
vd_control() { # vd_control <label>: a valid own draft completes a fresh task in the same fixture
  local id out rc f
  id=$(vd_task assigned); vd_reset_log
  f=$(vd_draft reviewer-1 "control-$1.md" "valid control for $1")
  out=$(vd reviewer-1 task-done.sh "$id" --note-file "$f" 2>&1); rc=$?
  { [ "$rc" = 0 ] && [ "$(jq -r .status "$(vd_tf "$id")")" = "done" ] && [ "$(vd_artifacts "$id")" = 1 ] && [ ! -e "$f" ]; } \
    || vd_bad="$vd_bad [$1: control failed rc=$rc out=$out]"
}
vd_expect_refused() { # vd_expect_refused <label> [reason-regex]
  { [ "$VD_LAST_RC" != 0 ] && vd_unchanged "$VD_LAST_ID" assigned; } \
    || vd_bad="$vd_bad [$1: rc=$VD_LAST_RC status=$(jq -r .status "$(vd_tf "$VD_LAST_ID")") events=$(jq -c '.meta.verdict_events // {}' "$(vd_tf "$VD_LAST_ID")") artifacts=$(vd_artifacts "$VD_LAST_ID") out=$VD_LAST_OUT]"
  if [ -n "${2:-}" ] && ! printf '%s' "$VD_LAST_OUT" | grep -qE "$2"; then vd_bad="$vd_bad [$1: reason mismatch: $VD_LAST_OUT]"; fi
}
# foreign pane draft
F=$(vd_draft other-1 foreign.md "foreign body"); vd_refuse foreign "$F"; vd_expect_refused foreign 'not an eligible own draft'
[ -f "$F" ] || vd_bad="$vd_bad [foreign draft removed]"; vd_control foreign
# symlink to a valid own draft
T=$(vd_draft reviewer-1 link-target.md "target body"); ln -s "$T" "$VD_MSGS/drafts/reviewer-1/link.md"
vd_refuse symlink "$VD_MSGS/drafts/reviewer-1/link.md"; vd_expect_refused symlink 'not an eligible own draft'
[ -f "$T" ] || vd_bad="$vd_bad [symlink target removed]"; rm -f "$VD_MSGS/drafts/reviewer-1/link.md" "$T"; vd_control symlink
# hardlinked draft
H=$(vd_draft reviewer-1 hard.md "hard body"); ln "$H" "$VD_ROOT/hard-other.md"
vd_refuse hardlink "$H"; vd_expect_refused hardlink 'not an eligible own draft'
rm -f "$H" "$VD_ROOT/hard-other.md"; vd_control hardlink
# file outside the drafts directory, and a bad draft name
O=$(printf 'outside body' > "$VD_ROOT/outside.md"; printf '%s' "$VD_ROOT/outside.md")
vd_refuse outside "$O"; vd_expect_refused outside 'not an eligible own draft'; rm -f "$O"; vd_control outside
B=$(vd_draft reviewer-1 bad-name.sh "bad name"); vd_refuse badname "$B"; vd_expect_refused badname 'not an eligible own draft'; rm -f "$B"; vd_control badname
# unreadable draft (mode 000: the digest cannot be taken, so the check refuses)
U=$(vd_draft reviewer-1 unreadable.md "unreadable body"); chmod 000 "$U"
vd_refuse unreadable "$U"; vd_expect_refused unreadable; chmod 600 "$U"; rm -f "$U"; vd_control unreadable
# oversize: the same 200-byte body is refused at a 100-byte limit and accepted at the default
S=$(vd_draft reviewer-1 big.md "$(printf 'x%.0s' $(seq 1 200))")
vd_refuse oversize "$S" SESSION_SCHEDULER_NOTE_MAX_BYTES=100; vd_expect_refused oversize 'limit of 100'
[ -f "$S" ] || vd_bad="$vd_bad [oversize draft removed]"; rm -f "$S"
S2=$(vd_draft reviewer-1 big-ok.md "$(printf 'x%.0s' $(seq 1 200))")
id=$(vd_task assigned); vd_reset_log; vd reviewer-1 task-done.sh "$id" --note-file "$S2" >/dev/null 2>&1 || vd_bad="$vd_bad [oversize control (default limit) failed]"
# a body exactly at the limit is accepted (boundary control)
S3=$(vd_draft reviewer-1 edge.md "$(printf 'y%.0s' $(seq 1 100))"); id=$(vd_task assigned); vd_reset_log
SESSION_SCHEDULER_NOTE_MAX_BYTES=100 vd reviewer-1 task-done.sh "$id" --note-file "$S3" >/dev/null 2>&1 || vd_bad="$vd_bad [exact-limit control failed]"
# NUL byte and invalid UTF-8 (raw bytes validated by python3 -I before any shell substitution)
N=$(vd_draft reviewer-1 nul.md ""); printf 'before\0after\n' > "$N"
vd_refuse nul "$N"; vd_expect_refused nul 'NUL byte'; rm -f "$N"; vd_control nul
X=$(vd_draft reviewer-1 badutf8.md ""); printf 'ok line\n\xff\xfe broken\n' > "$X"
vd_refuse invalid_utf8 "$X"; vd_expect_refused invalid_utf8 'not valid UTF-8'; rm -f "$X"; vd_control utf8
# empty draft
E=$(vd_draft reviewer-1 empty.md ""); vd_refuse empty "$E"; vd_expect_refused empty 'empty'; rm -f "$E"; vd_control empty
if [ -z "$vd_bad" ]; then pass "verdict_note_file_refusals_before_transition_each_with_control"
else fail "verdict_note_file_refusals_before_transition_each_with_control" "$vd_bad"; fi

# V2 mixed versions: an older session-chat without own-draft-check.sh refuses
# --note-file with an upgrade message BEFORE the file is read or anything changes
# (the draft is eligible: only the missing capability can be the reason). The
# same draft with the current chat is the control; inline notes keep working.
vd_bad=""
id=$(vd_task assigned); vd_reset_log
D=$(vd_draft reviewer-1 old-chat.md "verdict for an old chat")
old_out=$(VD_CHAT_USE="$VD_CHAT_NOHELPER" vd reviewer-1 task-done.sh "$id" --note-file "$D" 2>&1); old_rc=$?
{ [ "$old_rc" != 0 ] && echo "$old_out" | grep -q 'own-draft-check.sh' && echo "$old_out" | grep -qi 'newer session-chat' && echo "$old_out" | grep -q 'not read' \
  && vd_unchanged "$id" assigned && [ -f "$D" ]; } || vd_bad="$vd_bad [old chat rc=$old_rc out=$old_out]"
ctl_out=$(vd reviewer-1 task-done.sh "$id" --note-file "$D" 2>&1); ctl_rc=$?
{ [ "$ctl_rc" = 0 ] && [ "$(vd_artifacts "$id")" = 1 ] && [ ! -e "$D" ]; } || vd_bad="$vd_bad [current chat control rc=$ctl_rc out=$ctl_out]"
id=$(vd_task assigned); vd_reset_log
VD_CHAT_USE="$VD_CHAT_NOHELPER" vd reviewer-1 task-done.sh "$id" "inline note still works" >/dev/null 2>&1; inl_rc=$?
{ [ "$inl_rc" = 0 ] && [ "$(jq -r .status "$(vd_tf "$id")")" = "done" ] && [ "$(jq -r '(.meta.verdict_events // {}) | length' "$(vd_tf "$id")")" = 0 ]; } || vd_bad="$vd_bad [inline note with old chat rc=$inl_rc]"
# an installed chat whose helper prints malformed output is refused before any change
BAD_CHAT="$VD_ROOT/chat-badhelper"; vd_chat_root "$BAD_CHAT" no-helper
for variant in 'echo "OK	1:2	abc	5"' 'printf "OK\t1:2\t%064d\t5\nextra\n" 0' 'printf "NOPE\t1:2\t%064d\t5\n" 0' 'exit 0'; do
  printf '#!/usr/bin/env bash\n%s\n' "$variant" > "$BAD_CHAT/scripts/own-draft-check.sh"
  id=$(vd_task assigned); vd_reset_log; D=$(vd_draft reviewer-1 bad-helper.md "body")
  VD_CHAT_USE="$BAD_CHAT" vd reviewer-1 task-done.sh "$id" --note-file "$D" >/dev/null 2>&1; bh_rc=$?
  { [ "$bh_rc" != 0 ] && vd_unchanged "$id" assigned && [ -f "$D" ]; } || vd_bad="$vd_bad [malformed helper ($variant) rc=$bh_rc]"
  rm -f "$D"
done
if [ -z "$vd_bad" ]; then pass "verdict_note_file_missing_or_malformed_check_helper_refuses_before_read"
else fail "verdict_note_file_missing_or_malformed_check_helper_refuses_before_read" "$vd_bad"; fi

# V4: the draft is consumed only after the commit, and only if unchanged. A draft
# edited (or replaced) after the check, here during notification delivery, is kept
# with a NOTE while the verdict stays committed. The unchanged case is the control.
vd_bad=""
for variant in edited replaced; do
  id=$(vd_task review); vd_reset_log
  D=$(vd_draft reviewer-1 "mut-$variant.md" "verdict $variant")
  if [ "$variant" = edited ]; then mut_out=$(VD_MUTATE="$D" vd reviewer-1 task-done.sh "$id" --note-file "$D" 2>&1); mut_rc=$?
  else mut_out=$(VD_REPLACE="$D" vd reviewer-1 task-done.sh "$id" --note-file "$D" 2>&1); mut_rc=$?; fi
  { [ "$mut_rc" = 0 ] && [ -f "$D" ] && echo "$mut_out" | grep -q 'NOTE: kept draft' && [ "$(jq -r .status "$(vd_tf "$id")")" = "done" ] \
    && [ "$(jq -r '.meta.verdict_events | to_entries[0].value.notification.state' "$(vd_tf "$id")")" = delivered ] \
    && grep -qF "verdict $variant" "$VD_LOG/dispatch-1.md" && [ "$(vd_sha "$(jq -r '.meta.verdict_events | to_entries[0].value.artifact' "$(vd_tf "$id")")")" = "$(printf 'verdict %s' "$variant" | shasum -a 256 | awk '{print $1}')" ]; } \
    || vd_bad="$vd_bad [$variant rc=$mut_rc kept=$([ -f "$D" ] && echo yes || echo no) out=$mut_out]"
  rm -f "$D"
done
id=$(vd_task review); vd_reset_log; D=$(vd_draft reviewer-1 mut-control.md "verdict control")
vd reviewer-1 task-done.sh "$id" --note-file "$D" >/dev/null 2>&1; [ ! -e "$D" ] || vd_bad="$vd_bad [unchanged control kept]"
# opt-out and a hard failure of nothing: SESSION_CHAT_KEEP_DRAFTS=1 keeps the draft
id=$(vd_task review); vd_reset_log; D=$(vd_draft reviewer-1 keep-optout.md "verdict keep")
SESSION_CHAT_KEEP_DRAFTS=1 vd reviewer-1 task-done.sh "$id" --note-file "$D" >/dev/null 2>&1; { [ -f "$D" ] && [ "$(jq -r .status "$(vd_tf "$id")")" = "done" ]; } || vd_bad="$vd_bad [KEEP_DRAFTS opt-out]"
rm -f "$D"
if [ -z "$vd_bad" ]; then pass "verdict_draft_consumed_after_commit_only_when_unchanged"
else fail "verdict_draft_consumed_after_commit_only_when_unchanged" "$vd_bad"; fi

# V1: task-review records the review request id from exactly one `Message id:`
# stdout line of the review dispatch; absent, duplicated or stderr-only ids give
# null (unknown); never fabricated. The first case is the positive control.
vd_bad=""
rv_case() { # rv_case <label> <expected jq literal> [env assignments...]
  local label="$1" expect="$2" id; shift 2
  id=$(vd_new_for_review); vd_reset_log
  ( vd_env_export "$@"; vd executor-1 task-review.sh "$id" "sha abc" ) >/dev/null 2>&1
  [ "$(jq -c '.meta.review_request_msg_id' "$(vd_tf "$id")")" = "$expect" ] || vd_bad="$vd_bad [$label: got $(jq -c '.meta.review_request_msg_id' "$(vd_tf "$id")") want $expect]"
  [ "$label" = hard_failure ] || [ "$(jq -r '.meta.review_dispatch_status' "$(vd_tf "$id")")" != null ] || vd_bad="$vd_bad [$label: dispatch not recorded]"
}
vd_new_for_review() { local id; id=$(vd master-1 task-new.sh "rv-task" --reviewer reviewer-1 2>&1 | awk '/Created task:/ {print $3}'); vd master-1 task-assign.sh executor-1 "$id" "do it" >/dev/null 2>&1; printf '%s' "$id"; }
rv_case control '"aaaaaaaaaaaaaaaa"'
rv_case queued '"bbbbbbbbbbbbbbbb"' VD_MODE=queued
rv_case absent_older_chat null VD_ID_OUT=
rv_case duplicate null "VD_ID_OUT=Message id: aaaaaaaaaaaaaaaa
Message id: bbbbbbbbbbbbbbbb"
rv_case malformed null "VD_ID_OUT=Message id: ZZZZ"
rv_case prefix_text null "VD_ID_OUT=note: Message id: aaaaaaaaaaaaaaaa"
rv_case stderr_only null VD_ID_OUT= "VD_ERR_OUT=Message id: aaaaaaaaaaaaaaaa"
rv_case hard_failure null VD_MODE=fail
# a later round replaces the request id; a failed later dispatch resets it to unknown
id=$(vd_new_for_review); VD_MSGID=x vd executor-1 task-review.sh "$id" "round 1" >/dev/null 2>&1
vd master-1 task-block.sh "$id" "rework" >/dev/null 2>&1; vd master-1 task-assign.sh executor-1 "$id" "again" >/dev/null 2>&1
VD_MODE=fail vd executor-1 task-review.sh "$id" "round 2" >/dev/null 2>&1
[ "$(jq -c '.meta.review_request_msg_id' "$(vd_tf "$id")")" = null ] || vd_bad="$vd_bad [stale request id kept after failed dispatch]"
# with an unknown request id, the verdict event records null and task-status says unknown
id=$(vd_new_for_review); VD_ID_OUT='' vd executor-1 task-review.sh "$id" "sha" >/dev/null 2>&1
D=$(vd_draft reviewer-1 unknown-r.md "verdict with unknown request"); vd_reset_log
vd reviewer-1 task-done.sh "$id" --note-file "$D" >/dev/null 2>&1
unk_st=$(vd master-1 task-status.sh "$id" 2>&1)
{ [ "$(jq -c '.meta.verdict_events | to_entries[0].value.request_msg_id' "$(vd_tf "$id")")" = null ] \
  && echo "$unk_st" | grep -q 'request: unknown'; } || vd_bad="$vd_bad [unknown request not recorded/displayed]"
if [ -z "$vd_bad" ]; then pass "task_review_records_request_message_id_or_null"
else fail "task_review_records_request_message_id_or_null" "$vd_bad"; fi

# V3 crashes: the process is SIGKILLed at a chosen boundary by EXTERNAL
# instrumentation (BASH_ENV loads a DEBUG trap, set -T so functions inherit it,
# keyed on production function names and BASH_COMMAND). Each trial runs
# task-done as the leader of its own session via python (start_new_session);
# returncode -9 plus the marker file prove the death by SIGKILL at that
# boundary. Trials are isolated (fresh task each).
#   before-save     the mv that publishes the transition + event in ONE ledger write
#   after-save      the first command after that mv, before any dispatch
#   before-outcome  entry to verdict_record_outcome, after the dispatch ran
VD_TRAP="$VD_ROOT/crash-trap.sh"
cat > "$VD_TRAP" <<'TRAP'
set -T
__vd_after=0
__vd_kill() {
  local c="$BASH_COMMAND" hit=""
  case " ${FUNCNAME[*]} " in
    *" task_write "*)
      if [ "$__vd_after" = 1 ]; then hit=after-save
      else case "$c" in 'mv '*) __vd_after=1; hit=before-save ;; esac
      fi ;;
    *" verdict_record_outcome "*) hit=before-outcome ;;
  esac
  if [ -n "$hit" ] && [ "$hit" = "${VD_CRASH_AT:-}" ]; then
    printf '%s\n' "$hit" > "$VD_MARK"
    kill -KILL 0
  fi
  return 0
}
[ -n "${VD_CRASH_AT:-}" ] && trap '__vd_kill' DEBUG
TRAP
vd_crash_run() { # vd_crash_run <boundary> <id> <draft> -> prints the returncode
  local boundary="$1" id="$2" draft="$3"
  rm -f "$VD_ROOT/crash.mark"
  SESSION_SCHEDULER_HOME="$VD_HOME" SESSION_CHAT_ROOT_OVERRIDE="$VD_CHAT" SESSION_CHAT_PANE_NAME=reviewer-1 \
    SESSION_CHAT_TARGET_MESSAGES_DIR="$VD_MSGS" VD_LOG="$VD_LOG" BASH_ENV="$VD_TRAP" VD_CRASH_AT="$boundary" VD_MARK="$VD_ROOT/crash.mark" \
    python3 -B -I -c 'import subprocess, sys
print(subprocess.run(sys.argv[1:], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode)' \
    bash "$VD_SCRIPTS/task-done.sh" "$id" --note-file "$draft" 2>/dev/null
}
vd_tree_sum() { (cd "$VD_HOME" && find . -type f -not -path './locks/*' | sort | xargs cksum 2>/dev/null | cksum); }
vd_bad=""
for boundary in before-save after-save before-outcome; do
  id=$(vd_task review); vd_reset_log
  D=$(vd_draft reviewer-1 "crash-$boundary.md" "crash verdict ($boundary)")
  hist_before=$(jq -r '.history | length' "$(vd_tf "$id")")
  rc=$(vd_crash_run "$boundary" "$id" "$D")
  if [ "$rc" != -9 ] || [ "$(cat "$VD_ROOT/crash.mark" 2>/dev/null)" != "$boundary" ]; then
    vd_bad="$vd_bad [$boundary: SIGKILL not proven rc=$rc mark=$(cat "$VD_ROOT/crash.mark" 2>/dev/null)]"; continue
  fi
  F=$(vd_tf "$id"); events=$(jq -r '(.meta.verdict_events // {}) | length' "$F"); disp=$(vd_ndisp)
  case "$boundary" in
    before-save)
      # no transition, no event, history unchanged, nothing sent, draft kept; the
      # orphan artifact (created before the save) is not referenced by the ledger.
      { [ "$(jq -r .status "$F")" = review ] && [ "$events" = 0 ] && [ "$(jq -r '.history | length' "$F")" = "$hist_before" ] \
        && [ -z "$disp" ] && [ -f "$D" ] && [ "$(vd_artifacts "$id")" = 1 ]; } || vd_bad="$vd_bad [before-save: status=$(jq -r .status "$F") events=$events disp=$disp]"
      # recovery: the stale lock is reclaimed and a plain rerun commits exactly one event
      vd reviewer-1 task-done.sh "$id" --note-file "$D" >/dev/null 2>&1; rr=$?
      { [ "$rr" = 0 ] && [ "$(jq -r '.meta.verdict_events | length' "$F")" = 1 ] && [ "$(jq -r .status "$F")" = "done" ]; } || vd_bad="$vd_bad [before-save: rerun rc=$rr]" ;;
    after-save|before-outcome)
      # committed transition + event, outcome never recorded: pending = unconfirmed
      { [ "$(jq -r .status "$F")" = "done" ] && [ "$events" = 1 ] && [ "$(jq -r '.meta.verdict_events | to_entries[0].value.notification.state' "$F")" = pending ] \
        && [ "$(vd_artifacts "$id")" = 1 ] && [ -f "$D" ]; } || vd_bad="$vd_bad [$boundary: state=$(jq -c '.meta.verdict_events' "$F")]"
      if [ "$boundary" = after-save ]; then [ -z "$disp" ] || vd_bad="$vd_bad [after-save: a dispatch already ran ($disp)]"
      else [ "$disp" = 1 ] || vd_bad="$vd_bad [before-outcome: expected exactly one dispatch before the crash, got '$disp']"; fi
      # task-status reports it truthfully (unconfirmed) and never writes
      before=$(vd_tree_sum); st=$(vd master-1 task-status.sh "$id" 2>&1); st_all=$(vd master-1 task-status.sh --all 2>&1); after=$(vd_tree_sum)
      { echo "$st" | grep -q 'UNCONFIRMED' && echo "$st" | grep -q 'notification: pending' && echo "$st_all" | grep -q 'pending (unconfirmed)' && [ "$before" = "$after" ]; } \
        || vd_bad="$vd_bad [$boundary: status view not truthful/observational: $(echo "$st" | grep -i notification)]"
      # no replay: a rerun is refused as today; no second event, notification or kept artifact
      vd_n0=$(vd_ndisp)
      vd reviewer-1 task-done.sh "$id" --note-file "$D" >/dev/null 2>&1; rr=$?
      { [ "$rr" != 0 ] && [ "$(jq -r '.meta.verdict_events | length' "$F")" = 1 ] && [ "$(vd_artifacts "$id")" = 1 ] \
        && [ "$(vd_ndisp)" = "$vd_n0" ] \
        && [ "$(jq -r '.meta.verdict_events | to_entries[0].value.notification.state' "$F")" = pending ]; } || vd_bad="$vd_bad [$boundary: rerun rc=$rr replayed]" ;;
  esac
done
# control: the same trap loaded but never armed is an ordinary delivered run
id=$(vd_task review); vd_reset_log; D=$(vd_draft reviewer-1 crash-control.md "no crash")
SESSION_SCHEDULER_HOME="$VD_HOME" SESSION_CHAT_ROOT_OVERRIDE="$VD_CHAT" SESSION_CHAT_PANE_NAME=reviewer-1 SESSION_CHAT_TARGET_MESSAGES_DIR="$VD_MSGS" VD_LOG="$VD_LOG" \
  BASH_ENV="$VD_TRAP" bash "$VD_SCRIPTS/task-done.sh" "$id" --note-file "$D" >/dev/null 2>&1; nc_rc=$?
{ [ "$nc_rc" = 0 ] && [ "$(jq -r '.meta.verdict_events | to_entries[0].value.notification.state' "$(vd_tf "$id")")" = delivered ] && [ ! -e "$D" ]; } || vd_bad="$vd_bad [uncrashed control rc=$nc_rc]"
if [ -z "$vd_bad" ]; then pass "verdict_crash_boundaries_sigkill_truthful_pending_no_replay"
else fail "verdict_crash_boundaries_sigkill_truthful_pending_no_replay" "$vd_bad"; fi

# V5: task-status shows event id, request id (or unknown), artifact, SHA-256 and the
# notification state, prints a verdict body only after the digest matches, and
# never writes. Control: an untouched delivered event shows its body.
vd_bad=""
id=$(vd_task review); vd_reset_log; D=$(vd_draft reviewer-1 status-view.md $'STATUS-VIEW first line\nsecond body line\n')
vd reviewer-1 task-done.sh "$id" --note-file "$D" >/dev/null 2>&1
F=$(vd_tf "$id"); ev=$(jq -r '.meta.verdict_events | keys[0]' "$F"); art="$VD_HOME/prompts/$id-verdict-$ev.md"; sha=$(vd_sha "$art")
before=$(vd_tree_sum); st=$(vd master-1 task-status.sh "$id" 2>&1); after=$(vd_tree_sum)
{ echo "$st" | grep -qF "event $ev: done by reviewer-1" && echo "$st" | grep -qF "request: aaaaaaaaaaaaaaaa" && echo "$st" | grep -qF "artifact: $art sha256:$sha" \
  && echo "$st" | grep -qF "notification: delivered" && echo "$st" | grep -qF "second body line" && echo "$st" | grep -qF "SHA-256 verified" && [ "$before" = "$after" ]; } \
  || vd_bad="$vd_bad [status view: $st]"
all=$(vd master-1 task-status.sh --all 2>&1)
echo "$all" | grep -qE "^  $id	$ev	done	request:aaaaaaaaaaaaaaaa	notification:delivered" || vd_bad="$vd_bad [--all event row missing]"
printf 'tampered\n' >> "$art"
st2=$(vd master-1 task-status.sh "$id" 2>&1)
{ ! echo "$st2" | grep -qF "second body line" && echo "$st2" | grep -q 'body not shown'; } || vd_bad="$vd_bad [tampered artifact body was shown]"
if [ -z "$vd_bad" ]; then pass "task_status_shows_verdict_events_observationally"
else fail "task_status_shows_verdict_events_observationally" "$vd_bad"; fi

# V7: tasks-clean removes a task's verdict artifacts (and notice) with the task,
# keeps those of surviving tasks, sweeps only aged orphans, and is dry-run by default.
vd_bad=""
OLD=$(vd_task review); NEW=$(vd_task review)
for t in "$OLD" "$NEW"; do D=$(vd_draft reviewer-1 "clean-$t.md" "clean verdict $t"); vd reviewer-1 task-done.sh "$t" --note-file "$D" >/dev/null 2>&1; done
oev=$(jq -r '.meta.verdict_events | keys[0]' "$(vd_tf "$OLD")"); nev=$(jq -r '.meta.verdict_events | keys[0]' "$(vd_tf "$NEW")")
jq '.updated_at = "2020-01-01T00:00:00+05:30"' "$(vd_tf "$OLD")" > "$(vd_tf "$OLD").x" && mv "$(vd_tf "$OLD").x" "$(vd_tf "$OLD")"
P="$VD_HOME/prompts"
touch -t 202001010000 "$P/ghost-task-verdict-0123456789abcdef.md" 2>/dev/null || : > "$P/ghost-task-verdict-0123456789abcdef.md"; touch -t 202001010000 "$P/ghost-task-verdict-0123456789abcdef.md"
: > "$P/young-ghost-verdict-fedcba9876543210.md"
vd master-1 tasks-clean.sh --older-than 30 > "$VD_ROOT/clean-dry.out" 2>&1
{ [ -f "$P/$OLD-verdict-$oev.md" ] && [ -f "$P/ghost-task-verdict-0123456789abcdef.md" ] && grep -q DRY-RUN "$VD_ROOT/clean-dry.out"; } || vd_bad="$vd_bad [dry-run deleted or did not preview]"
vd master-1 tasks-clean.sh --older-than 30 --apply > "$VD_ROOT/clean-apply.out" 2>&1
{ [ ! -e "$(vd_tf "$OLD")" ] && [ ! -e "$P/$OLD-verdict-$oev.md" ] && [ ! -e "$P/$OLD-verdict-$oev-notice.md" ] && [ ! -e "$P/ghost-task-verdict-0123456789abcdef.md" ]; } \
  || vd_bad="$vd_bad [aged task artifacts/orphan not removed: $(cat "$VD_ROOT/clean-apply.out")]"
# controls: the surviving task keeps its artifacts; a young orphan is kept
{ [ -f "$(vd_tf "$NEW")" ] && [ -f "$P/$NEW-verdict-$nev.md" ] && [ -f "$P/$NEW-verdict-$nev-notice.md" ] && [ -f "$P/young-ghost-verdict-fedcba9876543210.md" ]; } \
  || vd_bad="$vd_bad [surviving task artifact or young orphan removed]"
if [ -z "$vd_bad" ]; then pass "tasks_clean_removes_verdict_artifacts_with_their_task"
else fail "tasks_clean_removes_verdict_artifacts_with_their_task" "$vd_bad"; fi

# V6: contracted tasks (real engine, real Git subject) produce the same event and
# notification, the review request id is persisted by the engine's review
# reserve/finish, and the notification outcome write leaves the admission digest
# intact (inspect still reports admitted; the stored history digest still matches).
VC_REPO="$VD_ROOT/ct-repo"; mkdir -p "$VC_REPO"
( cd "$VC_REPO" && git init -q && git config user.email fixture@example.invalid && git config user.name Fixture \
  && printf '#!/bin/bash\nexit 0\n' > check.sh && printf 'baseline' > source && git add . && git commit -qm fixture )
VC_SPEC="$VD_ROOT/ct-spec.json"
jq -n --arg repo "$(cd "$VC_REPO" && pwd -P)" '{schema_version:1, repository:$repo, checks:[{id:"unit",script:"check.sh",args:[],timeout_seconds:20}], ttl_seconds:600, max_attempts:3}' > "$VC_SPEC"
vc_task() { # vc_task [VAR=val ...] -> id of a contracted task in review (assigner master-1, executor-1, reviewer reviewer-1)
  local id digest
  id=$(vd master-1 task-new.sh "vc-task" --reviewer reviewer-1 2>&1 | awk '/Created task:/ {print $3}')
  vd master-1 task-contract.sh attach "$id" --spec "$VC_SPEC" >/dev/null 2>&1
  vd master-1 task-contract.sh assign executor-1 "$id" "implement" >/dev/null 2>&1
  digest=$(vd master-1 task-contract.sh inspect "$id" 2>/dev/null | jq -r .spec_digest)
  vd executor-1 task-contract.sh verify "$id" --generation 1 --spec-digest "$digest" >/dev/null 2>&1
  ( vd_env_export "$@"; vd executor-1 task-review.sh "$id" --generation 1 "ready" ) >/dev/null 2>&1
  printf '%s' "$id"
}
vc_digest_ok() { python3 -B -I -c 'import json,hashlib,sys
d=json.load(open(sys.argv[1]))
print(hashlib.sha256(json.dumps(d["history"],sort_keys=True,separators=(",",":")).encode()).hexdigest()==d["contract"]["admission"]["history"])' "$1"; }
vd_bad=""
VC_ID=$(vc_task); VC_F=$(vd_tf "$VC_ID"); vd_reset_log
[ "$(jq -r .status "$VC_F")" = review ] && [ "$(jq -r '.meta.review_request_msg_id' "$VC_F")" = aaaaaaaaaaaaaaaa ] \
  || vd_bad="$vd_bad [contracted review did not persist the request id: status=$(jq -r .status "$VC_F") r=$(jq -r '.meta.review_request_msg_id' "$VC_F")]"
VC_D=$(vd_draft reviewer-1 ct-done.md $'CONTRACT verdict line one\nsecond line of the verdict\n')
# refusals first, each leaving no event/artifact/notification and the draft in place;
# the valid reviewer call on the SAME task afterwards is the control
vc_refused() { # vc_refused <label> <pane> <script> args...
  local label="$1" pane="$2" script="$3" out rc; shift 3
  out=$(vd "$pane" "$script" "$VC_ID" "$@" 2>&1); rc=$?
  { [ "$rc" != 0 ] && [ "$(jq -r .status "$VC_F")" = review ] && [ "$(jq -r '(.meta.verdict_events // {}) | length' "$VC_F")" = 0 ] \
    && [ "$(vd_artifacts "$VC_ID")" = 0 ] && [ ! -e "$VD_LOG/dispatch.log" ] && [ -f "$VC_D" ]; } || vd_bad="$vd_bad [$label: rc=$rc out=$out]"
}
vc_refused executor_cannot_complete executor-1 task-done.sh --generation 1 --note-file "$VC_D"
vc_refused stale_generation reviewer-1 task-done.sh --generation 2 --note-file "$VC_D"
vc_refused missing_generation reviewer-1 task-done.sh --note-file "$VC_D"
vc_refused force_refused reviewer-1 task-done.sh --force --generation 1 --note-file "$VC_D"
vc_refused foreign_draft reviewer-1 task-done.sh --generation 1 --note-file "$(vd_draft other-1 ct-foreign.md "foreign")"
VC_HIST_BEFORE=$(jq -c '.history' "$VC_F")
vc_out=$(vd reviewer-1 task-done.sh "$VC_ID" --generation 1 --note-file "$VC_D" 2>&1); vc_rc=$?
VC_EV=$(jq -r '(.meta.verdict_events // {}) | keys[0] // empty' "$VC_F")
VC_ART="$VD_HOME/prompts/$VC_ID-verdict-$VC_EV.md"
{ [ "$vc_rc" = 0 ] && [ "$(jq -r .status "$VC_F")" = "done" ] && [ -n "$VC_EV" ] && [ "$(jq -r '.meta.verdict_events | length' "$VC_F")" = 1 ]; } || vd_bad="$vd_bad [contracted done rc=$vc_rc out=$vc_out]"
jq -e --arg ev "$VC_EV" --arg sha "$(vd_sha "$VC_ART" 2>/dev/null)" '.meta.verdict_events[$ev] | .transition == "done" and .actor == "reviewer-1" and .route_to == "master-1"
  and .request_msg_id == "aaaaaaaaaaaaaaaa" and .generation == 1 and .artifact_sha256 == $sha and .notification.state == "delivered"' "$VC_F" >/dev/null 2>&1 \
  || vd_bad="$vd_bad [contracted event: $(jq -c '.meta.verdict_events' "$VC_F")]"
{ [ "$(wc -l < "$VD_LOG/dispatch.log" | tr -d ' ')" = 1 ] && [[ "$(head -1 "$VD_LOG/dispatch-1.md")" == "[task:$VC_ID] [event:$VC_EV] CONTRACT verdict line one" ]] \
  && grep -qF 'second line of the verdict' "$VD_LOG/dispatch-1.md" && ! grep -qF '[re:' "$VD_LOG/dispatch-1.md" && [ ! -e "$VC_D" ]; } || vd_bad="$vd_bad [contracted notification/draft]"
# admission digest: history carries the verdict note (excerpt + artifact pointer) but no notification bookkeeping,
# the stored digest still matches AFTER the outcome write, and inspect still admits
[ "$(jq -r '[.history[] | select(.event == "admitted")] | length' "$VC_F")" = 1 ] && [ "$(vc_digest_ok "$VC_F")" = True ] \
  && [ "$(jq -r '.history | length' "$VC_F")" = "$(( $(printf '%s' "$VC_HIST_BEFORE" | jq 'length') + 1 ))" ] \
  && [ "$(vd master-1 task-contract.sh inspect "$VC_ID" 2>/dev/null | jq -r .state)" = admitted ] || vd_bad="$vd_bad [admission digest changed or inspect not admitted]"
echo "$(jq -r '.history[-1].note' "$VC_F")" | grep -q "^CONTRACT verdict line one (verdict $VC_ART sha256:" || vd_bad="$vd_bad [contracted history note]"
# a rerun on the admitted task is refused as today (no replay), nothing more is sent
vd_reset_log; D2=$(vd_draft reviewer-1 ct-done2.md "second"); vd reviewer-1 task-done.sh "$VC_ID" --generation 1 --note-file "$D2" >/dev/null 2>&1; rr=$?
{ [ "$rr" != 0 ] && [ "$(jq -r '.meta.verdict_events | length' "$VC_F")" = 1 ] && [ "$(vd_artifacts "$VC_ID")" = 1 ] && [ ! -e "$VD_LOG/dispatch.log" ] && [ "$(vc_digest_ok "$VC_F")" = True ]; } || vd_bad="$vd_bad [contracted rerun replayed rc=$rr]"
rm -f "$D2"
# contracted block by the reviewer: same event shape (blocked); queued outcome is recorded queued
VB_ID=$(vc_task); VB_F=$(vd_tf "$VB_ID"); vd_reset_log; VB_D=$(vd_draft reviewer-1 ct-block.md $'Contract rejection\nneeds a test\n')
vb_out=$(VD_MODE=queued vd reviewer-1 task-block.sh "$VB_ID" --generation 1 --note-file "$VB_D" 2>&1); vb_rc=$?
VB_EV=$(jq -r '(.meta.verdict_events // {}) | keys[0] // empty' "$VB_F")
{ [ "$vb_rc" = 0 ] && [ "$(jq -r .status "$VB_F")" = blocked ] && [ -n "$VB_EV" ] \
  && jq -e --arg ev "$VB_EV" '.meta.verdict_events[$ev] | .transition == "blocked" and .generation == 1 and .request_msg_id == "aaaaaaaaaaaaaaaa" and .notification.state == "queued"' "$VB_F" >/dev/null 2>&1 \
  && [ "$(wc -l < "$VD_LOG/dispatch.log" | tr -d ' ')" = 1 ] && [ ! -e "$VD_LOG/send.log" ] && [ ! -e "$VB_D" ] && grep -qF 'needs a test' "$VD_LOG/dispatch-1.md"; } \
  || vd_bad="$vd_bad [contracted block rc=$vb_rc out=$vb_out event=$(jq -c '.meta.verdict_events' "$VB_F")]"
# contracted notification failure: hard dispatch failure falls back to the bounded pointer
VF_ID=$(vc_task); VF_F=$(vd_tf "$VF_ID"); vd_reset_log; VF_D=$(vd_draft reviewer-1 ct-fail.md $'Approve despite transport trouble\nlong body\n')
VD_MODE=fail vd reviewer-1 task-done.sh "$VF_ID" --generation 1 --note-file "$VF_D" >/dev/null 2>&1; vf_rc=$?
{ [ "$vf_rc" = 0 ] && [ "$(jq -r .status "$VF_F")" = "done" ] && [ "$(jq -r '.meta.verdict_events | to_entries[0].value.notification.state' "$VF_F")" = inline-fallback ] \
  && grep -q "full verdict recorded: task-status $VF_ID" "$VD_LOG/send.log" && [ "$(vc_digest_ok "$VF_F")" = True ]; } || vd_bad="$vd_bad [contracted fallback rc=$vf_rc]"
# an older chat (no Message id line) leaves the contracted request id null
VN_ID=$(vc_task VD_ID_OUT=); [ "$(jq -c '.meta.review_request_msg_id' "$(vd_tf "$VN_ID")")" = null ] || vd_bad="$vd_bad [contracted request id fabricated]"
if [ -z "$vd_bad" ]; then pass "contracted_done_block_verdict_event_notification_and_admission_digest"
else fail "contracted_done_block_verdict_event_notification_and_admission_digest" "$vd_bad"; fi

# --- Review round 1 regressions (R1-R5, C1, C2) ---

# R1: composing the notification must never delete a path it did not create. An
# existing file, a symlink, or another task's base prompt at the notice path is
# refused (outcome failed, no dispatch) and left untouched; an empty path (control)
# gets a new 0600 notice and a delivered outcome.
vr_event() { # vr_event <task-id> <event> : a task whose ledger records one event with a valid artifact
  local id="$1" ev="$2" art="$VD_HOME/prompts/$1-verdict-$2.md" sha
  printf 'R1 verdict body\n' > "$art"; chmod 600 "$art"; sha=$(vd_sha "$art")
  jq -n --arg id "$id" --arg ev "$ev" --arg art "$art" --arg sha "$sha" \
    '{id:$id, assigner:"master-1", status:"done", history:[], meta:{verdict_events:{($ev):{artifact:$art, artifact_sha256:$sha, route_to:"master-1", notification:{state:"pending"}}}}}' > "$(vd_tf "$id")"
}
vr_notify() { # vr_notify <task-id> <event> -> stdout outcome; the dispatch marker is $VD_ROOT/vr-dispatched
  rm -f "$VD_ROOT/vr-dispatched"
  SESSION_SCHEDULER_HOME="$VD_HOME" VR_MARK="$VD_ROOT/vr-dispatched" bash -c 'source "$1"; session_chat_dispatch() { : > "$VR_MARK"; echo "Dispatched task to x"; }; verdict_notify "$2" "$3"' _ "$VD_SCRIPTS/lib.sh" "$1" "$2" 2>/dev/null
}
vd_bad=""
EV=1111111111111111
# (a) pre-existing regular file
vr_event r1-a "$EV"; NP="$VD_HOME/prompts/r1-a-verdict-$EV-notice.md"; printf 'PREEXISTING SENTINEL\n' > "$NP"
out=$(vr_notify r1-a "$EV"); { [ "$out" = failed ] && [ "$(cat "$NP")" = "PREEXISTING SENTINEL" ] && [ ! -e "$VD_ROOT/vr-dispatched" ]; } || vd_bad="$vd_bad [regular file: out=$out content=$(cat "$NP" 2>&1)]"
# (b) pre-existing symlink: the link and its target both survive
vr_event r1-b "$EV"; NP="$VD_HOME/prompts/r1-b-verdict-$EV-notice.md"; printf 'VICTIM\n' > "$VD_ROOT/r1-victim.txt"; ln -s "$VD_ROOT/r1-victim.txt" "$NP"
out=$(vr_notify r1-b "$EV"); { [ "$out" = failed ] && [ -L "$NP" ] && [ "$(cat "$VD_ROOT/r1-victim.txt")" = VICTIM ] && [ ! -e "$VD_ROOT/vr-dispatched" ]; } || vd_bad="$vd_bad [symlink: out=$out]"
# (c) the notice path is the base prompt of another valid task
vr_event r1-c "$EV"; OTHER="r1-c-verdict-$EV-notice"; NP="$VD_HOME/prompts/$OTHER.md"
printf 'OTHER TASK PROMPT\n' > "$NP"; jq -n --arg id "$OTHER" '{id:$id, status:"created", history:[]}' > "$(vd_tf "$OTHER")"
out=$(vr_notify r1-c "$EV"); { [ "$out" = failed ] && [ "$(cat "$NP")" = "OTHER TASK PROMPT" ] && [ -f "$(vd_tf "$OTHER")" ]; } || vd_bad="$vd_bad [other task prompt: out=$out]"
# (d) a directory at the path is refused too
vr_event r1-d "$EV"; NP="$VD_HOME/prompts/r1-d-verdict-$EV-notice.md"; mkdir "$NP"
out=$(vr_notify r1-d "$EV"); { [ "$out" = failed ] && [ -d "$NP" ]; } || vd_bad="$vd_bad [directory: out=$out]"
# control: an empty path gets a new private notice and a delivered outcome
vr_event r1-e "$EV"; NP="$VD_HOME/prompts/r1-e-verdict-$EV-notice.md"
out=$(vr_notify r1-e "$EV"); { [ "$out" = delivered ] && [ -e "$VD_ROOT/vr-dispatched" ] && [ "$(vd_mode "$NP")" = 600 ] && [ "$(head -1 "$NP")" = "[task:r1-e] [event:$EV] R1 verdict body" ]; } || vd_bad="$vd_bad [control: out=$out]"
# the symlink/directory fixtures would make later ensure_dirs refuse this ledger
rm -rf "$VD_HOME"/prompts/r1-* "$VD_HOME"/tasks/r1-* "$VD_ROOT/r1-victim.txt"
if [ -z "$vd_bad" ]; then pass "verdict_notice_collision_preserves_existing_path"
else fail "verdict_notice_collision_preserves_existing_path" "$vd_bad"; fi

# R2: a new assignment generation drops the previous round's review request id in
# the locked assignment save; recorded events keep theirs. Control: a task with no
# prior request records null; a new review in the new generation records its own id.
vd_bad=""
RA=$(vc_task); RA_F=$(vd_tf "$RA"); vd_reset_log
RA_D1=$(vd_draft reviewer-1 r2-gen1.md "generation one rejection")
vd reviewer-1 task-block.sh "$RA" --generation 1 --note-file "$RA_D1" >/dev/null 2>&1
vd master-1 task-contract.sh reconcile "$RA" --generation 1 --note "worker stopped; no external effects" >/dev/null 2>&1
vd master-1 task-contract.sh assign executor-1 "$RA" "second attempt" >/dev/null 2>&1
{ [ "$(jq -r .contract.generation "$RA_F")" = 2 ] && [ "$(jq -r .status "$RA_F")" = assigned ] && [ "$(jq -c '.meta.review_request_msg_id' "$RA_F")" = null ]; } \
  || vd_bad="$vd_bad [assign did not clear the request id: gen=$(jq -r .contract.generation "$RA_F") r=$(jq -c '.meta.review_request_msg_id' "$RA_F")]"
mkdir -p "$VD_MSGS/drafts/executor-1"; chmod 700 "$VD_MSGS/drafts/executor-1"
RA_D2=$(vd_draft executor-1 r2-gen2.md "generation two block")
vd executor-1 task-block.sh "$RA" --generation 2 --note-file "$RA_D2" >/dev/null 2>&1
{ [ "$(jq -r '[.meta.verdict_events[]] | length' "$RA_F")" = 2 ] \
  && [ "$(jq -c '[.meta.verdict_events[] | select(.generation == 1) | .request_msg_id]' "$RA_F")" = '["aaaaaaaaaaaaaaaa"]' ] \
  && [ "$(jq -c '[.meta.verdict_events[] | select(.generation == 2) | .request_msg_id]' "$RA_F")" = '[null]' ]; } \
  || vd_bad="$vd_bad [events: $(jq -c '[.meta.verdict_events[] | {generation, request_msg_id}]' "$RA_F")]"
# a new review in generation 2 establishes its own request id
RB=$(vc_task); RB_F=$(vd_tf "$RB")
vd reviewer-1 task-block.sh "$RB" --generation 1 "inline rejection" >/dev/null 2>&1
vd master-1 task-contract.sh reconcile "$RB" --generation 1 --note "worker stopped" >/dev/null 2>&1
vd master-1 task-contract.sh assign executor-1 "$RB" "second attempt" >/dev/null 2>&1
RB_DIGEST=$(vd master-1 task-contract.sh inspect "$RB" 2>/dev/null | jq -r .spec_digest)
vd executor-1 task-contract.sh verify "$RB" --generation 2 --spec-digest "$RB_DIGEST" >/dev/null 2>&1
VD_ID_OUT='Message id: dddddddddddddddd' vd executor-1 task-review.sh "$RB" --generation 2 "ready again" >/dev/null 2>&1
RB_D=$(vd_draft reviewer-1 r2-new-review.md "approve generation two")
vd reviewer-1 task-done.sh "$RB" --generation 2 --note-file "$RB_D" >/dev/null 2>&1
{ [ "$(jq -r .status "$RB_F")" = "done" ] && [ "$(jq -c '[.meta.verdict_events[] | {generation, request_msg_id}]' "$RB_F")" = '[{"generation":2,"request_msg_id":"dddddddddddddddd"}]' ]; } \
  || vd_bad="$vd_bad [new review request id: status=$(jq -r .status "$RB_F") events=$(jq -c '[.meta.verdict_events[]? | {generation, request_msg_id}]' "$RB_F")]"
# control: an assigned contracted task that never had a request records null
RC=$(vc_task VD_ID_OUT=''); RC_F=$(vd_tf "$RC")
RC_D=$(vd_draft reviewer-1 r2-control.md "no prior request"); vd reviewer-1 task-block.sh "$RC" --generation 1 --note-file "$RC_D" >/dev/null 2>&1
[ "$(jq -c '[.meta.verdict_events[]?.request_msg_id]' "$RC_F")" = '[null]' ] || vd_bad="$vd_bad [no-prior-request control]"
if [ -z "$vd_bad" ]; then pass "contract_reassignment_clears_review_request_linkage"
else fail "contract_reassignment_clears_review_request_linkage" "$vd_bad"; fi

# R3: an oversize draft is refused on its size BEFORE any hashing. A PATH shim that
# records every shasum/sha256sum call observes the work: none for the oversize
# draft; the same 200-byte draft at a sufficient limit is hashed and accepted.
vd_bad=""
VS_SHIM="$VD_ROOT/hash-shim"; mkdir -p "$VS_SHIM"; VS_MARK="$VD_ROOT/hash-calls"
for tool in shasum sha256sum; do
  real=$(command -v "$tool" 2>/dev/null) || continue
  printf '#!/bin/sh\necho x >> "%s"\nexec "%s" "$@"\n' "$VS_MARK" "$real" > "$VS_SHIM/$tool"; chmod 755 "$VS_SHIM/$tool"
done
S=$(vd_draft reviewer-1 r3-big.md "$(printf 'x%.0s' $(seq 1 200))"); rm -f "$VS_MARK"
vd_refuse oversize_noread "$S" SESSION_SCHEDULER_NOTE_MAX_BYTES=100 "PATH=$VS_SHIM:$PATH"
vd_expect_refused oversize_noread 'larger than the limit of 100'
[ ! -e "$VS_MARK" ] || vd_bad="$vd_bad [oversize draft was hashed ($(wc -l < "$VS_MARK" | tr -d ' ') call(s))]"
echo "$VD_LAST_OUT" | grep -q 'was not read' && vd_bad="$vd_bad [stale 'was not read' claim]"
echo "$VD_LAST_OUT" | grep -q 'not hashed or copied' || vd_bad="$vd_bad [claim text missing]"
[ -f "$S" ] || vd_bad="$vd_bad [draft removed]"
rm -f "$VS_MARK"; id=$(vd_task assigned); vd_reset_log
( export SESSION_SCHEDULER_NOTE_MAX_BYTES=200 "PATH=$VS_SHIM:$PATH"; vd reviewer-1 task-done.sh "$id" --note-file "$S" ) >/dev/null 2>&1; s_rc=$?
{ [ "$s_rc" = 0 ] && [ -e "$VS_MARK" ] && [ "$(vd_artifacts "$id")" = 1 ] && [ ! -e "$S" ]; } || vd_bad="$vd_bad [200-byte success control rc=$s_rc hashed=$([ -e "$VS_MARK" ] && echo yes || echo no)]"
# an older helper (missing) still refuses before any read: no hash call, task untouched
S2=$(vd_draft reviewer-1 r3-oldchat.md "body"); rm -f "$VS_MARK"; id=$(vd_task assigned); vd_reset_log
( export "PATH=$VS_SHIM:$PATH" VD_CHAT_USE="$VD_CHAT_NOHELPER"; vd reviewer-1 task-done.sh "$id" --note-file "$S2" ) >/dev/null 2>&1
{ vd_unchanged "$id" assigned && [ ! -e "$VS_MARK" ] && [ -f "$S2" ]; } || vd_bad="$vd_bad [missing helper read something]"
rm -f "$S2"
if [ -z "$vd_bad" ]; then pass "verdict_oversize_refused_before_hashing"
else fail "verdict_oversize_refused_before_hashing" "$vd_bad"; fi

# A draft that grows WHILE it is hashed: the checker exits 4 and the scheduler
# reports it truthfully as read-but-not-copied (never "not hashed"); the task is
# unchanged and the draft kept. Control: the same shim without growth completes.
vd_bad=""
VG_SHIM="$VD_ROOT/grow-shim"; mkdir -p "$VG_SHIM"
for tool in shasum sha256sum; do
  real=$(command -v "$tool" 2>/dev/null) || continue
  printf '#!/bin/sh\n[ -n "$VD_GROW" ] && printf "more\\n" >> "$VD_GROW"\nexec "%s" "$@"\n' "$real" > "$VG_SHIM/$tool"; chmod 755 "$VG_SHIM/$tool"
done
G=$(vd_draft reviewer-1 grow.md "growing verdict")
vd_refuse grow_during_hash "$G" "VD_GROW=$G" "PATH=$VG_SHIM:$PATH"
vd_expect_refused grow_during_hash 'changed while it was being checked'
echo "$VD_LAST_OUT" | grep -q 'not hashed' && vd_bad="$vd_bad [grow case claims not hashed]"
echo "$VD_LAST_OUT" | grep -q 'was read but not copied' || vd_bad="$vd_bad [grow case lacks read-but-not-copied text]"
[ -f "$G" ] || vd_bad="$vd_bad [grown draft removed]"
G2=$(vd_draft reviewer-1 grow-control.md "steady verdict"); id=$(vd_task assigned); vd_reset_log
( export "PATH=$VG_SHIM:$PATH"; vd reviewer-1 task-done.sh "$id" --note-file "$G2" ) >/dev/null 2>&1; g_rc=$?
{ [ "$g_rc" = 0 ] && [ "$(jq -r .status "$(vd_tf "$id")")" = "done" ] && [ "$(vd_artifacts "$id")" = 1 ]; } || vd_bad="$vd_bad [no-growth control rc=$g_rc]"
rm -f "$G"
if [ -z "$vd_bad" ]; then pass "verdict_growth_during_hash_reported_read_not_copied_with_control"
else fail "verdict_growth_during_hash_reported_read_not_copied_with_control" "$vd_bad"; fi

# R5: a failed notification never claims non-delivery. The stub transport writes the
# payload (a real side effect) and THEN reports failure; status says delivery is not
# confirmed and the artifact is durable. The delivered case is the wording control.
vd_bad=""
id=$(vd_task review); vd_reset_log; D=$(vd_draft reviewer-1 r5-fail.md "verdict after transport failure")
VD_MODE=fail VD_SEND_RC=1 vd reviewer-1 task-done.sh "$id" --note-file "$D" >/dev/null 2>&1
[ -f "$VD_LOG/dispatch-1.md" ] && grep -qF 'verdict after transport failure' "$VD_LOG/dispatch-1.md" || vd_bad="$vd_bad [stub did not perform its side effect]"
st=$(vd master-1 task-status.sh "$id" 2>&1)
{ echo "$st" | grep -q 'notification: failed (delivery not confirmed' && echo "$st" | grep -q 'verdict artifact is durable' && ! echo "$st" | grep -qi 'not delivered'; } || vd_bad="$vd_bad [failed wording: $(echo "$st" | grep notification:)]"
id=$(vd_task review); vd_reset_log; D=$(vd_draft reviewer-1 r5-ok.md "delivered verdict")
vd reviewer-1 task-done.sh "$id" --note-file "$D" >/dev/null 2>&1
st=$(vd master-1 task-status.sh "$id" 2>&1)
{ echo "$st" | grep -q 'notification: delivered$' && ! echo "$st" | grep -q 'delivery not confirmed'; } || vd_bad="$vd_bad [delivered control wording: $(echo "$st" | grep notification:)]"
if [ -z "$vd_bad" ]; then pass "task_status_failed_notification_never_claims_non_delivery"
else fail "task_status_failed_notification_never_claims_non_delivery" "$vd_bad"; fi

# C1: the bounded pointer fits its limit for every budget, the ellipsis included
# (minimal pointer = 80 bytes; below it the composer refuses). Multibyte first
# lines are cut on a character boundary. A line that fits is untouched (control).
vd_bad=""
ptr() { python3 -I "$VD_SCRIPTS/verdict-file.py" pointer --task test --event aaaaaaaaaaaaaaaa --line "$1" --max-bytes "$2" 2>/dev/null; }
for lim in 80 81 82 83 84 85 86 87 88 91 100 120; do
  p=$(ptr 'long long line that does not fit' "$lim"); n=$(printf '%s' "$p" | wc -c | tr -d ' ')
  { [ -n "$p" ] && [ "$n" -le "$lim" ] && [[ "$p" == "[task:test] [event:aaaaaaaaaaaaaaaa]"* ]] && [[ "$p" == *" — full verdict recorded: task-status test" ]]; } || vd_bad="$vd_bad [limit $lim -> $n bytes: $p]"
done
for lim in 84 91 95 99; do
  p=$(ptr 'éééééééééééééééé' "$lim"); n=$(printf '%s' "$p" | wc -c | tr -d ' ')
  { [ "$n" -le "$lim" ] && printf '%s' "$p" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; } || vd_bad="$vd_bad [multibyte limit $lim -> $n bytes invalid or too long]"
done
p=$(ptr 'short' 200); [ "$p" = "[task:test] [event:aaaaaaaaaaaaaaaa] short — full verdict recorded: task-status test" ] || vd_bad="$vd_bad [fitting line altered: $p]"
p=$(ptr 'x' 91); [[ "$p" == *"] x — full"* ]] || vd_bad="$vd_bad [one-char line at 91 altered: $p]"
for lim in 79 0; do ptr 'x' "$lim" >/dev/null && vd_bad="$vd_bad [limit $lim below the minimal pointer was accepted]"; done
if [ -z "$vd_bad" ]; then pass "verdict_pointer_ellipsis_fits_budget"
else fail "verdict_pointer_ellipsis_fits_budget" "$vd_bad"; fi

# C2: the helper itself refuses --generation with --note-file on an uncontracted
# task (done and block), before anything is read; the plain --note-file form is the
# control, and inline-note compatibility (the legacy form) is unchanged.
vd_bad=""
for script in task-done.sh task-block.sh; do
  id=$(vd_task assigned); vd_reset_log; D=$(vd_draft reviewer-1 "c2-$script.md" "c2 verdict")
  out=$(vd reviewer-1 "$script" "$id" --generation 1 --note-file "$D" 2>&1); rc=$?
  { [ "$rc" != 0 ] && echo "$out" | grep -q 'applies only to a task with a verification contract' && vd_unchanged "$id" assigned && [ -f "$D" ]; } || vd_bad="$vd_bad [$script refusal rc=$rc out=$out]"
  out=$(vd reviewer-1 "$script" "$id" --note-file "$D" 2>&1); rc=$?
  { [ "$rc" = 0 ] && [ "$(vd_artifacts "$id")" = 1 ] && [ ! -e "$D" ]; } || vd_bad="$vd_bad [$script control rc=$rc out=$out]"
done
id=$(vd_task assigned); vd_reset_log
vd reviewer-1 task-done.sh "$id" --generation 1 "legacy inline note" >/dev/null 2>&1; rc=$?
{ [ "$rc" = 0 ] && [ "$(jq -r '.history[-1].note' "$(vd_tf "$id")")" = "--generation 1 legacy inline note" ] && [ "$(jq -r '(.meta.verdict_events // {}) | length' "$(vd_tf "$id")")" = 0 ]; } || vd_bad="$vd_bad [legacy inline form changed rc=$rc]"
if [ -z "$vd_bad" ]; then pass "uncontracted_generation_with_note_file_refused_by_helper"
else fail "uncontracted_generation_with_note_file_refused_by_helper" "$vd_bad"; fi

# R4: contracted-path crashes. task-contract.py is Python, so the instrumentation is
# EXTERNAL: a python3 shim earlier on PATH runs it under pycrash.py, which installs a
# sys.setprofile hook that SIGKILLs the whole process group at a named boundary of
# the unmodified production file (first/second Store.save call and return, entry of
# Store.verdict_notify). The test process runs task-done/task-block as the leader of
# its own session; returncode -9 plus the marker prove death by SIGKILL at that
# boundary. Trials are isolated (fresh contracted task each). No production failpoint.
VC_SHIM="$VD_ROOT/pyshim"; mkdir -p "$VC_SHIM"
VC_REAL_PY=$(command -v python3)
cat > "$VD_ROOT/pycrash.py" <<'PYCRASH'
import os, runpy, signal, sys
at = os.environ.get("VD_PYCRASH_AT", "")
mark = os.environ.get("VD_PYMARK", "")
saves = {"n": 0}
def hook(frame, event, arg):
    code = frame.f_code
    if not code.co_filename.endswith("task-contract.py"):
        return
    name, hit = code.co_name, ""
    if name == "save":
        if event == "call":
            saves["n"] += 1
            hit = {1: "before-save", 2: "before-outcome"}.get(saves["n"], "")
        elif event == "return":
            hit = {1: "after-save", 2: "after-outcome"}.get(saves["n"], "")
    elif name == "verdict_notify" and event == "call":
        hit = "before-notify"
    if hit and hit == at:
        with open(mark, "w") as handle:
            handle.write(hit)
        os.killpg(os.getpgrp(), signal.SIGKILL)
sys.argv = sys.argv[1:]
if at:
    sys.setprofile(hook)
runpy.run_path(sys.argv[0], run_name="__main__")
PYCRASH
printf '%s\n' '#!/bin/bash' 'case "${1:-}" in' '  */task-contract.py) exec "$VC_REAL_PY" -B "$VC_PYCRASH" "$@" ;;' 'esac' 'exec "$VC_REAL_PY" "$@"' > "$VC_SHIM/python3"; chmod 755 "$VC_SHIM/python3"
vc_crash_run() { # vc_crash_run <done|block> <boundary> <id> <draft> -> prints the returncode
  local op="$1" boundary="$2" id="$3" draft="$4"
  rm -f "$VD_ROOT/pycrash.mark"
  env SESSION_SCHEDULER_HOME="$VD_HOME" SESSION_CHAT_ROOT_OVERRIDE="$VD_CHAT" SESSION_CHAT_PANE_NAME=reviewer-1 \
    SESSION_CHAT_TARGET_MESSAGES_DIR="$VD_MSGS" VD_LOG="$VD_LOG" PATH="$VC_SHIM:$PATH" VC_REAL_PY="$VC_REAL_PY" VC_PYCRASH="$VD_ROOT/pycrash.py" \
    VD_PYCRASH_AT="$boundary" VD_PYMARK="$VD_ROOT/pycrash.mark" \
    "$VC_REAL_PY" -B -I -c 'import subprocess, sys
print(subprocess.run(sys.argv[1:], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode)' \
    bash "$VD_SCRIPTS/task-$op.sh" "$id" --generation 1 --note-file "$draft" 2>/dev/null
}
vd_bad=""
for op in "done" block; do
  for boundary in before-save after-save before-notify before-outcome after-outcome; do
    id=$(vc_task); F=$(vd_tf "$id"); vd_reset_log
    D=$(vd_draft reviewer-1 "ccrash-$op-$boundary.md" "contracted crash verdict ($op/$boundary)")
    hist_before=$(jq -r '.history | length' "$F")
    rc=$(vc_crash_run "$op" "$boundary" "$id" "$D")
    if [ "$rc" != -9 ] || [ "$(cat "$VD_ROOT/pycrash.mark" 2>/dev/null)" != "$boundary" ]; then
      vd_bad="$vd_bad [$op/$boundary: SIGKILL not proven rc=$rc mark=$(cat "$VD_ROOT/pycrash.mark" 2>/dev/null)]"; continue
    fi
    events=$(jq -r '(.meta.verdict_events // {}) | length' "$F"); disp=$(vd_ndisp)
    want_status="done"; [ "$op" = block ] && want_status=blocked
    if [ "$boundary" = before-save ]; then
      # no transition, no event, no admission, history unchanged, nothing sent, draft kept
      { [ "$(jq -r .status "$F")" = review ] && [ "$events" = 0 ] && [ "$(jq -c '.contract.admission' "$F")" = null ] \
        && [ "$(jq -r '.history | length' "$F")" = "$hist_before" ] && [ -z "$disp" ] && [ -f "$D" ]; } \
        || vd_bad="$vd_bad [$op/before-save: status=$(jq -r .status "$F") events=$events disp=$disp]"
      # recovery: the dead holder's lock is reclaimed and a plain rerun commits one event
      vd reviewer-1 "task-$op.sh" "$id" --generation 1 --note-file "$D" >/dev/null 2>&1; rr=$?
      { [ "$rr" = 0 ] && [ "$(jq -r .status "$F")" = "$want_status" ] && [ "$(jq -r '.meta.verdict_events | length' "$F")" = 1 ]; } || vd_bad="$vd_bad [$op/before-save: rerun rc=$rr]"
      continue
    fi
    # committed: transition + event consistent; the notification state reflects what was recorded
    state=$(jq -r '.meta.verdict_events | to_entries[0].value.notification.state' "$F")
    want_state=pending; want_disp=""
    case "$boundary" in before-outcome) want_disp=1 ;; after-outcome) want_state=delivered; want_disp=1 ;; esac
    { [ "$(jq -r .status "$F")" = "$want_status" ] && [ "$events" = 1 ] && [ "$state" = "$want_state" ] && [ "$disp" = "$want_disp" ] \
      && [ "$(vd_artifacts "$id")" = 1 ] && [ -f "$D" ] && [ "$(jq -r '.history | length' "$F")" = "$((hist_before + 1))" ]; } \
      || vd_bad="$vd_bad [$op/$boundary: status=$(jq -r .status "$F") events=$events state=$state disp=$disp hist=$(jq -r '.history | length' "$F")/$hist_before]"
    jq -e --arg op "$op" '.meta.verdict_events | to_entries[0].value | .generation == 1 and .request_msg_id == "aaaaaaaaaaaaaaaa" and .route_to == "master-1" and .transition == (if $op == "done" then "done" else "blocked" end)' "$F" >/dev/null 2>&1 \
      || vd_bad="$vd_bad [$op/$boundary: event record: $(jq -c '.meta.verdict_events' "$F")]"
    if [ "$op" = "done" ]; then
      # admission digest preserved and inspect still admits, whatever the notification state
      { [ "$(vc_digest_ok "$F")" = True ] && [ "$(vd master-1 task-contract.sh inspect "$id" 2>/dev/null | jq -r .state)" = admitted ]; } || vd_bad="$vd_bad [$op/$boundary: admission digest/inspect]"
    else
      [ "$(jq -r .contract.reconciled "$F")" = false ] || vd_bad="$vd_bad [$op/$boundary: blocked contract state]"
    fi
    # task-status is truthful and observational
    before=$(vd_tree_sum); st=$(vd master-1 task-status.sh "$id" 2>&1); after=$(vd_tree_sum)
    if [ "$want_state" = pending ]; then
      { echo "$st" | grep -q 'UNCONFIRMED' && echo "$st" | grep -q 'notification: pending'; } || vd_bad="$vd_bad [$op/$boundary: status does not show unconfirmed]"
    else
      { echo "$st" | grep -q 'notification: delivered' && ! echo "$st" | grep -q 'UNCONFIRMED'; } || vd_bad="$vd_bad [$op/$boundary: status wording after recorded outcome]"
    fi
    [ "$before" = "$after" ] || vd_bad="$vd_bad [$op/$boundary: task-status wrote]"
    # no replay: the rerun is refused, nothing more is sent, event/artifact/state unchanged
    n0=$(vd_ndisp)
    vd reviewer-1 "task-$op.sh" "$id" --generation 1 --note-file "$D" >/dev/null 2>&1; rr=$?
    { [ "$rr" != 0 ] && [ "$(jq -r '.meta.verdict_events | length' "$F")" = 1 ] && [ "$(vd_artifacts "$id")" = 1 ] && [ "$(vd_ndisp)" = "$n0" ] \
      && [ "$(jq -r '.meta.verdict_events | to_entries[0].value.notification.state' "$F")" = "$want_state" ]; } || vd_bad="$vd_bad [$op/$boundary: rerun rc=$rr replayed]"
    [ "$op" = block ] || [ "$(vc_digest_ok "$F")" = True ] || vd_bad="$vd_bad [$op/$boundary: digest changed by the refused rerun]"
  done
  # control: the same shim with the hook never armed is an ordinary delivered run
  id=$(vc_task); F=$(vd_tf "$id"); vd_reset_log; D=$(vd_draft reviewer-1 "ccrash-$op-control.md" "no crash")
  ( export PATH="$VC_SHIM:$PATH" VC_REAL_PY="$VC_REAL_PY" VC_PYCRASH="$VD_ROOT/pycrash.py" VD_PYCRASH_AT=; vd reviewer-1 "task-$op.sh" "$id" --generation 1 --note-file "$D" ) >/dev/null 2>&1; nc_rc=$?
  { [ "$nc_rc" = 0 ] && [ "$(jq -r '.meta.verdict_events | to_entries[0].value.notification.state' "$F")" = delivered ] && [ ! -e "$D" ] \
    && { [ "$op" = block ] || [ "$(vc_digest_ok "$F")" = True ]; }; } || vd_bad="$vd_bad [$op uncrashed control rc=$nc_rc]"
done
if [ -z "$vd_bad" ]; then pass "contracted_crash_boundaries_sigkill_consistent_pending_no_replay"
else fail "contracted_crash_boundaries_sigkill_consistent_pending_no_replay" "$vd_bad"; fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
MAIN_RC=0
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  MAIN_RC=1
fi

# Tier 1.3a diagnostics suite (its own counters and summary; the count above is unchanged).
if [ -f "$HERE/test-diagnostics.sh" ]; then
  echo
  bash "$HERE/test-diagnostics.sh" || MAIN_RC=1
fi
exit "$MAIN_RC"
