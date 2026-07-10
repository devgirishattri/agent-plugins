#!/usr/bin/env bash
# test-session-manager.sh — destructive-safety tests for the delete helpers:
# both delete-session.sh and delete-all-sessions.sh require an explicit
# --confirmed capability flag (the /session-delete command passes it only after
# an AskUserQuestion default-cancel confirmation). Runs against a fake $HOME so
# it never touches real session data.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP=$(mktemp -d)
PASS=0; FAIL=0; FAILURES=()
pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1: $2"); echo "  FAIL  $1 — $2"; }
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "=== session-manager tests ==="

UUID="b3591ff4-9c80-4119-b0a2-ea47524297d4"

# --- single-session delete: refusal without --confirmed ---
FAKE="$TMP/home"
PROJDIR="$FAKE/.claude/projects/-Users-x-proj"
mkdir -p "$PROJDIR" "$FAKE/.claude/session-env/$UUID"
printf '{}' > "$PROJDIR/$UUID.jsonl"
out=$(HOME="$FAKE" bash "$HERE/delete-session.sh" "$UUID" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "REFUSED" && [ -f "$PROJDIR/$UUID.jsonl" ]; then
  pass "delete_refuses_without_confirmed"
else
  fail "delete_refuses_without_confirmed" "rc=$rc out=$out"
fi

# --- single-session delete: confirmed success ---
out=$(HOME="$FAKE" bash "$HERE/delete-session.sh" "$UUID" --confirmed 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$PROJDIR/$UUID.jsonl" ] && [ ! -d "$FAKE/.claude/session-env/$UUID" ]; then
  pass "delete_confirmed_success"
else
  fail "delete_confirmed_success" "rc=$rc out=$out"
fi

# --- invalid UUID rejected even with --confirmed ---
out=$(HOME="$FAKE" bash "$HERE/delete-session.sh" "not-a-uuid" --confirmed 2>&1); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "Invalid session ID"; then
  pass "delete_invalid_uuid_rejected"
else
  fail "delete_invalid_uuid_rejected" "rc=$rc out=$out"
fi

# --- bulk delete: refusal without --confirmed, then confirmed success ---
BULK="$TMP/bulk"
BPROJ="$BULK/.claude/projects/-tmp-proj"
mkdir -p "$BPROJ"
printf '{}' > "$BPROJ/$UUID.jsonl"
out=$(HOME="$BULK" bash "$HERE/delete-all-sessions.sh" "/tmp/proj" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "REFUSED" && [ -f "$BPROJ/$UUID.jsonl" ]; then
  pass "bulk_delete_refuses_without_confirmed"
else
  fail "bulk_delete_refuses_without_confirmed" "rc=$rc out=$out"
fi
out=$(HOME="$BULK" bash "$HERE/delete-all-sessions.sh" "/tmp/proj" --confirmed 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ ! -f "$BPROJ/$UUID.jsonl" ]; then
  pass "bulk_delete_confirmed_success"
else
  fail "bulk_delete_confirmed_success" "rc=$rc out=$out"
fi

# --- bulk delete still refuses a global wipe ---
out=$(HOME="$BULK" bash "$HERE/delete-all-sessions.sh" "all" --confirmed 2>&1); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "Refusing a global wipe"; then
  pass "bulk_delete_refuses_global_wipe"
else
  fail "bulk_delete_refuses_global_wipe" "rc=$rc out=$out"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
