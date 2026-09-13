#!/usr/bin/env bash
# Focused cleanup contract regression tests, no tmux required.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/scheduler-clean-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
export SESSION_SCHEDULER_HOME="$TEST_DIR/ledger"
source "$SCRIPT_DIR/lib.sh"
ensure_dirs
fixture() {
  jq -n --arg id "$1" --arg status "$2" --argjson deps "$3" \
    '{id:$id,status:$status,depends_on:$deps,updated_at:"2000-01-01T00:00:00Z"}' > "$TASKS_DIR/$1.json"
}
fixture a 'done' '[]'
fixture b 'done' '["a"]'
fixture c created '["b"]'
bash "$SCRIPT_DIR/tasks-clean.sh" --older-than 1 --status 'done' --apply > "$TEST_DIR/out"
[ -f "$TASKS_DIR/a.json" ] && [ -f "$TASKS_DIR/b.json" ]
rg -q 'kept a \(referenced by b\)' "$TEST_DIR/out"
fixture d 'done' '[]'
fixture d-child created '[]'
for suffix in '' -review -ack-done -ack-blocked -ack-review; do
  printf 'packet\n' > "$PROMPTS_DIR/d$suffix.md"
done
printf 'other task\n' > "$PROMPTS_DIR/d-child.md"
mkdir -p "$SCHEDULER_DIR/handoffs/d"
printf 'handoff\n' > "$SCHEDULER_DIR/handoffs/d/nonce.md"
bash "$SCRIPT_DIR/tasks-clean.sh" --older-than 1 --status 'done' --apply > "$TEST_DIR/out"
[ ! -e "$TASKS_DIR/d.json" ] && [ ! -e "$SCHEDULER_DIR/handoffs/d" ]
[ ! -e "$SCHEDULER_DIR/locks/d.lock" ] && [ -f "$PROMPTS_DIR/d-child.md" ]
for suffix in '' -review -ack-done -ack-blocked -ack-review; do
  [ ! -e "$PROMPTS_DIR/d$suffix.md" ]
done
mkdir -p "$SCHEDULER_DIR/handoffs/orphan"
printf 'old\n' > "$PROMPTS_DIR/orphan-review.md"
printf 'fresh\n' > "$PROMPTS_DIR/fresh.md"
touch -t 200001010000 "$PROMPTS_DIR/orphan-review.md" "$SCHEDULER_DIR/handoffs/orphan"
bash "$SCRIPT_DIR/tasks-clean.sh" --older-than 1 > "$TEST_DIR/out"
rg -q '^Orphans:' "$TEST_DIR/out"
[ -e "$PROMPTS_DIR/orphan-review.md" ]
bash "$SCRIPT_DIR/tasks-clean.sh" --older-than 1 --apply > "$TEST_DIR/out"
[ ! -e "$PROMPTS_DIR/orphan-review.md" ] && [ ! -e "$SCHEDULER_DIR/handoffs/orphan" ]
[ -e "$PROMPTS_DIR/fresh.md" ]
for flag in --older-than --status; do
  if bash "$SCRIPT_DIR/tasks-clean.sh" "$flag" >/dev/null 2>&1; then
    echo "FAIL: missing value accepted: $flag" >&2; exit 1
  fi
done
echo 'PASS: cleanup fixed-point dependencies, exact artifacts, orphan age/dry-run, bare days, missing values'
