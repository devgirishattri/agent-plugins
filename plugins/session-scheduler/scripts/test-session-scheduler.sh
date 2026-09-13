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

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
