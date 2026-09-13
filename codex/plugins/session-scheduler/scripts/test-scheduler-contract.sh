#!/usr/bin/env bash
# Targeted 0.6.0 regressions; transport is mocked and no tmux server is touched.
set -euo pipefail
CONTRACT_SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
CONTRACT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/scheduler-contract.XXXXXX")"
trap 'rm -rf "$CONTRACT_TMP"' EXIT
export SESSION_SCHEDULER_HOME="$CONTRACT_TMP/scheduler"
export SESSION_CHAT_ROOT_OVERRIDE="$CONTRACT_TMP/chat"
export TMUX_PANE=contract-pane
unset SESSION_CONTEXT_HOME
tmux() { printf 'contract-owner\n'; }
export -f tmux
source "$CONTRACT_SCRIPTS/lib.sh"
ensure_dirs
ASSERTIONS=0
check() { if "$@" > /dev/null; then ASSERTIONS=$((ASSERTIONS + 1)); else echo "FAIL: $*" >&2; exit 1; fi; }
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
seed() {
  jq -n --arg id "$1" --arg status "$2" --arg assigner "${3:-other}" \
    --arg assignee "${4:-other}" --arg reviewer "${5:-other}" \
    '{id:$id,name:$id,status:$status,assigner:$assigner,assignee:$assignee,
      reviewer:$reviewer,stage:"execute",depends_on:[],meta:{},history:[],
      updated_at:"2026-01-01T00:00:00Z",created_at:"2026-01-01T00:00:00Z"}' \
    > "$TASKS_DIR/$1.json"
}
mkdir -p "$SESSION_CHAT_ROOT_OVERRIDE/.codex-plugin" "$SESSION_CHAT_ROOT_OVERRIDE/scripts"
printf '{"version":"0.17.9"}\n' > "$SESSION_CHAT_ROOT_OVERRIDE/.codex-plugin/plugin.json"
printf '%s\n' '#!/usr/bin/env bash' \
  'test ! -d "$SESSION_SCHEDULER_HOME/locks/auto-task.lock" || exit 91' \
  'exit "${CONTRACT_DISPATCH_RESULT:-0}"' \
  > "$SESSION_CHAT_ROOT_OVERRIDE/scripts/dispatch-to-session.sh"

# Both locked APIs preserve all updates made by independent writer processes.
seed concurrent assigned
export CONTRACT_SCRIPTS
pids=()
for iteration in 1 2 3 4 5 6 7 8; do
  : "$iteration"
  bash -c 'source "$CONTRACT_SCRIPTS/lib.sh"; task_jq_update "$TASKS_DIR/concurrent.json" ".meta.count = ((.meta.count // 0) + 1)"' &
  pids+=("$!")
  bash -c 'source "$CONTRACT_SCRIPTS/lib.sh"; append_history_update "$TASKS_DIR/concurrent.json" assigned assigned worker note' &
  pids+=("$!")
done
for pid in "${pids[@]}"; do check wait "$pid"; done
check jq -e '.meta.count == 8 and (.history | length) == 8' "$TASKS_DIR/concurrent.json"
check test ! -e "$LOCKS_DIR/concurrent.lock"

# A known live holder cannot be reclaimed; a confirmed dead one can.
mkdir "$LOCKS_DIR/concurrent.lock"
printf '%s\n' "$$" > "$LOCKS_DIR/concurrent.lock/pid"
if SESSION_SCHEDULER_LOCK_TIMEOUT_SECS=0 bash -c 'source "$CONTRACT_SCRIPTS/lib.sh"; acquire_task_lock concurrent' > "$CONTRACT_TMP/live.out" 2>&1; then
  echo 'FAIL: live lock was reclaimed' >&2; exit 1
fi
check grep -F "$LOCKS_DIR/concurrent.lock" "$CONTRACT_TMP/live.out"
check test "$(cat "$LOCKS_DIR/concurrent.lock/pid")" = "$$"
if SESSION_SCHEDULER_LOCK_TIMEOUT_SECS=0 bash -c '
  source "$CONTRACT_SCRIPTS/lib.sh"
  kill() { echo "kill: Operation not permitted" >&2; return 1; }
  acquire_task_lock concurrent
' > "$CONTRACT_TMP/eperm.out" 2>&1; then
  echo 'FAIL: permission-denied holder was reclaimed' >&2; exit 1
fi
check grep -F 'timed out acquiring task lock' "$CONTRACT_TMP/eperm.out"
check test "$(cat "$LOCKS_DIR/concurrent.lock/pid")" = "$$"
bash -c 'exit 0' & dead_pid=$!
wait "$dead_pid"
printf '%s\n' "$dead_pid" > "$LOCKS_DIR/concurrent.lock/pid"
check bash -c 'source "$CONTRACT_SCRIPTS/lib.sh"; task_jq_update "$TASKS_DIR/concurrent.json" ".meta.reclaimed=true"'
check jq -e '.meta.reclaimed == true' "$TASKS_DIR/concurrent.json"
check test ! -e "$LOCKS_DIR/concurrent.lock"

# Ten waiters reclaim the same dead holder without stranding an empty lock.
mkdir "$LOCKS_DIR/concurrent.lock"
printf '%s\n' "$dead_pid" > "$LOCKS_DIR/concurrent.lock/pid"
pids=()
for iteration in 1 2 3 4 5 6 7 8 9 10; do
  : "$iteration"
  bash -c 'source "$CONTRACT_SCRIPTS/lib.sh"; task_jq_update "$TASKS_DIR/concurrent.json" ".meta.takeovers = ((.meta.takeovers // 0) + 1)"' &
  pids+=("$!")
done
for pid in "${pids[@]}"; do check wait "$pid"; done
check jq -e '.meta.takeovers == 10' "$TASKS_DIR/concurrent.json"
check test ! -e "$LOCKS_DIR/concurrent.lock"

seed pending created contract-owner
seed mine-assignee assigned other contract-owner
seed mine-reviewer review other other contract-owner
seed unrelated assigned
bash "$CONTRACT_SCRIPTS/task-status.sh" --pending > "$CONTRACT_TMP/pending"
check test "$(awk 'NR>1 {print $1}' "$CONTRACT_TMP/pending")" = pending
bash "$CONTRACT_SCRIPTS/task-status.sh" --mine > "$CONTRACT_TMP/mine"
check test "$(awk 'NR>1 {print $1}' "$CONTRACT_TMP/mine" | sort | tr '\n' ' ')" = 'mine-assignee mine-reviewer pending '

# Every trailing value-taking assignment flag exits promptly and explains why.
for flag in --eta --stage --context --reviewer --workflow --workflow-id; do
  bash "$CONTRACT_SCRIPTS/task-assign.sh" recipient pending "$flag" > "$CONTRACT_TMP/parser" 2>&1 & parser_pid=$!
  (sleep 3; kill "$parser_pid" 2>/dev/null || true) & watchdog_pid=$!
  result=0
  wait "$parser_pid" || result=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  check test "$result" -ne 0
  check grep -F "ERROR: $flag requires a value" "$CONTRACT_TMP/parser"
done

seed auto-task created contract-owner
bash "$CONTRACT_SCRIPTS/task-assign.sh" recipient auto-task --context auto 'approved prompt' > "$CONTRACT_TMP/assignment"
handoff=$(jq -r '.meta.handoff_file' "$TASKS_DIR/auto-task.json")
check test -f "$handoff"
check test "$(jq -r '.meta.handoff_home' "$TASKS_DIR/auto-task.json")" = "$(cd "$HANDOFFS_DIR" && pwd -P)"
check test "$(mode "$handoff")" = 600
check test "$(mode "$(dirname "$handoff")")" = 700
check test "$(basename "$handoff" .md | wc -c | tr -d ' ')" = 33
check bash -c '[[ $(basename "$1") =~ ^[a-f0-9]{32}\.md$ ]]' _ "$handoff"
check jq -e '.meta | has("context") == false and has("context_home") == false' "$TASKS_DIR/auto-task.json"
check grep -F 'Auto handoff (read it first):' "$PROMPTS_DIR/auto-task.md"
check grep -F -- '- stage: execute' "$handoff"
check grep -F -- '- status before assignment: created' "$handoff"
check grep -F 'approved prompt' "$handoff"
check grep -F 'no live-session summarization' "$handoff"
check test "$(awk '/^## / {print}' "$handoff" | tr '\n' '|')" = '## Task|## Dispatched prompt|'
check grep -F '  handoff:  ' "$CONTRACT_TMP/assignment"
original_digest=$(cksum "$handoff")
export SESSION_CONTEXT_HOME="$CONTRACT_TMP/contexts"
mkdir "$SESSION_CONTEXT_HOME"
printf 'existing context\n' > "$SESSION_CONTEXT_HOME/existing.md"
bash "$CONTRACT_SCRIPTS/task-assign.sh" recipient auto-task --context existing 'explicit assignment' > /dev/null
check jq -e '.meta | .context == "existing" and has("handoff_file") == false and has("handoff_home") == false' "$TASKS_DIR/auto-task.json"
check grep -F 'context-load existing' "$PROMPTS_DIR/auto-task.md"
export SESSION_CONTEXT_HOME="$CONTRACT_TMP/must-not-be-created"
bash "$CONTRACT_SCRIPTS/task-assign.sh" recipient auto-task --context auto 'second auto' > /dev/null
check test ! -e "$SESSION_CONTEXT_HOME"
check test "$(jq -r '.meta.handoff_file' "$TASKS_DIR/auto-task.json")" != "$handoff"
check test "$(cksum "$handoff")" = "$original_digest"
check jq -e '.meta | has("context") == false and has("context_home") == false' "$TASKS_DIR/auto-task.json"

# Failed dispatch removes only the new auto artifact and the empty task folder.
seed rollback created
if CONTRACT_DISPATCH_RESULT=1 bash "$CONTRACT_SCRIPTS/task-assign.sh" recipient rollback --context auto 'failed assignment' > /dev/null 2>&1; then
  echo 'FAIL: failed dispatch reported success' >&2; exit 1
fi
check test ! -e "$HANDOFFS_DIR/rollback"
check test ! -e "$PROMPTS_DIR/rollback.md"
check jq -e '.status == "created" and (.meta | has("handoff_file") == false)' "$TASKS_DIR/rollback.json"
printf 'PASS: %s contract assertions\n' "$ASSERTIONS"
