#!/usr/bin/env bash
# test-auto-name-pane.sh — Unit tests for auto-name-pane.sh's transcript
# candidate-selection and content-binding contract (no real tmux required;
# tmux is stubbed via a fake PATH entry).
#
# Usage: bash test-auto-name-pane.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/auto-name-pane.sh"

PASS=0
FAIL=0
FAILURES=()

pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1: $2"); echo "  FAIL  $1 — $2"; }

TESTROOT="$(mktemp -d -t auto-name-pane-test-XXXXXX)"
cleanup() { rm -rf "$TESTROOT" 2>/dev/null || true; }
trap cleanup EXIT

STUB_BIN="$TESTROOT/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  display-message)
    if [ -n "${STUB_DISPLAY_FAIL:-}" ]; then exit 1; fi
    # First call returns $STUB_NAME. If $STUB_NAME_LATER is set, every call
    # after the first returns it instead (simulates a race: unnamed at
    # startup, named by something else before the final set-option).
    STATE_FILE="${STUB_STATE_FILE:-}"
    if [ -n "$STATE_FILE" ] && [ -n "${STUB_NAME_LATER:-}" ]; then
      if [ -f "$STATE_FILE" ]; then
        printf '%s' "$STUB_NAME_LATER"
      else
        : > "$STATE_FILE"
        printf '%s' "${STUB_NAME:-}"
      fi
    else
      printf '%s' "${STUB_NAME:-}"
    fi
    ;;
  set-option)
    shift
    printf '%s\n' "$*" >> "${STUB_LOG:?STUB_LOG not set}"
    ;;
  *)
    ;;
esac
exit 0
EOF
chmod +x "$STUB_BIN/tmux"

FAKE_CWD="/fake/project/dir"
SLUG=$(printf '%s' "$FAKE_CWD" | sed 's|/|-|g')

# Run the script under test with a controlled, minimal environment.
run_script() {
  local payload="$1"
  env -i \
    HOME="$FAKE_HOME" \
    PATH="$STUB_BIN:$PATH" \
    TMUX=stub \
    TMUX_PANE=%9 \
    STUB_NAME="${STUB_NAME:-}" \
    STUB_NAME_LATER="${STUB_NAME_LATER:-}" \
    STUB_STATE_FILE="${STUB_STATE_FILE:-}" \
    STUB_DISPLAY_FAIL="${STUB_DISPLAY_FAIL:-}" \
    STUB_LOG="$STUB_LOG" \
    bash "$SCRIPT" <<< "$payload"
}

new_case_home() {
  FAKE_HOME="$(mktemp -d -t auto-name-pane-home-XXXXXX)"
  STUB_LOG="$(mktemp -t auto-name-pane-log-XXXXXX)"
  : > "$STUB_LOG"
  STUB_NAME=""
  STUB_NAME_LATER=""
  STUB_DISPLAY_FAIL=""
  STUB_STATE_FILE="$(mktemp -u -t auto-name-pane-state-XXXXXX)"
  mkdir -p "$FAKE_HOME/.claude/projects/$SLUG"
}

log_is_empty() {
  [ ! -s "$STUB_LOG" ]
}

log_has_name() {
  grep -qF -- "$1" "$STUB_LOG" 2>/dev/null
}

write_transcript() {
  local path="$1"; shift
  printf '%s\n' "$@" > "$path"
}

custom_title_line() {
  local title="$1" sid="${2:-}"
  if [ -n "$sid" ]; then
    printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}' "$title" "$sid"
  else
    printf '{"type":"custom-title","customTitle":"%s"}' "$title"
  fi
}

# A real-transcript-shaped record carrying both sessionId and cwd — this is
# what the script's binding check looks for (possibly on separate lines from
# the custom-title record, which carries sessionId only).
binding_line() {
  local sid="$1" cwd="$2"
  printf '{"type":"user","sessionId":"%s","cwd":"%s"}' "$sid" "$cwd"
}

junk_lines() {
  local n="$1" i
  for ((i = 0; i < n; i++)); do
    printf '{"type":"junk","n":%d}\n' "$i"
  done
}

# --- Case 1: happy path — transcript_path (candidate a) with two
# custom-title records; last wins; name sanitized. ---
new_case_home
TFILE="$FAKE_HOME/.claude/projects/$SLUG/sess-1.jsonl"
write_transcript "$TFILE" \
  "$(binding_line "sess-1" "$FAKE_CWD")" \
  "$(custom_title_line "First Title" "sess-1")" \
  '{"type":"other-event"}' \
  "$(custom_title_line "Trade Pro Master" "sess-1")"
PAYLOAD=$(printf '{"session_id":"sess-1","transcript_path":"%s","cwd":"%s"}' "$TFILE" "$FAKE_CWD")
run_script "$PAYLOAD" >/dev/null 2>&1
if log_has_name "Trade-Pro-Master"; then
  pass "case1 happy path: last title wins, sanitized"
else
  fail "case1 happy path" "expected @name Trade-Pro-Master, log: $(cat "$STUB_LOG")"
fi

# --- Case 2: transcript_path null, resolve via candidate b (session_id + cwd) ---
new_case_home
SID="sess-2"
TFILE="$FAKE_HOME/.claude/projects/$SLUG/$SID.jsonl"
write_transcript "$TFILE" \
  "$(binding_line "$SID" "$FAKE_CWD")" \
  "$(custom_title_line "From Session File" "$SID")"
PAYLOAD=$(printf '{"session_id":"%s","transcript_path":null,"cwd":"%s"}' "$SID" "$FAKE_CWD")
run_script "$PAYLOAD" >/dev/null 2>&1
if log_has_name "From-Session-File"; then
  pass "case2 resolve via session_id+cwd"
else
  fail "case2 resolve via session_id+cwd" "expected @name From-Session-File, log: $(cat "$STUB_LOG")"
fi

# --- Case 3: only an unrelated project's transcript exists (wrong dir, even
# though it's fully bound to this session) — it is never a candidate. ---
new_case_home
SID="sess-3"
OTHER_SLUG="other-project-dir"
mkdir -p "$FAKE_HOME/.claude/projects/$OTHER_SLUG"
write_transcript "$FAKE_HOME/.claude/projects/$OTHER_SLUG/$SID.jsonl" \
  "$(binding_line "$SID" "$FAKE_CWD")" \
  "$(custom_title_line "Should Not Be Used" "$SID")"
PAYLOAD=$(printf '{"session_id":"%s","transcript_path":null,"cwd":"%s"}' "$SID" "$FAKE_CWD")
run_script "$PAYLOAD" >/dev/null 2>&1
if log_is_empty; then
  pass "case3 unrelated project transcript ignored"
else
  fail "case3 unrelated project transcript ignored" "expected no set-option, log: $(cat "$STUB_LOG")"
fi

# --- Case 4: a newer other-session transcript in the same project (bound,
# with a title) must never be picked in place of this session's own file. ---
new_case_home
SID="sess-4"
OTHER_SID="sess-4-other"
write_transcript "$FAKE_HOME/.claude/projects/$SLUG/$SID.jsonl" '{"type":"other-event"}'
sleep 1
write_transcript "$FAKE_HOME/.claude/projects/$SLUG/$OTHER_SID.jsonl" \
  "$(binding_line "$OTHER_SID" "$FAKE_CWD")" \
  "$(custom_title_line "Newer Other Session" "$OTHER_SID")"
PAYLOAD=$(printf '{"session_id":"%s","transcript_path":null,"cwd":"%s"}' "$SID" "$FAKE_CWD")
run_script "$PAYLOAD" >/dev/null 2>&1
if log_is_empty; then
  pass "case4 does not fall back to newest file in project"
else
  fail "case4 does not fall back to newest file in project" "expected no set-option, log: $(cat "$STUB_LOG")"
fi

# --- Case 5: malformed JSON payload ---
new_case_home
run_script '{not valid json' >/dev/null 2>&1
if log_is_empty; then
  pass "case5 malformed JSON payload"
else
  fail "case5 malformed JSON payload" "expected no set-option, log: $(cat "$STUB_LOG")"
fi

# --- Case 6: pretty-printed multi-line JSON payload ---
new_case_home
TFILE="$FAKE_HOME/.claude/projects/$SLUG/sess-6.jsonl"
write_transcript "$TFILE" \
  "$(binding_line "sess-6" "$FAKE_CWD")" \
  "$(custom_title_line "Pretty Printed Works" "sess-6")"
PAYLOAD=$(cat <<EOF
{
  "session_id": "sess-6",
  "transcript_path": "$TFILE",
  "cwd": "$FAKE_CWD"
}
EOF
)
run_script "$PAYLOAD" >/dev/null 2>&1
if log_has_name "Pretty-Printed-Works"; then
  pass "case6 pretty-printed multi-line payload"
else
  fail "case6 pretty-printed multi-line payload" "expected @name Pretty-Printed-Works, log: $(cat "$STUB_LOG")"
fi

# --- Case 7: transcript is bound but has no custom-title record ---
new_case_home
TFILE="$FAKE_HOME/.claude/projects/$SLUG/sess-7.jsonl"
write_transcript "$TFILE" \
  "$(binding_line "sess-7" "$FAKE_CWD")" \
  '{"type":"other-event"}' \
  '{"type":"another-event"}'
PAYLOAD=$(printf '{"session_id":"sess-7","transcript_path":"%s","cwd":"%s"}' "$TFILE" "$FAKE_CWD")
run_script "$PAYLOAD" >/dev/null 2>&1
if log_is_empty; then
  pass "case7 no custom-title record"
else
  fail "case7 no custom-title record" "expected no set-option, log: $(cat "$STUB_LOG")"
fi

# --- Case 8: custom-title with mismatched sessionId is ignored ---
new_case_home
TFILE="$FAKE_HOME/.claude/projects/$SLUG/sess-8.jsonl"
write_transcript "$TFILE" \
  "$(binding_line "sess-8" "$FAKE_CWD")" \
  "$(custom_title_line "Wrong Session" "other-sess")" \
  "$(custom_title_line "Right Session" "sess-8")"
PAYLOAD=$(printf '{"session_id":"sess-8","transcript_path":"%s","cwd":"%s"}' "$TFILE" "$FAKE_CWD")
run_script "$PAYLOAD" >/dev/null 2>&1
if log_has_name "Right-Session"; then
  pass "case8a mismatched sessionId ignored, later match used"
else
  fail "case8a mismatched sessionId ignored, later match used" "expected @name Right-Session, log: $(cat "$STUB_LOG")"
fi

new_case_home
TFILE="$FAKE_HOME/.claude/projects/$SLUG/sess-8b.jsonl"
write_transcript "$TFILE" \
  "$(binding_line "sess-8b" "$FAKE_CWD")" \
  "$(custom_title_line "Wrong Session Only" "other-sess")"
PAYLOAD=$(printf '{"session_id":"sess-8b","transcript_path":"%s","cwd":"%s"}' "$TFILE" "$FAKE_CWD")
run_script "$PAYLOAD" >/dev/null 2>&1
if log_is_empty; then
  pass "case8b only mismatched sessionId -> no set-option"
else
  fail "case8b only mismatched sessionId -> no set-option" "expected no set-option, log: $(cat "$STUB_LOG")"
fi

# --- Case 9: pre-existing @name is never overwritten, even with a fully
# bound transcript and a valid title. ---
new_case_home
STUB_NAME="keep-me"
TFILE="$FAKE_HOME/.claude/projects/$SLUG/sess-9.jsonl"
write_transcript "$TFILE" \
  "$(binding_line "sess-9" "$FAKE_CWD")" \
  "$(custom_title_line "Should Not Set" "sess-9")"
PAYLOAD=$(printf '{"session_id":"sess-9","transcript_path":"%s","cwd":"%s"}' "$TFILE" "$FAKE_CWD")
run_script "$PAYLOAD" >/dev/null 2>&1
if log_is_empty; then
  pass "case9 pre-existing @name not overwritten"
else
  fail "case9 pre-existing @name not overwritten" "expected no set-option, log: $(cat "$STUB_LOG")"
fi
STUB_NAME=""

# --- Case 10: "customTitle" text escaped inside tool_result content ---
new_case_home
TFILE="$FAKE_HOME/.claude/projects/$SLUG/sess-10.jsonl"
write_transcript "$TFILE" \
  "$(binding_line "sess-10" "$FAKE_CWD")" \
  '{"type":"tool_result","content":"the payload contained \"customTitle\": \"Fake Title\" as text"}'
PAYLOAD=$(printf '{"session_id":"sess-10","transcript_path":"%s","cwd":"%s"}' "$TFILE" "$FAKE_CWD")
run_script "$PAYLOAD" >/dev/null 2>&1
if log_is_empty; then
  pass "case10 escaped customTitle inside tool_result ignored"
else
  fail "case10 escaped customTitle inside tool_result ignored" "expected no set-option, log: $(cat "$STUB_LOG")"
fi

# --- Case 11: title sanitizes to empty ---
new_case_home
TFILE="$FAKE_HOME/.claude/projects/$SLUG/sess-11.jsonl"
write_transcript "$TFILE" \
  "$(binding_line "sess-11" "$FAKE_CWD")" \
  "$(custom_title_line "!!!" "sess-11")"
PAYLOAD=$(printf '{"session_id":"sess-11","transcript_path":"%s","cwd":"%s"}' "$TFILE" "$FAKE_CWD")
run_script "$PAYLOAD" >/dev/null 2>&1
if log_is_empty; then
  pass "case11 title sanitizes to empty -> no set-option"
else
  fail "case11 title sanitizes to empty -> no set-option" "expected no set-option, log: $(cat "$STUB_LOG")"
fi

# --- Case 12: missing session_id and transcript_path ---
new_case_home
PAYLOAD='{"cwd":"/fake/project/dir","hook_event_name":"SessionStart"}'
run_script "$PAYLOAD" >/dev/null 2>&1
if log_is_empty; then
  pass "case12 missing session_id and transcript_path"
else
  fail "case12 missing session_id and transcript_path" "expected no set-option, log: $(cat "$STUB_LOG")"
fi

# --- Case 13: python3 fallback (jq hidden from PATH), happy path ---
new_case_home
TFILE="$FAKE_HOME/.claude/projects/$SLUG/sess-13.jsonl"
write_transcript "$TFILE" \
  "$(binding_line "sess-13" "$FAKE_CWD")" \
  "$(custom_title_line "Python Fallback Works" "sess-13")"
PAYLOAD=$(printf '{"session_id":"sess-13","transcript_path":"%s","cwd":"%s"}' "$TFILE" "$FAKE_CWD")

NOJQ_BIN="$TESTROOT/nojq-bin"
mkdir -p "$NOJQ_BIN"
# jq lives alongside grep/sed/tr/cut/mktemp on this system (e.g. /usr/bin), so
# excluding jq's directory from PATH would also hide the coreutils the script
# needs. Instead, symlink only the specific tools the script requires (never
# jq) into a curated bin dir, so `command -v jq` genuinely fails.
for tool in bash python3 grep sed tr cut cat mktemp basename dirname head; do
  tool_path="$(command -v "$tool" 2>/dev/null)" || continue
  ln -sf "$tool_path" "$NOJQ_BIN/$tool"
done
env -i \
  HOME="$FAKE_HOME" \
  PATH="$STUB_BIN:$NOJQ_BIN" \
  TMUX=stub \
  TMUX_PANE=%9 \
  STUB_NAME="" \
  STUB_LOG="$STUB_LOG" \
  bash "$SCRIPT" <<< "$PAYLOAD" >/dev/null 2>&1
if log_has_name "Python-Fallback-Works"; then
  pass "case13 python3 fallback (jq hidden)"
else
  fail "case13 python3 fallback (jq hidden)" "expected @name Python-Fallback-Works, log: $(cat "$STUB_LOG")"
fi

# --- Case 14: explicit transcript_path is a real, fully-bound file, but its
# basename is a different session's id — the basename gate rejects it before
# content is even considered, and the expected path for THIS session
# doesn't exist either. ---
new_case_home
SID="sess-14"
OTHER_SID="sess-14-other"
TFILE="$FAKE_HOME/${OTHER_SID}.jsonl"
write_transcript "$TFILE" \
  "$(binding_line "$SID" "$FAKE_CWD")" \
  "$(custom_title_line "Wrong Basename File" "$SID")"
PAYLOAD=$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s"}' "$SID" "$TFILE" "$FAKE_CWD")
run_script "$PAYLOAD" >/dev/null 2>&1
if log_is_empty; then
  pass "case14 transcript_path with wrong basename ignored"
else
  fail "case14 transcript_path with wrong basename ignored" "expected no set-option, log: $(cat "$STUB_LOG")"
fi

# --- Case 15: session_id present but cwd missing -> no set-option, even
# though a matching, bound file exists under the slug that cwd would have
# produced. ---
new_case_home
SID="sess-15"
TFILE="$FAKE_HOME/.claude/projects/$SLUG/$SID.jsonl"
write_transcript "$TFILE" \
  "$(binding_line "$SID" "$FAKE_CWD")" \
  "$(custom_title_line "Would Have Worked" "$SID")"
PAYLOAD=$(printf '{"session_id":"%s","transcript_path":null}' "$SID")
run_script "$PAYLOAD" >/dev/null 2>&1
if log_is_empty; then
  pass "case15 missing cwd -> no set-option"
else
  fail "case15 missing cwd -> no set-option" "expected no set-option, log: $(cat "$STUB_LOG")"
fi

# --- Case 16: relative cwd derives the wrong slug directory, so the real
# (bound) file for this session is never found. ---
new_case_home
SID="sess-16"
TFILE="$FAKE_HOME/.claude/projects/$SLUG/$SID.jsonl"
write_transcript "$TFILE" \
  "$(binding_line "$SID" "$FAKE_CWD")" \
  "$(custom_title_line "Would Have Worked" "$SID")"
PAYLOAD=$(printf '{"session_id":"%s","transcript_path":null,"cwd":"relative/dir"}' "$SID")
run_script "$PAYLOAD" >/dev/null 2>&1
if log_is_empty; then
  pass "case16 relative cwd -> no set-option"
else
  fail "case16 relative cwd -> no set-option" "expected no set-option, log: $(cat "$STUB_LOG")"
fi

# --- Case 17: race with /whoami — pane is unnamed at startup but gets named
# before we reach the final set-option, so we must not overwrite it. The
# transcript is fully bound with a valid title, so this isolates the race
# guard specifically. ---
new_case_home
SID="sess-17"
TFILE="$FAKE_HOME/.claude/projects/$SLUG/$SID.jsonl"
write_transcript "$TFILE" \
  "$(binding_line "$SID" "$FAKE_CWD")" \
  "$(custom_title_line "Should Not Overwrite" "$SID")"
PAYLOAD=$(printf '{"session_id":"%s","transcript_path":null,"cwd":"%s"}' "$SID" "$FAKE_CWD")
STUB_NAME=""
STUB_NAME_LATER="raced-name"
run_script "$PAYLOAD" >/dev/null 2>&1
STUB_NAME_LATER=""
if log_is_empty; then
  pass "case17 race with /whoami before final set-option"
else
  fail "case17 race with /whoami before final set-option" "expected no set-option, log: $(cat "$STUB_LOG")"
fi

# --- Case 18: explicit transcript_path with the correct basename, living
# under a DIFFERENT (differently-derived) project slug directory, but its
# CONTENT is properly bound to this session (sessionId + cwd match). Path
# location no longer matters once content proves ownership -> must be named.
new_case_home
SID="sess-18"
OTHER_SLUG="other-project-dir-18"
mkdir -p "$FAKE_HOME/.claude/projects/$OTHER_SLUG"
TFILE="$FAKE_HOME/.claude/projects/$OTHER_SLUG/$SID.jsonl"
write_transcript "$TFILE" \
  "$(binding_line "$SID" "$FAKE_CWD")" \
  "$(custom_title_line "Different Slug Content Bound" "$SID")"
PAYLOAD=$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s"}' "$SID" "$TFILE" "$FAKE_CWD")
run_script "$PAYLOAD" >/dev/null 2>&1
if log_has_name "Different-Slug-Content-Bound"; then
  pass "case18 transcript_path under a different slug, content-bound -> named"
else
  fail "case18 transcript_path under a different slug, content-bound -> named" "expected @name Different-Slug-Content-Bound, log: $(cat "$STUB_LOG")"
fi

# --- Case 19: explicit path, correct basename, but the content's sessionId
# belongs to another session -> not bound -> no set-option. ---
new_case_home
SID="sess-19"
TFILE="$FAKE_HOME/${SID}.jsonl"
write_transcript "$TFILE" \
  "$(binding_line "some-other-session" "$FAKE_CWD")" \
  "$(custom_title_line "Should Not Bind" "some-other-session")"
PAYLOAD=$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s"}' "$SID" "$TFILE" "$FAKE_CWD")
run_script "$PAYLOAD" >/dev/null 2>&1
if log_is_empty; then
  pass "case19 content sessionId belongs to another session -> no set-option"
else
  fail "case19 content sessionId belongs to another session -> no set-option" "expected no set-option, log: $(cat "$STUB_LOG")"
fi

# --- Case 20: explicit path, correct basename, correct sessionId in
# content, but the content's cwd differs from the payload's cwd -> not
# bound -> no set-option. ---
new_case_home
SID="sess-20"
TFILE="$FAKE_HOME/${SID}.jsonl"
write_transcript "$TFILE" \
  "$(binding_line "$SID" "/some/other/cwd")" \
  "$(custom_title_line "Should Not Bind Either" "$SID")"
PAYLOAD=$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s"}' "$SID" "$TFILE" "$FAKE_CWD")
run_script "$PAYLOAD" >/dev/null 2>&1
if log_is_empty; then
  pass "case20 content cwd differs from payload cwd -> no set-option"
else
  fail "case20 content cwd differs from payload cwd -> no set-option" "expected no set-option, log: $(cat "$STUB_LOG")"
fi

# --- Case 21: the binding record sits exactly at line 200 (within the scan
# window) -> named. ---
new_case_home
SID="sess-21"
TFILE="$FAKE_HOME/.claude/projects/$SLUG/$SID.jsonl"
{
  junk_lines 199
  binding_line "$SID" "$FAKE_CWD"
  echo ""
  custom_title_line "Line Two Hundred Works" "$SID"
  echo ""
} > "$TFILE"
PAYLOAD=$(printf '{"session_id":"%s","transcript_path":null,"cwd":"%s"}' "$SID" "$FAKE_CWD")
run_script "$PAYLOAD" >/dev/null 2>&1
if log_has_name "Line-Two-Hundred-Works"; then
  pass "case21 binding record on line 200 -> named"
else
  fail "case21 binding record on line 200 -> named" "expected @name Line-Two-Hundred-Works, log: $(cat "$STUB_LOG")"
fi

# --- Case 22: the binding record sits at line 201 (just outside the 200
# line scan window) -> not bound -> no set-option. ---
new_case_home
SID="sess-22"
TFILE="$FAKE_HOME/.claude/projects/$SLUG/$SID.jsonl"
{
  junk_lines 200
  binding_line "$SID" "$FAKE_CWD"
  echo ""
  custom_title_line "Line Two Oh One Fails" "$SID"
  echo ""
} > "$TFILE"
PAYLOAD=$(printf '{"session_id":"%s","transcript_path":null,"cwd":"%s"}' "$SID" "$FAKE_CWD")
run_script "$PAYLOAD" >/dev/null 2>&1
if log_is_empty; then
  pass "case22 binding record on line 201 -> no set-option"
else
  fail "case22 binding record on line 201 -> no set-option" "expected no set-option, log: $(cat "$STUB_LOG")"
fi

# --- Case 23: symlinked $HOME — an explicit transcript_path given as the
# PHYSICAL (non-aliased) path, with correct basename and content bound to
# this session, must still be accepted (path/HOME symlinking is irrelevant
# once acceptance is content-based). ---
REAL_HOME_DIR="$(mktemp -d -t auto-name-pane-realhome-XXXXXX)"
ALIAS_HOME_DIR="${REAL_HOME_DIR}-alias"
ln -s "$REAL_HOME_DIR" "$ALIAS_HOME_DIR"
FAKE_HOME="$ALIAS_HOME_DIR"
STUB_LOG="$(mktemp -t auto-name-pane-log-XXXXXX)"
: > "$STUB_LOG"
STUB_NAME=""
STUB_NAME_LATER=""
STUB_STATE_FILE="$(mktemp -u -t auto-name-pane-state-XXXXXX)"
mkdir -p "$REAL_HOME_DIR/.claude/projects/$SLUG"
SID="sess-23"
TFILE_REAL="$REAL_HOME_DIR/.claude/projects/$SLUG/$SID.jsonl"
write_transcript "$TFILE_REAL" \
  "$(binding_line "$SID" "$FAKE_CWD")" \
  "$(custom_title_line "Symlinked Home Works" "$SID")"
PAYLOAD=$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s"}' "$SID" "$TFILE_REAL" "$FAKE_CWD")
run_script "$PAYLOAD" >/dev/null 2>&1
if log_has_name "Symlinked-Home-Works"; then
  pass "case23 symlinked HOME still accepted via basename+content binding"
else
  fail "case23 symlinked HOME still accepted via basename+content binding" "expected @name Symlinked-Home-Works, log: $(cat "$STUB_LOG")"
fi
rm -rf "$REAL_HOME_DIR" "$ALIAS_HOME_DIR" 2>/dev/null || true

# --- Case 24: crossed records — sessionId on one record, cwd on another,
# never both on the same record -> must NOT bind (two foreign halves). ---
new_case_home
TFILE="$FAKE_HOME/.claude/projects/$SLUG/sess-24.jsonl"
write_transcript "$TFILE" \
  '{"type":"user","sessionId":"sess-24","cwd":"/some/other/dir"}' \
  '{"type":"user","sessionId":"other-session","cwd":"'"$FAKE_CWD"'"}' \
  "$(custom_title_line "Crossed Halves" "sess-24")"
PAYLOAD=$(printf '{"session_id":"sess-24","transcript_path":"%s","cwd":"%s"}' "$TFILE" "$FAKE_CWD")
run_script "$PAYLOAD" >/dev/null 2>&1
if log_is_empty; then pass "case24 crossed records (sessionId and cwd on different records) -> no set-option"; else fail "case24 crossed records" "log: $(cat "$STUB_LOG")"; fi

# --- Case 25: control for 24 — same records plus ONE record with both -> named ---
new_case_home
TFILE="$FAKE_HOME/.claude/projects/$SLUG/sess-25.jsonl"
write_transcript "$TFILE" \
  '{"type":"user","sessionId":"sess-25","cwd":"/some/other/dir"}' \
  '{"type":"user","sessionId":"other-session","cwd":"'"$FAKE_CWD"'"}' \
  "$(binding_line "sess-25" "$FAKE_CWD")" \
  "$(custom_title_line "Same Record Bound" "sess-25")"
PAYLOAD=$(printf '{"session_id":"sess-25","transcript_path":"%s","cwd":"%s"}' "$TFILE" "$FAKE_CWD")
run_script "$PAYLOAD" >/dev/null 2>&1
if log_has_name "Same-Record-Bound"; then pass "case25 same-record binding present -> named"; else fail "case25 same-record binding present -> named" "log: $(cat "$STUB_LOG")"; fi

# --- Case 26: display-message failure at the initial check -> exit unnamed ---
new_case_home
TFILE="$FAKE_HOME/.claude/projects/$SLUG/sess-26.jsonl"
write_transcript "$TFILE" "$(binding_line "sess-26" "$FAKE_CWD")" "$(custom_title_line "Should Not Name" "sess-26")"
PAYLOAD=$(printf '{"session_id":"sess-26","transcript_path":"%s","cwd":"%s"}' "$TFILE" "$FAKE_CWD")
STUB_DISPLAY_FAIL=1
run_script "$PAYLOAD" >/dev/null 2>&1; rc=$?
STUB_DISPLAY_FAIL=""
if log_is_empty && [ "$rc" -eq 0 ]; then pass "case26 tmux display-message failure -> exit 0 unnamed"; else fail "case26 tmux display-message failure" "rc=$rc log: $(cat "$STUB_LOG")"; fi

# --- Case 27/28: escaped quote + backslash + \n in the title: jq path and
# python3 path must produce the same @name. ---
ESCAPED_TITLE='Ship \"v2\" \\ now\nplease'   # JSON text: Ship \"v2\" \\ now\nplease
EXPECTED_ESCAPED="Ship-v2-now-please"
new_case_home
TFILE="$FAKE_HOME/.claude/projects/$SLUG/sess-27.jsonl"
write_transcript "$TFILE" \
  "$(binding_line "sess-27" "$FAKE_CWD")" \
  "{\"type\":\"custom-title\",\"customTitle\":\"$ESCAPED_TITLE\",\"sessionId\":\"sess-27\"}"
PAYLOAD=$(printf '{"session_id":"sess-27","transcript_path":"%s","cwd":"%s"}' "$TFILE" "$FAKE_CWD")
run_script "$PAYLOAD" >/dev/null 2>&1
JQ_RESULT="$(cat "$STUB_LOG")"
if log_has_name "@name $EXPECTED_ESCAPED"; then pass "case27 escaped/multiline title via jq -> $EXPECTED_ESCAPED"; else fail "case27 escaped/multiline title via jq" "log: $JQ_RESULT"; fi

new_case_home
TFILE="$FAKE_HOME/.claude/projects/$SLUG/sess-27.jsonl"
write_transcript "$TFILE" \
  "$(binding_line "sess-27" "$FAKE_CWD")" \
  "{\"type\":\"custom-title\",\"customTitle\":\"$ESCAPED_TITLE\",\"sessionId\":\"sess-27\"}"
env -i HOME="$FAKE_HOME" PATH="$STUB_BIN:$NOJQ_BIN" TMUX=stub TMUX_PANE=%9 STUB_NAME="" STUB_LOG="$STUB_LOG" \
  bash "$SCRIPT" <<< "$PAYLOAD" >/dev/null 2>&1
PY_RESULT="$(cat "$STUB_LOG")"
if [ "$PY_RESULT" = "$JQ_RESULT" ] && log_has_name "@name $EXPECTED_ESCAPED"; then pass "case28 python3 path yields identical @name for escaped/multiline title"; else fail "case28 python3 path parity" "jq=[$JQ_RESULT] py=[$PY_RESULT]"; fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
exit 0
