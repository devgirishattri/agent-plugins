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
   && grep -q "knowledge:doc-reviewer" "$SKILL" \
   && grep -qi "Fallback" "$SKILL" \
   && grep -qi "Repeat after fixes" "$SKILL"; then
  pass "skill_mandates_independent_review"
else
  fail "skill_mandates_independent_review" "SKILL.md missing the mandatory-review contract"
fi

# --- docs-write.sh: the ONE deliberate Phase A behavior change ------------
# The docs-create workflow must run this reviewer-role preflight FIRST and
# stop on any non-zero exit, before writing or editing any doc.
DW="$HERE/docs-write.sh"

# 7: usage grammar — anything other than exactly `--repo <path>` is exit 2.
out=$(bash "$DW" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "docs_write_usage_rejects_no_args"; else fail "docs_write_usage_rejects_no_args" "rc=$rc out=$out"; fi
out=$(bash "$DW" --repo "" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "docs_write_usage_rejects_empty_value"; else fail "docs_write_usage_rejects_empty_value" "rc=$rc out=$out"; fi
out=$(bash "$DW" --repo "$TMP" extra 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "docs_write_usage_rejects_trailing_token"; else fail "docs_write_usage_rejects_trailing_token" "rc=$rc out=$out"; fi
out=$(bash "$DW" --wrong-flag "$TMP" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "docs_write_usage_rejects_unknown_flag"; else fail "docs_write_usage_rejects_unknown_flag" "rc=$rc out=$out"; fi

# 8: a *-reviewer pane name refuses with the exact stderr line, exit 6.
out=$(KNOWLEDGE_PANE_NAME="test-reviewer" bash "$DW" --repo "$TMP" 2>&1); rc=$?
if [ "$rc" -eq 6 ] && printf '%s' "$out" | grep -qF "reviewer role: docs writes refused"; then
  pass "docs_write_refuses_reviewer_role"
else
  fail "docs_write_refuses_reviewer_role" "rc=$rc out=$out"
fi

# 9: true solo use (no pane-name source, outside tmux) proceeds, exit 0.
out=$(env -u TMUX -u TMUX_PANE -u KNOWLEDGE_PANE_NAME -u SESSION_CHAT_PANE_NAME \
  bash "$DW" --repo "$TMP" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  pass "docs_write_solo_outside_tmux_proceeds"
else
  fail "docs_write_solo_outside_tmux_proceeds" "rc=$rc out=$out"
fi

# 10: inside tmux with no resolvable name is an UNRESOLVED FLEET IDENTITY —
# fail closed rather than silently defaulting to executor authority.
out=$(env -u KNOWLEDGE_PANE_NAME -u SESSION_CHAT_PANE_NAME -u TMUX_PANE \
  TMUX="fake-socket,0,0" bash "$DW" --repo "$TMP" 2>&1); rc=$?
if [ "$rc" -eq 6 ] && printf '%s' "$out" | grep -qF "unresolved pane identity: set KNOWLEDGE_PANE_NAME"; then
  pass "docs_write_unresolved_fleet_identity_fails_closed"
else
  fail "docs_write_unresolved_fleet_identity_fails_closed" "rc=$rc out=$out"
fi

# 11: SESSION_CHAT_PANE_NAME is consulted when KNOWLEDGE_PANE_NAME is absent.
out=$(env -u KNOWLEDGE_PANE_NAME SESSION_CHAT_PANE_NAME="peer-reviewer" bash "$DW" --repo "$TMP" 2>&1); rc=$?
if [ "$rc" -eq 6 ] && printf '%s' "$out" | grep -qF "reviewer role: docs writes refused"; then
  pass "docs_write_falls_back_to_session_chat_pane_name"
else
  fail "docs_write_falls_back_to_session_chat_pane_name" "rc=$rc out=$out"
fi

# 12: KNOWLEDGE_PANE_NAME takes precedence over SESSION_CHAT_PANE_NAME even
# when the latter looks like a reviewer — first non-empty source wins.
out=$(KNOWLEDGE_PANE_NAME="executor-1" SESSION_CHAT_PANE_NAME="peer-reviewer" bash "$DW" --repo "$TMP" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  pass "docs_write_knowledge_pane_name_takes_precedence"
else
  fail "docs_write_knowledge_pane_name_takes_precedence" "rc=$rc out=$out"
fi

# 13: the docs-create command and skill both wire the preflight in as step
# one, with a stop-on-non-zero instruction — a direct invocation of either
# cannot silently skip the gate.
CMD="$(cd "$HERE/.." && pwd)/commands/docs-create.md"
if grep -q "docs-write.sh" "$CMD" && grep -qi "stop" "$CMD" \
   && grep -q "docs-write.sh" "$SKILL" && grep -qi "MANDATORY" "$SKILL" \
   && grep -q "run FIRST" "$SKILL"; then
  pass "docs_create_wires_preflight_first"
else
  fail "docs_create_wires_preflight_first" "command or skill missing the preflight wiring"
fi

# 14: the preflight invocation is a single literal trusted-helper segment in
# both surfaces — repo root resolved in a separate step, never via command
# substitution embedded in the helper call.
LITERAL='bash "${CLAUDE_PLUGIN_ROOT}/scripts/docs-write.sh" --repo "<REPO_ROOT>"'
if grep -qF "$LITERAL" "$CMD" && grep -qF "$LITERAL" "$SKILL" \
   && ! grep -F "docs-write.sh" "$CMD" | grep -q '\$(' \
   && ! grep -F "docs-write.sh" "$SKILL" | grep -q '\$('; then
  pass "docs_create_preflight_is_literal_segment"
else
  fail "docs_create_preflight_is_literal_segment" "embedded substitution or non-literal helper call"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
