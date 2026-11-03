#!/usr/bin/env bash
# Reject commit messages that carry a Co-Authored-By or Claude-Session line.
#
# Usage:
#   check-commit-trailers.sh --range <rev-range>    every commit in the range
#   check-commit-trailers.sh --message-file <path>  one message (commit-msg hook)
#
# A message fails when either of these finds a Co-Authored-By or
# Claude-Session key:
#   - git's trailer parser (%(trailers:key=...) or interpret-trailers --parse)
#   - a line that starts with the key and a colon, after optional leading
#     whitespace, anywhere in the message.
# The line rule is needed because git parses trailers only from the last
# paragraph. GitHub's default squash message copies each commit's body, so
# copied trailers end up mid-message, where the parser does not look; a local
# `git merge --squash` copies them indented by four spaces.
# Keys match case-insensitively: GitHub writes "Co-authored-by".
# In --message-file mode, everything from git's scissors line (the
# `git commit -v` diff) down is ignored, as git itself discards it. Comment
# lines never match, because they start with the comment character.
#
# Exit status: 0 clean, 1 a message carries a line, 2 usage or git error.

set -euo pipefail

KEYS_RE='^[[:space:]]*(co-authored-by|claude-session)[[:space:]]*:'

usage() {
  echo "usage: $0 --range <rev-range> | --message-file <path>" >&2
  exit 2
}

annotate() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error title=commit trailers::$1"
  fi
}

# Print the offending lines of one message. Returns 1 when any exist.
#   $1 label, $2 message text, $3 trailer lines from git's parser
scan() {
  local label="$1" msg="$2" parsed="$3" lines found=0
  parsed="$(printf '%s\n' "$parsed" | grep -iE "$KEYS_RE" || true)"
  lines="$(printf '%s\n' "$msg" | grep -inE "$KEYS_RE" || true)"
  if [ -n "$parsed" ] || [ -n "$lines" ]; then
    found=1
    echo "FAIL: $label"
    if [ -n "$parsed" ]; then
      printf '%s\n' "$parsed" | sed 's/^/  trailer: /'
    fi
    if [ -n "$lines" ]; then
      printf '%s\n' "$lines" | sed 's/^/  line /'
    fi
  fi
  return "$found"
}

check_range() {
  local range="$1" commits c msg parsed subject count=0 bad=0
  if ! commits="$(git rev-list --reverse "$range" --)"; then
    echo "ERROR: cannot list the commits in range '$range'" >&2
    exit 2
  fi
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    count=$((count + 1))
    msg="$(git log -1 --format=%B "$c")"
    parsed="$(git log -1 --format='%(trailers:key=Co-Authored-By,key=Claude-Session)' "$c")"
    subject="$(git log -1 --format='%h %s' "$c")"
    if ! scan "$subject" "$msg" "$parsed"; then
      bad=$((bad + 1))
      annotate "$subject carries a Co-Authored-By or Claude-Session line"
    fi
  done <<<"$commits"
  if [ "$bad" -gt 0 ]; then
    echo "ERROR: $bad of $count commit(s) in $range carry Co-Authored-By or Claude-Session lines." >&2
    echo "Reword them without those lines (git commit --amend, or git rebase -i with reword)" >&2
    echo "and push again. For a squash merge, write the squash message by hand." >&2
    echo "A commit already on main needs a force push of main to reword; that is the maintainer's call." >&2
    exit 1
  fi
  echo "OK: $count commit(s) in $range carry no Co-Authored-By or Claude-Session line"
}

check_message_file() {
  local file="$1" msg parsed
  [ -f "$file" ] || { echo "ERROR: no message file: $file" >&2; exit 2; }
  # Drop git's scissors line and everything below it.
  msg="$(awk '/^[^[:space:]]+ -+ >8 -+$/ { exit } { print }' "$file")"
  if ! parsed="$(printf '%s\n' "$msg" | git interpret-trailers --parse)"; then
    echo "ERROR: git interpret-trailers failed on $file" >&2
    exit 2
  fi
  if ! scan "commit message" "$msg" "$parsed"; then
    echo "ERROR: commit messages in this repository carry no Co-Authored-By or Claude-Session line." >&2
    echo "Remove the line(s) above and commit again. Your message is saved in $file." >&2
    exit 1
  fi
}

[ "$#" -eq 2 ] || usage
case "$1" in
  --range) check_range "$2" ;;
  --message-file) check_message_file "$2" ;;
  *) usage ;;
esac
