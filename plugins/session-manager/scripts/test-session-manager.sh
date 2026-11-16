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

# --- symlink-parent escape (NON-project dir): a symlinked file-history dir
#     pointing out of ~/.claude is REFUSED, its out-of-tree sentinel preserved,
#     the refusal is explicit (REFUSED + nonzero), and in-boundary data still
#     deletes. Proves canonical containment covers every destructive path, not
#     just projects/*. ---
SLC="$TMP/sl_fh/.claude"
mkdir -p "$SLC/projects/-Users-x-proj" "$SLC/session-env/$UUID"
printf '{}' > "$SLC/projects/-Users-x-proj/$UUID.jsonl"
OUT_FH="$TMP/outside_fh"
mkdir -p "$OUT_FH/$UUID"
printf 'KEEPME' > "$OUT_FH/$UUID/precious.txt"
ln -s "$OUT_FH" "$SLC/file-history"      # symlinked non-project parent -> outside
out=$(HOME="$TMP/sl_fh" bash "$HERE/delete-session.sh" "$UUID" --confirmed 2>&1); rc=$?
if [ "$rc" -ne 0 ] \
   && echo "$out" | grep -q "REFUSED" \
   && [ -f "$OUT_FH/$UUID/precious.txt" ] && [ "$(cat "$OUT_FH/$UUID/precious.txt")" = "KEEPME" ] \
   && [ ! -f "$SLC/projects/-Users-x-proj/$UUID.jsonl" ]; then
  pass "delete_refuses_symlinked_nonproject_parent"
else
  fail "delete_refuses_symlinked_nonproject_parent" \
    "rc=$rc sentinel=$([ -f "$OUT_FH/$UUID/precious.txt" ] && echo present || echo GONE) out=$out"
fi

# --- symlink-parent escape (PROJECT dir): a symlinked encoded-project dir
#     pointing out of ~/.claude is REFUSED and its out-of-tree transcript +
#     subagent data preserved. ---
SLPC="$TMP/sl_proj/.claude"
mkdir -p "$SLPC/projects"
OUT_PROJ="$TMP/outside_proj"
mkdir -p "$OUT_PROJ/$UUID"
printf '{}' > "$OUT_PROJ/$UUID.jsonl"
printf 'AGENTKEEP' > "$OUT_PROJ/$UUID/data.txt"
ln -s "$OUT_PROJ" "$SLPC/projects/-evil-proj"   # symlinked project parent -> outside
out=$(HOME="$TMP/sl_proj" bash "$HERE/delete-session.sh" "$UUID" --confirmed 2>&1); rc=$?
if [ "$rc" -ne 0 ] \
   && echo "$out" | grep -q "REFUSED" \
   && [ -f "$OUT_PROJ/$UUID.jsonl" ] && [ -f "$OUT_PROJ/$UUID/data.txt" ]; then
  pass "delete_refuses_symlinked_project_parent"
else
  fail "delete_refuses_symlinked_project_parent" \
    "rc=$rc jsonl=$([ -f "$OUT_PROJ/$UUID.jsonl" ] && echo present || echo GONE) sub=$([ -f "$OUT_PROJ/$UUID/data.txt" ] && echo present || echo GONE) out=$out"
fi

# --- bulk delete: a project path that RESOLVES outside projects/ (symlinked
#     encoded-project dir) fails LOUDLY (REFUSED + nonzero), never a benign
#     no-sessions, and never touches the out-of-tree target. ---
BSLC="$TMP/bulk_sl/.claude"
mkdir -p "$BSLC/projects"
OUT_BULK="$TMP/outside_bulk"
mkdir -p "$OUT_BULK"
printf '{}' > "$OUT_BULK/$UUID.jsonl"
printf 'BULKKEEP' > "$OUT_BULK/keep.txt"
ln -s "$OUT_BULK" "$BSLC/projects/-tmp-evilbulk"
out=$(HOME="$TMP/bulk_sl" bash "$HERE/delete-all-sessions.sh" "/tmp/evilbulk" --confirmed 2>&1); rc=$?
if [ "$rc" -ne 0 ] \
   && echo "$out" | grep -q "REFUSED" \
   && [ -f "$OUT_BULK/$UUID.jsonl" ] && [ -f "$OUT_BULK/keep.txt" ]; then
  pass "bulk_delete_refuses_outside_projects"
else
  fail "bulk_delete_refuses_outside_projects" "rc=$rc out=$out"
fi

# --- bulk delete: a genuinely MISSING project stays benign (no sessions, rc 0).
#     (Distinguishes an unsafe escape from an ordinary absent target.) ---
out=$(HOME="$TMP/bulk_sl" bash "$HERE/delete-all-sessions.sh" "/tmp/definitely-absent-$$" --confirmed 2>&1); rc=$?
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "No sessions found"; then
  pass "bulk_delete_missing_target_benign"
else
  fail "bulk_delete_missing_target_benign" "rc=$rc out=$out"
fi

# --- hardlinked history.jsonl.lock: a confirmed delete must REFUSE (nonzero) and
#     never truncate the out-of-tree file the lock hardlinks to. Covers safe_leaf
#     (link count != 1) plus the non-truncating lock open. ---
HLC="$TMP/hist_hl/.claude"
mkdir -p "$HLC/projects/-Users-x-proj"
printf '{}' > "$HLC/projects/-Users-x-proj/$UUID.jsonl"
printf '{"sessionId":"%s"}\n' "$UUID" > "$HLC/history.jsonl"
OUT_LOCK="$TMP/outside_lock.txt"
printf 'LOCKSENTINEL' > "$OUT_LOCK"
ln "$OUT_LOCK" "$HLC/history.jsonl.lock"       # hardlink (link count 2) to outside
out=$(HOME="$TMP/hist_hl" bash "$HERE/delete-session.sh" "$UUID" --confirmed 2>&1); rc=$?
if [ "$rc" -ne 0 ] \
   && echo "$out" | grep -q "REFUSED" \
   && [ -f "$OUT_LOCK" ] && [ "$(cat "$OUT_LOCK")" = "LOCKSENTINEL" ]; then
  pass "delete_refuses_hardlinked_history_lock"
else
  fail "delete_refuses_hardlinked_history_lock" \
    "rc=$rc sentinel=$(cat "$OUT_LOCK" 2>/dev/null) out=$out"
fi

# --- history flock acquisition failure is reported as FAILED (nonzero), never a
#     false "Removed", and the matching history row is preserved. Regression for
#     the subshell-exit bug where a lock failure was misreported as success and
#     the counter mutation was lost inside the subshell. A fake `flock` first on
#     PATH forces the flock branch and always fails to acquire. ---
FLK="$TMP/fakeflock"
mkdir -p "$FLK"
cat > "$FLK/flock" <<'FAKEFLOCK'
#!/usr/bin/env bash
exit 1
FAKEFLOCK
chmod +x "$FLK/flock"
FHC="$TMP/flock_hist/.claude"
mkdir -p "$FHC/projects/-Users-x-proj"
printf '{}' > "$FHC/projects/-Users-x-proj/$UUID.jsonl"
printf '{"sessionId":"%s"}\n' "$UUID" > "$FHC/history.jsonl"
out=$(PATH="$FLK:$PATH" HOME="$TMP/flock_hist" bash "$HERE/delete-session.sh" "$UUID" --confirmed 2>&1); rc=$?
if [ "$rc" -ne 0 ] \
   && echo "$out" | grep -q "FAILED History entries" \
   && ! echo "$out" | grep -q "Removed .* entries from history.jsonl" \
   && grep -q "$UUID" "$FHC/history.jsonl"; then
  pass "history_flock_failure_reported_not_removed"
else
  fail "history_flock_failure_reported_not_removed" \
    "rc=$rc histrow=$(grep -c "$UUID" "$FHC/history.jsonl" 2>/dev/null) out=$out"
fi

# --- set-aside transcripts, per-session ~/.claude dirs and the session's temp
#     directory are all removed; another session's copies are kept. ---
OTHER="0f0e0d0c-0b0a-4908-8706-050403020100"
SAH="$TMP/aside"
SAC="$SAH/.claude"
SAP="$SAC/projects/-Users-x-proj"
mkdir -p "$SAP" "$SAC/image-cache/$UUID" "$SAC/uploads/$UUID" "$SAC/dev-mods/$UUID" "$SAC/tasks/$UUID" \
  "$SAC/image-cache/$OTHER"
printf '{}' > "$SAP/$UUID.jsonl"
printf '{}' > "$SAP/$UUID.orphaned-1794800000000-ab12.jsonl"
printf '{}' > "$SAP/$UUID.jsonl.superseded-1794800000000"
printf '{}' > "$SAP/$OTHER.orphaned-1794800000000-cd34.jsonl"
printf 'img' > "$SAC/image-cache/$UUID/1.png"
printf 'up' > "$SAC/uploads/$UUID/f.txt"
printf 'mod' > "$SAC/dev-mods/$UUID/mod.js"
printf '{}' > "$SAC/tasks/$UUID/1.json"
printf 'img' > "$SAC/image-cache/$OTHER/1.png"
CTMP="$TMP/ctmp"
TROOT="$CTMP/claude-$(id -u)"
mkdir -p "$TROOT/-Users-x-proj/$UUID/scratchpad" "$TROOT/-Users-x-proj/$OTHER/scratchpad"
printf 'scratch' > "$TROOT/-Users-x-proj/$UUID/scratchpad/notes.txt"
printf 'scratch' > "$TROOT/-Users-x-proj/$OTHER/scratchpad/notes.txt"
printf '{}' > "$TROOT/cache-break-state-$UUID.json"
printf '{}' > "$TROOT/cache-break-state-$OTHER.json"
out=$(CLAUDE_CODE_TMPDIR="$CTMP" TMPDIR="$CTMP" HOME="$SAH" bash "$HERE/delete-session.sh" "$UUID" --confirmed 2>&1); rc=$?
gone=1
for path in "$SAP/$UUID.orphaned-1794800000000-ab12.jsonl" "$SAP/$UUID.jsonl.superseded-1794800000000" \
  "$SAC/image-cache/$UUID" "$SAC/uploads/$UUID" "$SAC/dev-mods/$UUID" "$SAC/tasks/$UUID" \
  "$TROOT/-Users-x-proj/$UUID" "$TROOT/cache-break-state-$UUID.json"; do
  [ -e "$path" ] && { gone=0; echo "    still present: $path"; }
done
kept=1
for path in "$SAP/$OTHER.orphaned-1794800000000-cd34.jsonl" "$SAC/image-cache/$OTHER/1.png" \
  "$TROOT/-Users-x-proj/$OTHER/scratchpad/notes.txt" "$TROOT/cache-break-state-$OTHER.json"; do
  [ -e "$path" ] || { kept=0; echo "    removed by mistake: $path"; }
done
if [ "$rc" -eq 0 ] && [ "$gone" -eq 1 ] && [ "$kept" -eq 1 ] \
   && echo "$out" | grep -q "Deleted Set-aside transcript" && echo "$out" | grep -q "Deleted Temp directory"; then
  pass "delete_removes_set_aside_transcripts_and_session_dirs"
else
  fail "delete_removes_set_aside_transcripts_and_session_dirs" "rc=$rc out=$out"
fi

# --- temp directory reached through a symlinked project dir is REFUSED and the
#     out-of-tree target is preserved. ---
STH="$TMP/temp_sl"
mkdir -p "$STH/.claude/projects"
STMP="$TMP/stmp"
STROOT="$STMP/claude-$(id -u)"
mkdir -p "$STROOT"
OUT_TMP="$TMP/outside_tmp"
mkdir -p "$OUT_TMP/$UUID"
printf 'TMPKEEP' > "$OUT_TMP/$UUID/precious.txt"
ln -s "$OUT_TMP" "$STROOT/-evil-proj"
out=$(CLAUDE_CODE_TMPDIR="$STMP" TMPDIR="$STMP" HOME="$STH" bash "$HERE/delete-session.sh" "$UUID" --confirmed 2>&1); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "REFUSED Temp directory" \
   && [ "$(cat "$OUT_TMP/$UUID/precious.txt" 2>/dev/null)" = "TMPKEEP" ]; then
  pass "delete_refuses_symlinked_temp_project"
else
  fail "delete_refuses_symlinked_temp_project" "rc=$rc out=$out"
fi

# --- a temp root that is itself a symlink (shared /tmp is world-writable) is
#     REFUSED and nothing under its target is removed. ---
RTH="$TMP/temp_root_sl"
mkdir -p "$RTH/.claude/projects"
RTMP="$TMP/rtmp"
mkdir -p "$RTMP"
OUT_ROOT="$TMP/outside_root"
mkdir -p "$OUT_ROOT/-Users-x-proj/$UUID"
printf 'ROOTKEEP' > "$OUT_ROOT/-Users-x-proj/$UUID/precious.txt"
ln -s "$OUT_ROOT" "$RTMP/claude-$(id -u)"
out=$(CLAUDE_CODE_TMPDIR="$RTMP" TMPDIR="$RTMP" HOME="$RTH" bash "$HERE/delete-session.sh" "$UUID" --confirmed 2>&1); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "REFUSED Temp directory" \
   && [ "$(cat "$OUT_ROOT/-Users-x-proj/$UUID/precious.txt" 2>/dev/null)" = "ROOTKEEP" ]; then
  pass "delete_refuses_symlinked_temp_root"
else
  fail "delete_refuses_symlinked_temp_root" "rc=$rc out=$out"
fi

# --- a set-aside transcript reached through a symlinked project dir is REFUSED. ---
SAS="$TMP/aside_sl/.claude"
mkdir -p "$SAS/projects"
OUT_ASIDE="$TMP/outside_aside"
mkdir -p "$OUT_ASIDE"
printf 'ASIDEKEEP' > "$OUT_ASIDE/$UUID.jsonl.superseded-1794800000000"
ln -s "$OUT_ASIDE" "$SAS/projects/-evil-aside"
out=$(CLAUDE_CODE_TMPDIR="$TMP/none" TMPDIR="$TMP/none" HOME="$TMP/aside_sl" bash "$HERE/delete-session.sh" "$UUID" --confirmed 2>&1); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "REFUSED Set-aside transcript" \
   && [ "$(cat "$OUT_ASIDE/$UUID.jsonl.superseded-1794800000000" 2>/dev/null)" = "ASIDEKEEP" ]; then
  pass "delete_refuses_symlinked_set_aside_parent"
else
  fail "delete_refuses_symlinked_set_aside_parent" "rc=$rc out=$out"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
