#!/usr/bin/env bash
# test-auto.sh — hermetic tests for the 0.2 opt-in "automatic" surfaces:
#   * inject-recall.sh   — SessionStart index injection + UserPromptSubmit
#                          salient-term union recall (opt-in, safe-fallback).
#   * nudge-consolidate.sh — Stop capture-inbox nudge (opt-in, never writes).
#   * memory-lint.sh --fix — the delegating status/index normalizer.
# All fixtures are synthetic (ProjectA/ProjectB, zephyr/quokka/widget) — never
# real project names. Isolated git repos under a temp dir; cleans up on exit.
#
# Usage: bash test-auto.sh [-v]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INJECT="$HERE/inject-recall.sh"
NUDGE="$HERE/nudge-consolidate.sh"
LINT="$HERE/memory-lint.sh"
WRITER="$HERE/memory-write.sh"
REMEMBER="$HERE/memory-remember.sh"

PASS=0
FAIL=0
FAILURES=()
TMP="$(mktemp -d -t kmauto-test-XXXXXX)"
TMP="$(cd "$TMP" && pwd -P)"
cleanup() { chmod -R u+rwx "$TMP" 2>/dev/null || true; rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT
echo "=== auto (0.2 recall/capture/normalizer) tests (tmp: $TMP) ==="

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1: $2"); echo "  FAIL  $1 -- $2"; }
assert_rc()   { [ "$3" = "$2" ] && pass "$1" || fail "$1" "expected rc=$2 got rc=$3"; }
assert_eq()   { [ "$3" = "$2" ] && pass "$1" || fail "$1" "expected [$2] got [$3]"; }
assert_empty()    { [ -z "$2" ] && pass "$1" || fail "$1" "expected empty, got [$2]"; }
assert_nonempty() { [ -n "$2" ] && pass "$1" || fail "$1" "expected non-empty output"; }
assert_contains()     { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "want [$3] in: $2" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) fail "$1" "unwanted [$3] in: $2" ;; *) pass "$1" ;; esac; }

new_repo() { local d="$1"; rm -rf "$d"; mkdir -p "$d"; (cd "$d" && git init -q .); }
bootstrap_store() {
  local d="$1" store
  new_repo "$d"
  (cd "$d" && echo ".agents/memory/" >> .gitignore && git add .gitignore && git commit -q -m init)
  store="$d/.agents/memory"
  bash "$WRITER" bootstrap --store "$store" > /dev/null 2>&1
  (cd "$store" && pwd -P)
}
write_canonical() {
  # write_canonical <path> <type> <name> <desc>
  cat > "$1" <<EOF
---
schema_version: 1
name: $3
description: $4
metadata:
  type: $2
status: active
created: 2026-01-01
updated: 2026-01-02
---
**Why:** synthetic fixture.

**How to apply:** synthetic fixture.
EOF
}
stage_candidate() {
  # stage_candidate <path> <source> <name> <desc> <type>
  {
    echo "---"; echo "source: $2"; echo "sensitivity: normal"; echo "proposed:"
    echo "  schema_version: \"1\""; echo "  name: $3"; echo "  description: $4"
    echo "  metadata:"; echo "    type: $5"; echo "---"
    echo "**Why:** synthetic capture."; echo; echo "**How to apply:** n/a."
  } > "$1"
}
sha() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }
mkprompt() { printf '{"prompt":"%s"}' "$1"; }
body_payload() { awk 'body { print } /^---$/ { fences += 1; if (fences == 2) body = 1 }' "$1"; }

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------
store="$(bootstrap_store "$TMP/main")"
write_canonical "$store/alpha_zephyr.md" reference "Alpha Zephyr" "the zephyr calibration procedure for widget sensors"
write_canonical "$store/beta_quokka.md"  project   "Beta Quokka"  "quokka deployment rollback runbook"
cat > "$store/MEMORY.md" <<EOF
- [Alpha Zephyr](alpha_zephyr.md) — the zephyr calibration procedure for widget sensors
- [Beta Quokka](beta_quokka.md) — quokka deployment rollback runbook
EOF

# ---------------------------------------------------------------------------
# inject-recall — SessionStart index mode
# ---------------------------------------------------------------------------
out="$(KNOWLEDGE_MEMORY_HOME="$store" bash "$INJECT" --session-start)"; rc=$?
assert_rc    inject_session_gateoff_rc 0 "$rc"
assert_empty inject_session_gateoff_silent "$out"

out="$(KNOWLEDGE_MEMORY_HOME="$store" KNOWLEDGE_AUTO_RECALL=1 bash "$INJECT" --session-start)"; rc=$?
assert_rc       inject_session_on_rc 0 "$rc"
assert_contains inject_session_untrusted "$out" "untrusted background context"
assert_contains inject_session_hasrow    "$out" "alpha_zephyr.md"

out="$(KNOWLEDGE_MEMORY_HOME="$store" KNOWLEDGE_AUTO_RECALL=1 bash "$INJECT" --bogus)"
assert_empty inject_badmode_silent "$out"

out="$(KNOWLEDGE_MEMORY_HOME="$store" KNOWLEDGE_AUTO_RECALL=1 KNOWLEDGE_AUTO_RECALL_BUDGET=120 bash "$INJECT" --session-start)"
assert_contains inject_session_budget_truncates "$out" "truncated"

estore="$(bootstrap_store "$TMP/empty")"
out="$(KNOWLEDGE_MEMORY_HOME="$estore" KNOWLEDGE_AUTO_RECALL=1 bash "$INJECT" --session-start)"
assert_empty inject_session_emptyindex_silent "$out"

# ---------------------------------------------------------------------------
# inject-recall — UserPromptSubmit term-union recall mode
# ---------------------------------------------------------------------------
out="$(mkprompt "how do I run the zephyr calibration on the widget" | KNOWLEDGE_MEMORY_HOME="$store" KNOWLEDGE_AUTO_RECALL=1 bash "$INJECT" --prompt)"
assert_contains     inject_prompt_hit          "$out" "alpha_zephyr"
assert_contains     inject_prompt_untrusted    "$out" "untrusted background context"
assert_not_contains inject_prompt_only_relevant "$out" "beta_quokka"

out="$(mkprompt "zephyr calibration widget" | KNOWLEDGE_MEMORY_HOME="$store" bash "$INJECT" --prompt)"
assert_empty inject_prompt_gateoff "$out"

out="$(mkprompt "please compose a cheerful limerick about autumn foliage" | KNOWLEDGE_MEMORY_HOME="$store" KNOWLEDGE_AUTO_RECALL=1 bash "$INJECT" --prompt)"
assert_empty inject_prompt_unrelated_suppressed "$out"

out="$(printf 'not valid json at all' | KNOWLEDGE_MEMORY_HOME="$store" KNOWLEDGE_AUTO_RECALL=1 bash "$INJECT" --prompt)"
assert_empty inject_prompt_malformed_stdin "$out"

out="$(mkprompt "hi" | KNOWLEDGE_MEMORY_HOME="$store" KNOWLEDGE_AUTO_RECALL=1 bash "$INJECT" --prompt)"
assert_empty inject_prompt_trivial_short "$out"

out="$(printf '' | KNOWLEDGE_MEMORY_HOME="$store" KNOWLEDGE_AUTO_RECALL=1 bash "$INJECT" --prompt)"
assert_empty inject_prompt_empty_stdin "$out"

# ---------------------------------------------------------------------------
# nudge-consolidate — Stop capture nudge
# ---------------------------------------------------------------------------
nstore="$(bootstrap_store "$TMP/nudge")"
out="$(KNOWLEDGE_MEMORY_HOME="$nstore" KNOWLEDGE_CONSOLIDATE_NUDGE=1 bash "$NUDGE")"
assert_empty nudge_empty_inbox_silent "$out"

cand="$TMP/cand1.md"
stage_candidate "$cand" "sess-1" "ProjectA Note" "a captured learning about widgets" project
bash "$REMEMBER" --store "$nstore" --staged "$cand" > /dev/null 2>&1

out="$(KNOWLEDGE_MEMORY_HOME="$nstore" bash "$NUDGE")"
assert_empty nudge_gateoff_silent "$out"

before_idx="$(sha "$nstore/MEMORY.md")"
out="$(KNOWLEDGE_MEMORY_HOME="$nstore" KNOWLEDGE_CONSOLIDATE_NUDGE=1 bash "$NUDGE")"
assert_contains nudge_fires_on_candidate "$out" "consolidate"
assert_eq nudge_never_writes_index "$before_idx" "$(sha "$nstore/MEMORY.md")"
# candidate must still be pending (nudge does not consume it)
still="$(bash "$REMEMBER" --store "$nstore" --list 2>/dev/null | grep -c . || true)"
assert_eq nudge_leaves_candidate "1" "$still"

out="$(printf '{"hook_event_name":"Stop","stop_hook_active":false}' | KNOWLEDGE_MEMORY_HOME="$nstore" KNOWLEDGE_CONSOLIDATE_NUDGE=1 bash "$NUDGE" --stop-json)"
if printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("decision") == "block"; assert "consolidate" in d.get("reason", "")' 2>/dev/null; then
  pass nudge_stop_json_valid
else
  fail nudge_stop_json_valid "expected valid Codex Stop decision JSON, got [$out]"
fi
out="$(printf '{"hook_event_name":"Stop","stop_hook_active":true}' | KNOWLEDGE_MEMORY_HOME="$nstore" KNOWLEDGE_CONSOLIDATE_NUDGE=1 bash "$NUDGE" --stop-json)"
assert_empty nudge_stop_json_reentry_guard "$out"

# ---------------------------------------------------------------------------
# memory-lint --fix — normalizer
# ---------------------------------------------------------------------------
fstore="$(bootstrap_store "$TMP/fix")"
# aa: canonical, NO status anywhere
cat > "$fstore/aa_nostatus.md" <<EOF
---
schema_version: 1
name: AA
description: canonical no status
metadata:
  type: reference
created: 2026-01-01
updated: 2026-01-02
---
Body.
EOF
# bb: canonical, mis-nested status stale (value must be preserved) + orphaned
cat > "$fstore/bb_nested.md" <<EOF
---
schema_version: 1
name: BB
description: nested stale status and not in index
metadata:
  type: reference
  status: stale
created: 2026-01-01
updated: 2026-01-02
---
Body.
EOF
# cc: canonical, mis-nested status, with body status/updated examples that must
# survive --fix byte-for-byte after the frontmatter closes.
cat > "$fstore/cc_body.md" <<EOF
---
schema_version: 1
name: CC
description: nested archived status with body examples
metadata:
  type: reference
  status: archived
created: 2026-01-01
updated: 2026-01-02
---
Example body:

\`\`\`yaml
  status: should_remain_in_body
  updated: should_remain_in_body
\`\`\`
EOF
cat > "$fstore/MEMORY.md" <<EOF
- [AA](aa_nostatus.md) — canonical no status
- [CC](cc_body.md) — nested archived status with body examples
EOF

# default lint (no --fix) must NOT mutate anything
ha="$(sha "$fstore/aa_nostatus.md")"; hb="$(sha "$fstore/bb_nested.md")"; hc="$(sha "$fstore/cc_body.md")"; hi="$(sha "$fstore/MEMORY.md")"
body_c_before="$(body_payload "$fstore/cc_body.md")"
bash "$LINT" --store "$fstore" > /dev/null 2>&1
assert_eq fix_readonly_file_a  "$ha" "$(sha "$fstore/aa_nostatus.md")"
assert_eq fix_readonly_file_b  "$hb" "$(sha "$fstore/bb_nested.md")"
assert_eq fix_readonly_file_c  "$hc" "$(sha "$fstore/cc_body.md")"
assert_eq fix_readonly_index   "$hi" "$(sha "$fstore/MEMORY.md")"

# --fix
fixout="$(bash "$LINT" --fix --store "$fstore" 2>&1)"
assert_contains fix_reports_a         "$fixout" "aa_nostatus.md"
assert_contains fix_reports_index_add "$fixout" "added missing MEMORY.md index row"
assert_contains fix_a_toplevel_active "$(grep -E '^status:' "$fstore/aa_nostatus.md" || true)" "status: active"
assert_contains fix_b_toplevel_stale  "$(grep -E '^status:' "$fstore/bb_nested.md"  || true)" "status: stale"
assert_contains fix_c_toplevel_archived "$(grep -E '^status:' "$fstore/cc_body.md" || true)" "status: archived"
assert_empty    fix_b_no_nested       "$(grep -E '^[[:space:]]+status:' "$fstore/bb_nested.md" || true)"
assert_eq       fix_c_body_preserved  "$body_c_before" "$(body_payload "$fstore/cc_body.md")"
assert_contains fix_index_has_bb      "$(cat "$fstore/MEMORY.md")" "bb_nested.md"

bash "$LINT" --store "$fstore" > /dev/null 2>&1
assert_rc fix_lint_clean_after 0 "$?"

fixout2="$(bash "$LINT" --fix --store "$fstore" 2>&1)"
assert_not_contains fix_idempotent "$fixout2" "FIXED"

rstore="$(bootstrap_store "$TMP/reviewer")"
cat > "$rstore/reviewer_refusal.md" <<EOF
---
schema_version: 1
name: Reviewer Refusal
description: canonical no status for reviewer refusal
metadata:
  type: reference
created: 2026-01-01
updated: 2026-01-02
---
Body.
EOF
cat > "$rstore/MEMORY.md" <<EOF
- [Reviewer Refusal](reviewer_refusal.md) — canonical no status for reviewer refusal
EOF
rh="$(sha "$rstore/reviewer_refusal.md")"
review_out="$(KNOWLEDGE_PANE_NAME=agent-reviewer bash "$LINT" --fix --store "$rstore" 2>&1)"
review_rc=$?
assert_rc fix_reviewer_refusal_rc 6 "$review_rc"
assert_contains fix_reviewer_refusal_msg "$review_out" "reviewer role: memory writes refused"
assert_eq fix_reviewer_refusal_no_mutation "$rh" "$(sha "$rstore/reviewer_refusal.md")"

# ---------------------------------------------------------------------------
# syntax + zero-egress on the shipped hook scripts
# ---------------------------------------------------------------------------
for s in "$INJECT" "$NUDGE" "$LINT"; do
  if bash -n "$s" 2>/dev/null; then pass "bash_n_$(basename "$s")"; else fail "bash_n_$(basename "$s")" "syntax error"; fi
done
if grep -Eq 'curl|wget|http\.client|urllib|requests\.|socket\.connect' "$INJECT" "$NUDGE"; then
  fail egress_clean_hooks "network client invocation found"
else
  pass egress_clean_hooks
fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
echo ""
echo "=== $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  echo "Failures:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
