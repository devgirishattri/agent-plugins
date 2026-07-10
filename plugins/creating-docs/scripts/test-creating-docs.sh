#!/usr/bin/env bash
# test-creating-docs.sh — contract test: the validation scripts operate on ANY
# doc parent directory (project root, docs/, or a module-adjacent dir), not a
# hard-coded docs/. Proves the "run validators once per unique parent" contract.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP=$(mktemp -d)
PASS=0; FAIL=0; FAILURES=()
pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1: $2"); echo "  FAIL  $1 — $2"; }
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "=== creating-docs contract tests ==="

# A module-adjacent docs location — deliberately NOT named docs/.
MOD="$TMP/src/api"
mkdir -p "$MOD"

# 1: check-todos accepts an arbitrary dir and passes on a clean doc
printf '# API\nSee [other](other.md).\n' > "$MOD/README.md"
printf '# Other\n' > "$MOD/other.md"
if bash "$HERE/check-todos.sh" "$MOD" >/dev/null 2>&1; then
  pass "check_todos_accepts_module_dir_clean"
else
  fail "check_todos_accepts_module_dir_clean" "clean module dir was flagged"
fi

# 2: check-todos DETECTS an embedded marker in the module dir
printf '# API\nTODO: finish this section\n' > "$MOD/README.md"
if ! bash "$HERE/check-todos.sh" "$MOD" >/dev/null 2>&1; then
  pass "check_todos_detects_in_module_dir"
else
  fail "check_todos_detects_in_module_dir" "embedded TODO not flagged in module dir"
fi

# 3: validate-links DETECTS a broken link in the module dir
printf '# API\nSee [missing](nope.md).\n' > "$MOD/README.md"
if ! bash "$HERE/validate-links.sh" "$MOD" >/dev/null 2>&1; then
  pass "validate_links_detects_in_module_dir"
else
  fail "validate_links_detects_in_module_dir" "broken link not flagged in module dir"
fi

# 4: validate-links passes a valid cross-link in the module dir
printf '# API\nSee [other](other.md).\n' > "$MOD/README.md"
if bash "$HERE/validate-links.sh" "$MOD" >/dev/null 2>&1; then
  pass "validate_links_accepts_module_dir"
else
  fail "validate_links_accepts_module_dir" "valid link in module dir flagged"
fi

# 5: check-freshness accepts the dir without erroring (skips cleanly outside git)
if bash "$HERE/check-freshness.sh" "$MOD" 30 >/dev/null 2>&1; then
  pass "check_freshness_accepts_module_dir"
else
  fail "check_freshness_accepts_module_dir" "check-freshness errored on module dir"
fi

# 6: contract — the user-invocable SKILL mandates an independent review after
# every docs edit (so a direct skill invocation cannot bypass it), with a safe
# no-Agent fallback and a repeat-after-fixes rule.
SKILL="$(cd "$HERE/.." && pwd)/skills/creating-docs/SKILL.md"
if grep -qi "MANDATORY independent review" "$SKILL" \
   && grep -q "creating-docs:doc-reviewer" "$SKILL" \
   && grep -qi "Fallback" "$SKILL" \
   && grep -qi "Repeat after fixes" "$SKILL"; then
  pass "skill_mandates_independent_review"
else
  fail "skill_mandates_independent_review" "SKILL.md missing the mandatory-review contract"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
