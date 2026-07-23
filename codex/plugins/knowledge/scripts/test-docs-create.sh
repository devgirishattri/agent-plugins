#!/usr/bin/env bash
# Hermetic smoke tests for knowledge's absorbed docs validators and Codex skill contracts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/knowledge-docs-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$TMP/docs"
printf '# A\n\nSee [B](B.md).\n' > "$TMP/docs/A.md"
printf '# B\n\nAll good.\n' > "$TMP/docs/B.md"

bash "$SCRIPT_DIR/validate-links.sh" "$TMP/docs" > "$TMP/links-pass.out"
bash "$SCRIPT_DIR/check-todos.sh" "$TMP/docs" > "$TMP/todos-pass.out"
(cd "$TMP" && bash "$SCRIPT_DIR/check-freshness.sh" docs 30) > "$TMP/freshness.out"

printf '# Broken\n\nSee [missing](MISSING.md).\n' > "$TMP/docs/BROKEN.md"
if bash "$SCRIPT_DIR/validate-links.sh" "$TMP/docs" > "$TMP/links-fail.out" 2>&1; then
  fail "validate-links accepted a missing target"
fi
grep -Fq 'MISSING.md' "$TMP/links-fail.out" || fail "broken-link output omitted target"

printf '# Work\n\nTODO: move this.\n' > "$TMP/docs/WORK.md"
if bash "$SCRIPT_DIR/check-todos.sh" "$TMP/docs" > "$TMP/todos-fail.out" 2>&1; then
  fail "check-todos accepted an embedded TODO"
fi
grep -Fq 'WORK.md' "$TMP/todos-fail.out" || fail "TODO output omitted source file"

if rg -n --glob '!test-docs-create.sh' --glob '!test-context.sh' 'CODEX_PLUGIN_ROOT|plugins/cache/.*/knowledge/[0-9]' "$PLUGIN_ROOT" >/dev/null; then
  fail "knowledge (docs surface) still contains a fixed plugin-root or cache-version pin"
fi
rg -q 'fresh subagent' "$PLUGIN_ROOT/skills/docs-review/SKILL.md" \
  || fail "docs-review does not require fresh subagent delegation"
rg -q 'no subagent/delegation capability' "$PLUGIN_ROOT/skills/docs-review/SKILL.md" \
  || fail "docs-review lacks the direct-review fallback guard"
rg -q 'Run an independent accuracy review' "$PLUGIN_ROOT/skills/docs-create/SKILL.md" \
  || fail "docs-create does not chain the independent review"
rg -q 'actual parent directory' "$PLUGIN_ROOT/skills/docs-create/SKILL.md" \
  || fail "docs-create validators are not scoped to the changed doc location"
rg -q 'Never silently substitute a hard-coded `docs/`' "$PLUGIN_ROOT/skills/docs-review/SKILL.md" \
  || fail "docs-review can still validate the wrong hard-coded directory"

# --- docs-write.sh: the ONE deliberate Phase A behavior change ------------
# The docs-create workflow must run this reviewer-role preflight FIRST and
# stop on any non-zero exit, before writing or editing any doc.
DW="$SCRIPT_DIR/docs-write.sh"

set +e

bash "$DW" >/dev/null 2>&1
[ "$?" -eq 2 ] || fail "docs-write.sh accepted zero arguments"

bash "$DW" --repo "" >/dev/null 2>&1
[ "$?" -eq 2 ] || fail "docs-write.sh accepted an empty --repo value"

bash "$DW" --repo "$TMP" extra >/dev/null 2>&1
[ "$?" -eq 2 ] || fail "docs-write.sh accepted a trailing token"

bash "$DW" --wrong-flag "$TMP" >/dev/null 2>&1
[ "$?" -eq 2 ] || fail "docs-write.sh accepted an unknown flag"

out=$(KNOWLEDGE_PANE_NAME="test-reviewer" bash "$DW" --repo "$TMP" 2>&1)
rc=$?
[ "$rc" -eq 6 ] || fail "docs-write.sh did not refuse a *-reviewer pane name (rc=$rc out=$out)"
printf '%s' "$out" | grep -qF "reviewer role: docs writes refused" \
  || fail "docs-write.sh reviewer refusal missing its exact stderr line: $out"

out=$(env -u TMUX -u TMUX_PANE -u KNOWLEDGE_PANE_NAME -u SESSION_CHAT_PANE_NAME \
  bash "$DW" --repo "$TMP" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  || fail "docs-write.sh true-solo (outside tmux, no pane name) did not proceed (rc=$rc out=$out)"

out=$(env -u KNOWLEDGE_PANE_NAME -u SESSION_CHAT_PANE_NAME -u TMUX_PANE \
  TMUX="fake-socket,0,0" bash "$DW" --repo "$TMP" 2>&1)
rc=$?
[ "$rc" -eq 6 ] || fail "docs-write.sh did not fail closed on unresolved fleet identity (rc=$rc out=$out)"
printf '%s' "$out" | grep -qF "unresolved pane identity: set KNOWLEDGE_PANE_NAME" \
  || fail "docs-write.sh unresolved-identity refusal missing its exact stderr line: $out"

out=$(KNOWLEDGE_PANE_NAME="executor-1" SESSION_CHAT_PANE_NAME="peer-reviewer" bash "$DW" --repo "$TMP" 2>&1)
rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  || fail "docs-write.sh: KNOWLEDGE_PANE_NAME did not take precedence over SESSION_CHAT_PANE_NAME (rc=$rc out=$out)"

set -e

rg -q 'docs-write.sh' "$PLUGIN_ROOT/commands/docs-create.md" \
  || fail "docs-create command does not wire in the docs-write.sh preflight"
rg -qi 'stop' "$PLUGIN_ROOT/commands/docs-create.md" \
  || fail "docs-create command omits the stop-on-non-zero instruction"
rg -q 'docs-write.sh' "$PLUGIN_ROOT/skills/docs-create/SKILL.md" \
  || fail "docs-create skill does not wire in the docs-write.sh preflight"
rg -qi 'MANDATORY' "$PLUGIN_ROOT/skills/docs-create/SKILL.md" \
  || fail "docs-create skill does not mark the preflight mandatory"

for surface in \
  "$PLUGIN_ROOT/commands/docs-create.md" \
  "$PLUGIN_ROOT/skills/docs-create/SKILL.md"; do
  preflight_line=$(sed -n '/^[[:space:]]*bash .*docs-write\.sh/p' "$surface" | sed 's/^[[:space:]]*//')
  [ "$preflight_line" = 'bash "<PLUGIN_ROOT>/scripts/docs-write.sh" --repo "<REPO_ROOT>"' ] \
    || fail "docs-write preflight is not one literal helper segment in $surface: $preflight_line"
done

echo "knowledge docs-surface smoke tests passed"
