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
if grep -q "Shared ledger:" "$ah_prompt" 2>/dev/null \
   && grep -qF "export SESSION_SCHEDULER_HOME=$(printf '%q' "$abs_expected")" "$ah_prompt" 2>/dev/null \
   && [ "$ah_home" = "$abs_expected" ]; then
  pass "abs_home_propagation"
else
  fail "abs_home_propagation" "home=$ah_home expected=$abs_expected prompt=$(cat "$ah_prompt" 2>/dev/null)"
fi

# --- Test 30: --context auto generates an immutable handoff (removed on rollback) ---
AUTO_CTX_DIR="$TMP/contexts"
mkdir -p "$AUTO_CTX_DIR"
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "auto-ctx" 2>&1)
AC_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CONTEXT_HOME="$AUTO_CTX_DIR" bash "$HERE/task-assign.sh" worker-1 "$AC_ID" --context auto "auto handoff work" >/dev/null 2>&1
# Name is unique per assignment (auto-<id>-<rand>) for true immutability — derive
# the actual file from the recorded meta.context rather than assuming it.
meta_ctx=$(jq -r '.meta.context // empty' "$SESSION_SCHEDULER_HOME/tasks/$AC_ID.json")
auto_file="$AUTO_CTX_DIR/$meta_ctx.md"
perms_ok=""
[ -f "$auto_file" ] && perms_ok=$(stat -f '%Lp' "$auto_file" 2>/dev/null || stat -c '%a' "$auto_file" 2>/dev/null)
name_ok=$(printf '%s' "$meta_ctx" | grep -qE "^auto-$AC_ID-[0-9a-f]+$" && echo yes || echo no)
# rollback: a dispatch failure must remove the auto handoff (none left for AC_RB)
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "auto-ctx-rb" 2>&1)
AC_RB=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" SESSION_CONTEXT_HOME="$AUTO_CTX_DIR" SESSION_CHAT_ROOT_OVERRIDE="$TMP/session-chat-failstub" bash "$HERE/task-assign.sh" worker-1 "$AC_RB" --context auto "doomed" >/dev/null 2>&1
rb_count=$(find "$AUTO_CTX_DIR" -name "auto-$AC_RB-*.md" 2>/dev/null | wc -l | tr -d ' ')
if [ -f "$auto_file" ] && [ "$name_ok" = "yes" ] && [ "$perms_ok" = "400" ] \
   && grep -q "Auto handoff" "$auto_file" && grep -q "auto handoff work" "$auto_file" \
   && [ "$rb_count" = "0" ]; then
  pass "context_auto_immutable"
else
  fail "context_auto_immutable" "file=$([ -f "$auto_file" ] && echo yes || echo no) name_ok=$name_ok perms=$perms_ok meta=$meta_ctx rb_count=$rb_count"
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

# --- Test 33: assignment + review packets list BOTH provider forms + exact export ---
out=$(SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-new.sh" "mixed-prov" 2>&1)
MX_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-assign.sh" worker-1 "$MX_ID" --reviewer auditor "mixed work" >/dev/null 2>&1
apf="$SESSION_SCHEDULER_HOME/prompts/$MX_ID.md"
SESSION_SCHEDULER_HOME="$SESSION_SCHEDULER_HOME" bash "$HERE/task-review.sh" "$MX_ID" "sha-mixed" >/dev/null 2>&1
rpf="$SESSION_SCHEDULER_HOME/prompts/$MX_ID-review.md"
if grep -qF "/session-scheduler:task-done $MX_ID" "$apf" && grep -qF "\$session-scheduler:task-done $MX_ID" "$apf" \
   && grep -qF "export SESSION_SCHEDULER_HOME=" "$apf" \
   && grep -qF "/session-scheduler:task-done $MX_ID" "$rpf" && grep -qF "\$session-scheduler:task-done $MX_ID" "$rpf" \
   && grep -qF "export SESSION_SCHEDULER_HOME=" "$rpf"; then
  pass "mixed_provider_packets"
else
  fail "mixed_provider_packets" "apf/rpf missing dual forms or export"
fi

# --- Test 34: ledger dirs are 0700 and task/prompt files 0600 (umask 077) ---
mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }
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
    echo "DIR=$(stat -f '%Lp' "$H/tasks" 2>/dev/null || stat -c '%a' "$H/tasks" 2>/dev/null)"
    echo "FILE=$(stat -f '%Lp' "$H/tasks/legacy.json" 2>/dev/null || stat -c '%a' "$H/tasks/legacy.json" 2>/dev/null)"
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
d_mode=$(stat -f '%Lp' "$RACE/tasks" 2>/dev/null || stat -c '%a' "$RACE/tasks" 2>/dev/null)
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

# --- Test 43: assignment export uses %q (spaces + apostrophe copy-paste safe) ---
WQH="$TMP/sched home's weird"
mkdir -p "$WQH"
out=$(SESSION_SCHEDULER_HOME="$WQH" bash "$HERE/task-new.sh" "wq" 2>&1)
WQ_ID=$(echo "$out" | awk '/Created task:/ {print $3}')
SESSION_SCHEDULER_HOME="$WQH" bash "$HERE/task-assign.sh" worker-1 "$WQ_ID" "wq work" >/dev/null 2>&1
wq_pf="$WQH/prompts/$WQ_ID.md"
wq_abs=$(cd "$WQH" && pwd -P)
wq_expected="export SESSION_SCHEDULER_HOME=$(printf '%q' "$wq_abs")"
wq_safe=$(bash -c "$wq_expected; printf '%s' \"\$SESSION_SCHEDULER_HOME\"")
if grep -qF "$wq_expected" "$wq_pf" 2>/dev/null && [ "$wq_safe" = "$wq_abs" ]; then
  pass "assignment_export_quoted_special_path"
else
  fail "assignment_export_quoted_special_path" "expected=$wq_expected safe=$wq_safe"
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

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
