#!/usr/bin/env bash
# shellcheck disable=SC2015  # assertions read `CHECK && ok || fail ...`; ok() always
# returns 0, so fail can only run when CHECK itself failed.
# Hermetic smoke tests for knowledge's absorbed docs validators and Codex skill contracts.
set -euo pipefail

# --- test isolation (do not remove) ---------------------------------------
# The workspace launcher exports KNOWLEDGE_MEMORY_HOME into every agent pane.
# Inherited here it outranks the store-discovery these suites exercise, which
# (a) made discovery/init cases assert against the real repo store instead of
# their temp fixtures, and (b) let a --store-less write in a discovery case
# stage a synthetic candidate into the REAL .inbox. Tests must never resolve
# or write to a live store, so drop it before anything else runs.
unset KNOWLEDGE_MEMORY_HOME
unset KNOWLEDGE_AUTO_RECALL KNOWLEDGE_AUTO_RECALL_LIMIT KNOWLEDGE_AUTO_RECALL_TERMS
unset KNOWLEDGE_AUTO_RECALL_BUDGET KNOWLEDGE_AUTO_RECALL_GRAPH KNOWLEDGE_CONSOLIDATE_NUDGE
unset KNOWLEDGE_AUTO_CAPTURE KNOWLEDGE_AUTO_CAPTURE_LIMIT
unset KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING KNOWLEDGE_AUTO_CAPTURE_MAX_BYTES
# KNOWLEDGE_PANE_NAME is deliberately NOT unset: it is the writer's role-detection
# identity, and clearing it pushes role checks onto a tmux probe that fails closed
# for an unnamed pane. Suites that test role behaviour set it explicitly.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# KNOWLEDGE_DOCS_TEST_CODEX_VALIDATE_LINKS selects another validate-links.sh,
# for example an original copy from `git show`, to run the same assertions.
VALIDATE_LINKS="${KNOWLEDGE_DOCS_TEST_CODEX_VALIDATE_LINKS:-$SCRIPT_DIR/validate-links.sh}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/knowledge-docs-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Assertions are fail-fast: fail() exits non-zero on the first failure, so
# reaching the summary means every assertion below passed. ok() counts the
# assertions actually exercised, so a suite that quietly stops asserting shows a
# dropped count instead of an unchanged "PASS" line.
ASSERTIONS=0
ok() { ASSERTIONS=$((ASSERTIONS + 1)); }

mkdir -p "$TMP/docs"
printf '# A\n\nSee [B](B.md).\n' > "$TMP/docs/A.md"
printf '# B\n\nAll good.\n' > "$TMP/docs/B.md"

bash "$VALIDATE_LINKS" "$TMP/docs" > "$TMP/links-pass.out"
bash "$SCRIPT_DIR/check-todos.sh" "$TMP/docs" > "$TMP/todos-pass.out"
(cd "$TMP" && bash "$SCRIPT_DIR/check-freshness.sh" docs 30) > "$TMP/freshness.out"

printf '# Broken\n\nSee [missing](MISSING.md).\n' > "$TMP/docs/BROKEN.md"
if bash "$VALIDATE_LINKS" "$TMP/docs" > "$TMP/links-fail.out" 2>&1; then
  fail "validate-links accepted a missing target"
fi
grep -Fq 'MISSING.md' "$TMP/links-fail.out" && ok || fail "broken-link output omitted target"

# A markdown link target is a URL, so a space or a literal percent sign in a
# file name is written %20 or %25. validate-links decodes the target before it
# looks for the file, and a BROKEN line names the decoded path.
# enc_docs <case> <link as written> [name of the file that exists in api/]
enc_docs() {
  local d="$TMP/enc/$1/docs"
  mkdir -p "$d/guide" "$d/api"
  printf '# Guide\n\nSee [the item](%s).\n' "$2" > "$d/guide/index.md"
  if [ -n "${3:-}" ]; then printf '# Item\n' > "$d/api/$3"; fi
  printf '%s' "$d"
}
links_valid() {  # <what> <docs dir>
  local out rc=0
  out=$(bash "$VALIDATE_LINKS" "$2" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "All doc cross-references valid." ] \
    && ok || fail "validate-links rejected $1 (rc=$rc out=$out)"
}

links_valid "a %20 link to an existing file with a space" \
  "$(enc_docs pct20 '../api/1.2%20List%20Items.md' '1.2 List Items.md')"
links_valid "a %25 link to an existing file with a literal percent" \
  "$(enc_docs pct25 '../api/100%25%20done.md' '100% done.md')"
links_valid "a plain-space link to an existing file" \
  "$(enc_docs plain '../api/1.2 List Items.md' '1.2 List Items.md')"
links_valid "a bare % that is not an escape" \
  "$(enc_docs bare '../api/50%off.md' '50%off.md')"
# Markdown allows spaces between "(" and the link target.
links_valid "a link with a space before the target" \
  "$(enc_docs lead ' ../api/item.md' 'item.md')"

# Control: a %20 link to a file that does not exist is still BROKEN, and the
# line shows the link as written and the decoded expected path.
enc_missing="$(enc_docs missing '../api/1.2%20Missing%20Item.md')"
enc_rc=0
bash "$VALIDATE_LINKS" "$enc_missing" > "$TMP/links-enc-missing.out" 2>&1 || enc_rc=$?
[ "$enc_rc" -eq 1 ] && ok || fail "validate-links accepted a %20 link to a missing file (rc=$enc_rc)"
grep -qxF "BROKEN: $enc_missing/guide/index.md -> ../api/1.2%20Missing%20Item.md (expected at $enc_missing/guide/../api/1.2 Missing Item.md)" \
  "$TMP/links-enc-missing.out" \
  && ok || fail "BROKEN line does not show the decoded expected path: $(cat "$TMP/links-enc-missing.out")"

printf '# Work\n\nTODO: move this.\n' > "$TMP/docs/WORK.md"
if bash "$SCRIPT_DIR/check-todos.sh" "$TMP/docs" > "$TMP/todos-fail.out" 2>&1; then
  fail "check-todos accepted an embedded TODO"
fi
grep -Fq 'WORK.md' "$TMP/todos-fail.out" && ok || fail "TODO output omitted source file"

if rg -n --glob '!test-docs-create.sh' --glob '!test-context.sh' 'CODEX_PLUGIN_ROOT|plugins/cache/.*/knowledge/[0-9]' "$PLUGIN_ROOT" >/dev/null; then
  fail "knowledge (docs surface) still contains a fixed plugin-root or cache-version pin"
fi
rg -q 'fresh subagent' "$PLUGIN_ROOT/skills/docs-review/SKILL.md" \
  && ok || fail "docs-review does not require fresh subagent delegation"
rg -q 'no subagent/delegation capability' "$PLUGIN_ROOT/skills/docs-review/SKILL.md" \
  && ok || fail "docs-review lacks the direct-review fallback guard"
rg -q 'Run an independent accuracy review' "$PLUGIN_ROOT/skills/docs-create/SKILL.md" \
  && ok || fail "docs-create does not chain the independent review"
rg -q 'actual parent directory' "$PLUGIN_ROOT/skills/docs-create/SKILL.md" \
  && ok || fail "docs-create validators are not scoped to the changed doc location"
rg -q 'Never silently substitute a hard-coded `docs/`' "$PLUGIN_ROOT/skills/docs-review/SKILL.md" \
  && ok || fail "docs-review can still validate the wrong hard-coded directory"

# --- docs-write.sh: the ONE deliberate Phase A behavior change ------------
# The docs-create workflow must run this reviewer-role preflight FIRST and
# stop on any non-zero exit, before writing or editing any doc.
DW="$SCRIPT_DIR/docs-write.sh"

set +e

bash "$DW" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok || fail "docs-write.sh accepted zero arguments"

bash "$DW" --repo "" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok || fail "docs-write.sh accepted an empty --repo value"

bash "$DW" --repo "$TMP" extra >/dev/null 2>&1
[ "$?" -eq 2 ] && ok || fail "docs-write.sh accepted a trailing token"

bash "$DW" --wrong-flag "$TMP" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok || fail "docs-write.sh accepted an unknown flag"

out=$(KNOWLEDGE_PANE_NAME="test-reviewer" bash "$DW" --repo "$TMP" 2>&1)
rc=$?
[ "$rc" -eq 6 ] && ok || fail "docs-write.sh did not refuse a *-reviewer pane name (rc=$rc out=$out)"
printf '%s' "$out" | grep -qF "reviewer role: docs writes refused" \
  && ok || fail "docs-write.sh reviewer refusal missing its exact stderr line: $out"

out=$(env -u TMUX -u TMUX_PANE -u KNOWLEDGE_PANE_NAME -u SESSION_CHAT_PANE_NAME \
  bash "$DW" --repo "$TMP" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  && ok || fail "docs-write.sh true-solo (outside tmux, no pane name) did not proceed (rc=$rc out=$out)"

out=$(env -u KNOWLEDGE_PANE_NAME -u SESSION_CHAT_PANE_NAME -u TMUX_PANE \
  TMUX="fake-socket,0,0" bash "$DW" --repo "$TMP" 2>&1)
rc=$?
[ "$rc" -eq 6 ] && ok || fail "docs-write.sh did not fail closed on unresolved fleet identity (rc=$rc out=$out)"
printf '%s' "$out" | grep -qF "unresolved pane identity: set KNOWLEDGE_PANE_NAME" \
  && ok || fail "docs-write.sh unresolved-identity refusal missing its exact stderr line: $out"

out=$(KNOWLEDGE_PANE_NAME="executor-1" SESSION_CHAT_PANE_NAME="peer-reviewer" bash "$DW" --repo "$TMP" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  && ok || fail "docs-write.sh: KNOWLEDGE_PANE_NAME did not take precedence over SESSION_CHAT_PANE_NAME (rc=$rc out=$out)"

set -e

rg -q 'docs-write.sh' "$PLUGIN_ROOT/commands/docs-create.md" \
  && ok || fail "docs-create command does not wire in the docs-write.sh preflight"
rg -qi 'stop' "$PLUGIN_ROOT/commands/docs-create.md" \
  && ok || fail "docs-create command omits the stop-on-non-zero instruction"
rg -q 'docs-write.sh' "$PLUGIN_ROOT/skills/docs-create/SKILL.md" \
  && ok || fail "docs-create skill does not wire in the docs-write.sh preflight"
rg -qi 'MANDATORY' "$PLUGIN_ROOT/skills/docs-create/SKILL.md" \
  && ok || fail "docs-create skill does not mark the preflight mandatory"

for surface in \
  "$PLUGIN_ROOT/commands/docs-create.md" \
  "$PLUGIN_ROOT/skills/docs-create/SKILL.md"; do
  preflight_line=$(sed -n '/^[[:space:]]*bash .*docs-write\.sh/p' "$surface" | sed 's/^[[:space:]]*//')
  [ "$preflight_line" = 'bash "<PLUGIN_ROOT>/scripts/docs-write.sh" --repo "<REPO_ROOT>"' ] \
    && ok || fail "docs-write preflight is not one literal helper segment in $surface: $preflight_line"
done

echo "knowledge docs-surface tests: $ASSERTIONS passed, 0 failed"
