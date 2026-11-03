#!/usr/bin/env bash
# Regression test for scripts/check-commit-trailers.sh and the tracked
# .githooks/commit-msg hook. Every rejection case has a passing control, and
# the mid-message squash case shows that git's trailer parser alone misses it.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/check-commit-trailers.sh"
HOOKS="$ROOT/.githooks"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Isolate git from the caller's configuration and any hook environment, so
# `git config --global` below writes only to the scratch file.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_PREFIX
unset XDG_CONFIG_HOME GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_EDITOR
export HOME="$TMP/home" GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
git config --global user.name "Test"
git config --global user.email "test@example.invalid"
git config --global commit.gpgsign false
git config --global init.defaultBranch main
git config --global core.editor true

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }

# assert <name> <command...>: the command's success is the expectation.
assert() {
  local name="$1"
  shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}

# expect <name> <wanted exit> <command...>
expect() {
  local name="$1" want="$2" got=0
  shift 2
  "$@" >"$TMP/out" 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then
    ok "$name"
  else
    bad "$name (exit $got, wanted $want)"
    sed 's/^/    /' "$TMP/out"
  fi
}

REPO="$TMP/repo"
git init -q "$REPO"
cd "$REPO"

commit() {
  git commit -q --allow-empty --no-verify -F - <<<"$1"
  git rev-parse HEAD
}

base="$(commit "Base commit")"
clean="$(commit "$(printf 'Clean subject\n\nThe body names Co-Authored-By and Claude-Session trailers mid-sentence.\n')")"

# Control: a clean range passes.
expect "clean range passes" 0 bash "$CHECK" --range "$base..$clean"
expect "empty range passes" 0 bash "$CHECK" --range "$clean..$clean"

coauthor="$(commit "$(printf 'Trailer subject\n\nBody.\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n')")"
expect "Co-Authored-By trailer fails" 1 bash "$CHECK" --range "$clean..$coauthor"
assert "failure names the commit" grep -q "$(git rev-parse --short "$coauthor") Trailer subject" "$TMP/out"
expect "range containing a trailer commit fails" 1 bash "$CHECK" --range "$base..$coauthor"

session="$(commit "$(printf 'Session subject\n\nBody.\n\nClaude-Session: https://claude.ai/code/session_example\n')")"
expect "Claude-Session trailer alone fails" 1 bash "$CHECK" --range "$coauthor..$session"

lower="$(commit "$(printf 'GitHub squash subject\n\nBody.\n\nCo-authored-by: Claude <noreply@anthropic.com>\n')")"
expect "lowercase GitHub Co-authored-by fails" 1 bash "$CHECK" --range "$session..$lower"

spaced="$(commit "$(printf 'Spaced subject\n\nBody.\n\nco-authored-by : Someone <a@example.invalid>\n')")"
expect "key with space before the colon fails" 1 bash "$CHECK" --range "$lower..$spaced"

# GitHub's default squash message copies each commit's body, trailers
# included, and then adds its own paragraph. The copied lines sit mid-message.
squash="$(commit "$(printf 'Squash subject (#1)\n\n* first commit\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n\n* second commit\n\nPlain closing paragraph.\n')")"
parsed="$(git log -1 --format='%(trailers:key=Co-Authored-By,key=Claude-Session)' "$squash")"
assert "control: git trailer parser misses mid-message trailers" [ -z "$parsed" ]
expect "mid-message Co-Authored-By fails" 1 bash "$CHECK" --range "$spaced..$squash"
midsession="$(commit "$(printf 'Squash subject (#2)\n\n* first commit\n\nClaude-Session: https://claude.ai/code/session_example\n\n* second commit\n\nPlain closing paragraph.\n')")"
expect "mid-message Claude-Session fails" 1 bash "$CHECK" --range "$squash..$midsession"

# `git merge --squash` indents the copied bodies by four spaces.
indented="$(commit "$(printf 'Indented subject\n\n    Co-Authored-By: Claude <noreply@anthropic.com>\n')")"
expect "indented Co-Authored-By fails" 1 bash "$CHECK" --range "$midsession..$indented"
onespace="$(commit "$(printf 'One-space subject\n\n Claude-Session: https://claude.ai/code/session_example\n')")"
expect "one-space Claude-Session fails" 1 bash "$CHECK" --range "$indented..$onespace"

expect "unknown revision fails closed" 2 bash "$CHECK" --range "no-such-rev..$onespace"
expect "missing arguments is a usage error" 2 bash "$CHECK" --range

# commit-msg hook, through the tracked hooks directory.
git config core.hooksPath "$HOOKS"
before="$(git rev-parse HEAD)"
expect "hook refuses a Co-Authored-By commit" 1 \
  git commit -q --allow-empty -m "Hook subject" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
assert "the hook made that refusal" grep -q '^FAIL: commit message' "$TMP/out"
assert "refused commit leaves HEAD unchanged" [ "$(git rev-parse HEAD)" = "$before" ]
expect "hook refuses a Claude-Session commit" 1 \
  git commit -q --allow-empty -m "Hook subject" -m "Claude-Session: https://claude.ai/code/session_example"
expect "hook allows a clean commit" 0 \
  git commit -q --allow-empty -m "Hook subject" -m "Body without attribution lines."
assert "clean commit lands" [ "$(git rev-parse HEAD)" != "$before" ]

# `git commit -v` puts the diff below a scissors line in the message file. A
# diff context line that starts with a space and a key is not part of the
# message. Control: the same commit with the key above the scissors fails.
printf 'a\nCo-Authored-By: listed in a file\nb\n' >file.txt
git add file.txt
git commit -q --no-verify -m "Add file"
printf 'a\nCo-Authored-By: listed in a file\nc\n' >file.txt
expect "control: verbose commit with a trailer above the scissors fails" 1 \
  git commit -q -a -v -e -m "Edit file" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
assert "the hook made that refusal" grep -q '^FAIL: commit message' "$TMP/out"
expect "verbose commit whose diff context shows a key passes" 0 \
  git commit -q -a -v -e -m "Edit file"

# A local squash merge copies the branch's commit bodies, indented.
git checkout -q -b dirty
printf 'dirty\n' >dirty.txt
git add dirty.txt
git commit -q --no-verify -m "Dirty branch" -m "Co-Authored-By: Claude <noreply@anthropic.com>"
git checkout -q main
git merge -q --squash dirty >/dev/null
assert "control: the squash message holds the trailer indented" grep -q '^    Co-Authored-By: Claude' .git/SQUASH_MSG
expect "hook refuses a local squash of a trailer commit" 1 git commit -q
assert "the hook made that refusal" grep -q '^FAIL: commit message' "$TMP/out"
git reset -q --hard
git checkout -q -b tidy
printf 'tidy\n' >tidy.txt
git add tidy.txt
git commit -q -m "Tidy branch" -m "Body without attribution lines."
git checkout -q main
git merge -q --squash tidy >/dev/null
expect "control: hook allows a local squash of clean commits" 0 git commit -q

printf 'Message file\n\nBody.\n\nCo-Authored-By: X <x@example.invalid>\n' >"$TMP/msg-bad"
printf 'Message file\n\nBody.\n\n# Co-Authored-By: a comment line is stripped by git\n' >"$TMP/msg-ok"
printf 'Message file\n\nBody.\n# ------------------------ >8 ------------------------\nCo-Authored-By: below the scissors\n' >"$TMP/msg-scissors"
expect "message file with a trailer fails" 1 bash "$CHECK" --message-file "$TMP/msg-bad"
expect "message file with only a comment passes" 0 bash "$CHECK" --message-file "$TMP/msg-ok"
expect "message file text below the scissors is ignored" 0 bash "$CHECK" --message-file "$TMP/msg-scissors"
expect "missing message file is an error" 2 bash "$CHECK" --message-file "$TMP/none"

# The tracked repository files that this rule depends on.
cd "$ROOT"
if git rev-parse --git-dir >/dev/null 2>&1; then
  mode="$(git ls-files -s .githooks/commit-msg | cut -d' ' -f1)"
  assert "tracked hook is executable (mode $mode)" [ "$mode" = "100755" ]
else
  echo "SKIP: tracked hook mode ($ROOT is not a git checkout)"
fi
if python3 - "$ROOT/.claude/settings.json" <<'PY'
import json, sys
attribution = json.load(open(sys.argv[1])).get("attribution")
sys.exit(0 if attribution == {"commit": "", "pr": "", "sessionUrl": False} else 1)
PY
then
  ok "project settings turn off commit, PR and session-link attribution"
else
  bad "project settings turn off commit, PR and session-link attribution"
fi

echo "commit trailers: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
