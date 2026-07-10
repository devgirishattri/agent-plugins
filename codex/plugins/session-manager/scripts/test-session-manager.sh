#!/usr/bin/env bash
# Hermetic smoke tests for guarded native Codex session deletion.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TMP_BASE="${TMPDIR:-/tmp}"
TMP_ROOT=$(mktemp -d "${TMP_BASE%/}/session-manager-test.XXXXXX")
CODEX_HOME="$TMP_ROOT/codex-home"
MOCK_BIN="$TMP_ROOT/bin"
PROJECT="$TMP_ROOT/project"
OTHER_PROJECT="$TMP_ROOT/other-project"
SESSION_MANAGER_TEST_LOG="$TMP_ROOT/codex-calls.log"

UUID_ONE="11111111-1111-4111-8111-111111111111"
UUID_TWO="22222222-2222-4222-8222-222222222222"
UUID_OTHER="33333333-3333-4333-8333-333333333333"

cleanup() {
    case "$TMP_ROOT" in
        "${TMP_BASE%/}"/session-manager-test.*) rm -rf "$TMP_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    [ "$actual" = "$expected" ] || fail "$label (expected '$expected', got '$actual')"
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local label="$3"
    case "$haystack" in
        *"$needle"*) ;;
        *) fail "$label (missing '$needle')" ;;
    esac
}

assert_log_empty() {
    [ ! -s "$SESSION_MANAGER_TEST_LOG" ] || fail "$1 invoked native Codex unexpectedly"
}

assert_session_file_exists() {
    local session_id="$1"
    [ -f "$CODEX_HOME/sessions/2026/07/10/rollout-$session_id.jsonl" ] || fail "$2 removed rollout data directly"
}

write_session() {
    local session_id="$1"
    local project_path="$2"
    local title="$3"
    local session_file="$CODEX_HOME/sessions/2026/07/10/rollout-$session_id.jsonl"

    printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$session_id" "$project_path" > "$session_file"
    printf '{"type":"event_msg","payload":{"type":"user_message","message":"%s"}}\n' "$title" >> "$session_file"
}

mkdir -p "$CODEX_HOME/sessions/2026/07/10" "$MOCK_BIN" "$PROJECT" "$OTHER_PROJECT"
ln -s "$SCRIPT_DIR/test-codex-mock.sh" "$MOCK_BIN/codex"
: > "$SESSION_MANAGER_TEST_LOG"

export CODEX_HOME SESSION_MANAGER_TEST_LOG
PATH="$MOCK_BIN:$PATH"
export PATH

write_session "$UUID_ONE" "$PROJECT" "First session"
write_session "$UUID_TWO" "$PROJECT" "Second session"
write_session "$UUID_OTHER" "$OTHER_PROJECT" "Other project session"

output=$(cd "$PROJECT" && bash "$SCRIPT_DIR/prepare-delete.sh" "")
assert_contains "$output" "$(printf 'STATUS\tSELECT')" "empty target should request selection"
assert_log_empty "empty-target resolution"
assert_session_file_exists "$UUID_ONE" "empty-target resolution"

output=$(bash "$SCRIPT_DIR/prepare-delete.sh" "$UUID_ONE")
assert_contains "$output" "$(printf 'STATUS\tONE')" "exact UUID should resolve one session"
assert_contains "$output" "$UUID_ONE" "exact UUID result should include the UUID"
assert_log_empty "single-target preparation"
assert_session_file_exists "$UUID_ONE" "single-target preparation"

output=$(bash "$SCRIPT_DIR/delete-resolved-session.sh" "$UUID_ONE")
assert_contains "$output" "$(printf 'STATUS\tONE')" "legacy resolver should remain read-only"
assert_log_empty "legacy resolution"
assert_session_file_exists "$UUID_ONE" "legacy resolution"

set +e
output=$(bash "$SCRIPT_DIR/delete-session.sh" "$UUID_ONE" 2>&1)
status=$?
set -e
assert_eq "2" "$status" "single delete without confirmation should be cancelled"
assert_contains "$output" "Explicit final confirmation is required" "single-delete cancellation message"
assert_log_empty "unconfirmed single deletion"
assert_session_file_exists "$UUID_ONE" "unconfirmed single deletion"

set +e
output=$(bash "$SCRIPT_DIR/delete-session.sh" "not-a-uuid" --confirmed 2>&1)
status=$?
set -e
assert_eq "1" "$status" "invalid UUID should fail"
assert_contains "$output" "Invalid session ID format" "invalid UUID error"
assert_log_empty "invalid UUID deletion"

output=$(bash "$SCRIPT_DIR/delete-session.sh" "$UUID_ONE" --confirmed)
assert_contains "$output" "$(printf 'delete\t--force\t%s' "$UUID_ONE")" "confirmed delete should call native Codex"
expected=$(printf 'CODEX_HOME=%s\tdelete\t--force\t%s' "$CODEX_HOME" "$UUID_ONE")
actual=$(tail -1 "$SESSION_MANAGER_TEST_LOG")
assert_eq "$expected" "$actual" "native single-delete invocation"

: > "$SESSION_MANAGER_TEST_LOG"
set +e
output=$(cd "$PROJECT" && bash "$SCRIPT_DIR/delete-all-sessions.sh" 2>&1)
status=$?
set -e
assert_eq "2" "$status" "bulk delete without confirmation should be cancelled"
assert_contains "$output" "Explicit final confirmation is required" "bulk cancellation message"
assert_log_empty "unconfirmed bulk deletion"
assert_session_file_exists "$UUID_ONE" "unconfirmed bulk deletion"
assert_session_file_exists "$UUID_TWO" "unconfirmed bulk deletion"

output=$(cd "$PROJECT" && bash "$SCRIPT_DIR/delete-all-sessions.sh" --confirmed)
assert_contains "$output" "Sessions: 2 processed | 2 fully deleted | 0 with failures" "confirmed bulk summary"
call_count=$(wc -l < "$SESSION_MANAGER_TEST_LOG" | tr -d ' ')
assert_eq "2" "$call_count" "bulk native invocation count"
grep -qF "$(printf '\tdelete\t--force\t%s' "$UUID_ONE")" "$SESSION_MANAGER_TEST_LOG" || fail "bulk delete missed first project UUID"
grep -qF "$(printf '\tdelete\t--force\t%s' "$UUID_TWO")" "$SESSION_MANAGER_TEST_LOG" || fail "bulk delete missed second project UUID"
if grep -qF "$UUID_OTHER" "$SESSION_MANAGER_TEST_LOG"; then
    fail "bulk delete crossed the current-project boundary"
fi

echo "session-manager smoke tests: PASS"
