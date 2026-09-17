#!/usr/bin/env bash
# auto-name-pane.sh — Auto-set tmux pane @name from Claude session name
# Called from SessionStart hook ONLY (not UserPromptSubmit, to avoid overwriting /whoami)
# Supported platforms: macOS, Linux
#
# Identity contract:
#   The pane name must come from THIS session's transcript, never from
#   "whichever *.jsonl is newest in the project dir" — that file can belong
#   to a different concurrent session in the same project and would silently
#   mislabel the pane.
#
#   Candidates, in order (first ACCEPTED one wins; no other candidates):
#     (a) the hook-provided transcript_path, if it's a regular file whose
#         basename is exactly "<session_id>.jsonl"
#     (b) "$HOME/.claude/projects/<slug(cwd)>/<session_id>.jsonl", where
#         slug replaces every '/' in cwd with '-' (never $(pwd) — a payload
#         missing cwd tells us nothing about which project this pane
#         belongs to, so we refuse to guess)
#   The slug rule is only our best guess at Claude Code's real project-dir
#   naming, so a candidate's PATH is never trusted on its own — a location
#   match (or a matching basename) is necessary but not sufficient. A
#   candidate is only ACCEPTED once its *content* proves it belongs to this
#   session: within its first 200 lines, a SINGLE JSON record must carry
#   both sessionId == session_id and cwd == the payload's cwd (exact string
#   match). Two foreign records each satisfying one half do not bind. Real
#   transcripts carry both fields on ordinary user/assistant records.
#   Content binding is the whole identity check by design: an explicit
#   transcript_path with the right basename is accepted from ANY directory
#   once its content binds (so the derived slug rule is never load-bearing),
#   and a wrong-content file is rejected even if its path and basename look
#   right. transcript_path can therefore never be used to read an arbitrary
#   file or another project's session.
#
#   The title is extracted (from the whole accepted transcript, not just the
#   first 200 lines) by parsing each line as JSON (jq, or python3 as a
#   fallback) and taking the LAST record with type == "custom-title" whose
#   sessionId is absent or matches session_id. We never grep the raw text
#   for "customTitle", because an escaped "customTitle" string can appear
#   inside unrelated tool-result content and would false-match a plain grep.
#
#   Right before setting @name we re-check display-message for an existing
#   name: /whoami (or another hook) can race us between the startup check
#   and here, and the pane must never be overwritten once named.

set -uo pipefail

BIND_SCAN_LINES=200

# Quick exit if not inside tmux
[ -z "${TMUX:-}" ] && exit 0

# Quick exit if pane already has a name (don't overwrite manual /whoami)
# A failing display-message means we cannot know whether the pane is named,
# so treat it as "do not touch" rather than "unnamed".
CURRENT_NAME=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@name}' 2>/dev/null) || exit 0
[ -n "$CURRENT_NAME" ] && exit 0

# Read hook input from stdin
HOOK_INPUT=$(cat)
[ -z "$HOOK_INPUT" ] && exit 0

HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

# Extract a top-level string field from the hook JSON payload.
# Prints empty string on malformed JSON or missing/non-string field.
extract_field() {
  local field="$1"
  if [ "$HAVE_JQ" -eq 1 ]; then
    printf '%s' "$HOOK_INPUT" | jq -r --arg f "$field" '.[$f]? // empty | if type == "string" then . else empty end' 2>/dev/null
  else
    printf '%s' "$HOOK_INPUT" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
val = data.get(sys.argv[1])
if isinstance(val, str):
    sys.stdout.write(val)
' "$field" 2>/dev/null
  fi
}

SESSION_ID=$(extract_field "session_id") || true
TRANSCRIPT_PATH=$(extract_field "transcript_path") || true
CWD=$(extract_field "cwd") || true

# Without a session_id we cannot check a candidate's basename or its content
# binding, so there is nothing to accept.
[ -z "$SESSION_ID" ] && exit 0
# Identity also needs an absolute cwd from the payload (never $(pwd)): the
# content binding below compares cwd strings exactly, and an empty or
# relative value could only ever match a malformed transcript record.
case "$CWD" in
  /*) ;;
  *) exit 0 ;;
esac

# Does the first $BIND_SCAN_LINES lines of $1 contain some record with
# sessionId == $SESSION_ID AND cwd == $CWD on the SAME record? (Two foreign
# records each satisfying one half must not bind.) Skips unparsable lines.
# Prints "yes"/"no".
transcript_is_bound() {
  local file="$1"
  local result
  if [ "$HAVE_JQ" -eq 1 ]; then
    result=$(head -n "$BIND_SCAN_LINES" "$file" 2>/dev/null \
      | jq -Rrs --arg sid "$SESSION_ID" --arg cwd "$CWD" '
          (split("\n") | map(select(length > 0)) | map(fromjson?) | map(select(. != null))) as $recs
          | if any($recs[]; type == "object" and .sessionId == $sid and .cwd == $cwd) then "yes" else "no" end
        ' 2>/dev/null) || true
  else
    result=$(head -n "$BIND_SCAN_LINES" "$file" 2>/dev/null | python3 -c '
import json, sys

sid = sys.argv[1]
cwd = sys.argv[2]
bound = False
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except Exception:
        continue
    if not isinstance(rec, dict):
        continue
    if rec.get("sessionId") == sid and rec.get("cwd") == cwd:
        bound = True
        break
print("yes" if bound else "no")
' "$SESSION_ID" "$CWD" 2>/dev/null) || true
  fi
  [ "$result" = "yes" ]
}

TRANSCRIPT=""

# (a) transcript_path, only if its basename matches this session_id
if [ -z "$TRANSCRIPT" ] && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  if [ "$(basename -- "$TRANSCRIPT_PATH")" = "$SESSION_ID.jsonl" ] && transcript_is_bound "$TRANSCRIPT_PATH"; then
    TRANSCRIPT="$TRANSCRIPT_PATH"
  fi
fi

# (b) the derived project-dir path — never "newest file"
if [ -z "$TRANSCRIPT" ] && [ -n "$CWD" ]; then
  SLUG=$(printf '%s' "$CWD" | sed 's|/|-|g')
  EXPECTED_PATH="$HOME/.claude/projects/$SLUG/$SESSION_ID.jsonl"
  if [ -f "$EXPECTED_PATH" ] && transcript_is_bound "$EXPECTED_PATH"; then
    TRANSCRIPT="$EXPECTED_PATH"
  fi
fi

# Give up if no candidate was accepted
[ -z "$TRANSCRIPT" ] && exit 0

# Cheap prefilter before invoking jq/python3 on the whole file
if ! grep -aq 'custom-title' "$TRANSCRIPT" 2>/dev/null; then
  exit 0
fi

if [ "$HAVE_JQ" -eq 1 ]; then
  SESSION_NAME=$(grep -a 'custom-title' "$TRANSCRIPT" 2>/dev/null \
    | jq -Rrs --arg sid "$SESSION_ID" '
        [ split("\n")[] | select(length > 0) | fromjson? | select(type == "object")
          | select(.type == "custom-title")
          | select((.sessionId // $sid) == $sid)
          | .customTitle | select(type == "string") ]
        | if length > 0 then .[-1] else empty end
      ' 2>/dev/null) || true
else
  SESSION_NAME=$(grep -a 'custom-title' "$TRANSCRIPT" 2>/dev/null | python3 -c '
import json, sys

session_id = sys.argv[1] if len(sys.argv) > 1 else ""
last_title = ""
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except Exception:
        continue
    if not isinstance(rec, dict) or rec.get("type") != "custom-title":
        continue
    rec_sid = rec.get("sessionId")
    if rec_sid is not None and rec_sid != session_id:
        continue
    title = rec.get("customTitle")
    if isinstance(title, str):
        last_title = title
sys.stdout.write(last_title)
' "$SESSION_ID" 2>/dev/null) || true
fi

# Sanitize: session titles are free-form prose, but pane labels must stay in
# [a-zA-Z0-9_-] or resolve_pane can never reach this pane again (the failure
# mode is a silently dead outbound channel).
SESSION_NAME=$(printf '%s' "$SESSION_NAME" \
  | tr -s '[:space:]' '-' \
  | tr -cd 'a-zA-Z0-9_-' \
  | sed 's/--*/-/g; s/^-*//; s/-*$//' \
  | cut -c1-48)

# Set @name only if we found a session name, and only if nothing named the
# pane while we were resolving the transcript (race with /whoami).
if [ -n "$SESSION_NAME" ]; then
  RECHECK_NAME=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@name}' 2>/dev/null) || exit 0
  if [ -z "$RECHECK_NAME" ]; then
    tmux set-option -p -t "${TMUX_PANE:-}" @name "$SESSION_NAME" 2>/dev/null || true
  fi
fi

exit 0
