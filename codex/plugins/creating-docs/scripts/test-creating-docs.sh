#!/usr/bin/env bash
# Hermetic smoke tests for creating-docs validators and Codex skill contracts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/creating-docs-test.XXXXXX")"
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

if rg -n --glob '!test-creating-docs.sh' 'CODEX_PLUGIN_ROOT|plugins/cache/.*/creating-docs/[0-9]' "$PLUGIN_ROOT" >/dev/null; then
  fail "creating-docs still contains a fixed plugin-root or cache-version pin"
fi
rg -q 'fresh subagent' "$PLUGIN_ROOT/skills/doc-review/SKILL.md" \
  || fail "doc-review does not require fresh subagent delegation"
rg -q 'no subagent/delegation capability' "$PLUGIN_ROOT/skills/doc-review/SKILL.md" \
  || fail "doc-review lacks the direct-review fallback guard"
rg -q 'Run an independent accuracy review' "$PLUGIN_ROOT/skills/creating-docs/SKILL.md" \
  || fail "creating-docs does not chain the independent review"
rg -q 'actual parent directory' "$PLUGIN_ROOT/skills/creating-docs/SKILL.md" \
  || fail "creating-docs validators are not scoped to the changed doc location"
rg -q 'Never silently substitute a hard-coded `docs/`' "$PLUGIN_ROOT/skills/doc-review/SKILL.md" \
  || fail "doc-review can still validate the wrong hard-coded directory"

echo "creating-docs smoke tests passed"
