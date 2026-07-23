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
# empty inbox → silent (JSON mode)
out="$(printf '{"stop_hook_active":false}' | KNOWLEDGE_MEMORY_HOME="$nstore" KNOWLEDGE_CONSOLIDATE_NUDGE=1 bash "$NUDGE" --stop-json)"
assert_empty nudge_empty_inbox_silent "$out"

cand="$TMP/cand1.md"
stage_candidate "$cand" "sess-1" "ProjectA Note" "a captured learning about widgets" project
bash "$REMEMBER" --store "$nstore" --staged "$cand" > /dev/null 2>&1

# gate off → silent even with a pending candidate
out="$(printf '{"stop_hook_active":false}' | KNOWLEDGE_MEMORY_HOME="$nstore" bash "$NUDGE" --stop-json)"
assert_empty nudge_gateoff_silent "$out"

# gate on + candidate + --stop-json → valid non-blocking Claude Stop JSON
before_idx="$(sha "$nstore/MEMORY.md")"
out="$(printf '{"stop_hook_active":false}' | KNOWLEDGE_MEMORY_HOME="$nstore" KNOWLEDGE_CONSOLIDATE_NUDGE=1 bash "$NUDGE" --stop-json)"
assert_contains nudge_json_event   "$out" "\"hookEventName\":\"Stop\""
assert_contains nudge_json_context "$out" "additionalContext"
assert_contains nudge_json_message "$out" "consolidate"
assert_not_contains nudge_json_nonblocking "$out" "\"decision\""
if printf '%s' "$out" | python3 -c 'import sys,json; d=json.load(sys.stdin); h=d["hookSpecificOutput"]; assert h["hookEventName"]=="Stop" and "consolidate" in h["additionalContext"]' 2>/dev/null; then
  pass nudge_json_valid
else
  fail nudge_json_valid "not valid Stop JSON: $out"
fi
# never writes; candidate still pending (nudge does not consume it)
assert_eq nudge_never_writes_index "$before_idx" "$(sha "$nstore/MEMORY.md")"
still="$(bash "$REMEMBER" --store "$nstore" --list 2>/dev/null | grep -c . || true)"
assert_eq nudge_leaves_candidate "1" "$still"

# stop_hook_active guard → silent (defence against any stop-continuation loop)
out="$(printf '{"stop_hook_active":true}' | KNOWLEDGE_MEMORY_HOME="$nstore" KNOWLEDGE_CONSOLIDATE_NUDGE=1 bash "$NUDGE" --stop-json)"
assert_empty nudge_stop_hook_active_guard "$out"

# plain-text mode (no flag) still emits a line (CLI use); never JSON
out="$(KNOWLEDGE_MEMORY_HOME="$nstore" KNOWLEDGE_CONSOLIDATE_NUDGE=1 bash "$NUDGE" < /dev/null)"
assert_contains     nudge_plain_line "$out" "consolidate"
assert_not_contains nudge_plain_not_json "$out" "hookSpecificOutput"

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
cat > "$fstore/MEMORY.md" <<EOF
- [AA](aa_nostatus.md) — canonical no status
EOF

# default lint (no --fix) must NOT mutate anything
ha="$(sha "$fstore/aa_nostatus.md")"; hb="$(sha "$fstore/bb_nested.md")"; hi="$(sha "$fstore/MEMORY.md")"
bash "$LINT" --store "$fstore" > /dev/null 2>&1
assert_eq fix_readonly_file_a  "$ha" "$(sha "$fstore/aa_nostatus.md")"
assert_eq fix_readonly_file_b  "$hb" "$(sha "$fstore/bb_nested.md")"
assert_eq fix_readonly_index   "$hi" "$(sha "$fstore/MEMORY.md")"

# --fix
fixout="$(bash "$LINT" --fix --store "$fstore" 2>&1)"
assert_contains fix_reports_a         "$fixout" "aa_nostatus.md"
assert_contains fix_reports_index_add "$fixout" "added missing MEMORY.md index row"
assert_contains fix_a_toplevel_active "$(grep -E '^status:' "$fstore/aa_nostatus.md" || true)" "status: active"
assert_contains fix_b_toplevel_stale  "$(grep -E '^status:' "$fstore/bb_nested.md"  || true)" "status: stale"
assert_empty    fix_b_no_nested       "$(grep -E '^[[:space:]]+status:' "$fstore/bb_nested.md" || true)"
assert_contains fix_index_has_bb      "$(cat "$fstore/MEMORY.md")" "bb_nested.md"

bash "$LINT" --store "$fstore" > /dev/null 2>&1
assert_rc fix_lint_clean_after 0 "$?"

fixout2="$(bash "$LINT" --fix --store "$fstore" 2>&1)"
assert_not_contains fix_idempotent "$fixout2" "FIXED"

# --- finding 2 regression: frontmatter-only transform must NOT touch body ---
btstore="$(bootstrap_store "$TMP/bodytrap")"
cat > "$btstore/body_trap.md" <<EOF
---
schema_version: 1
name: Body Trap
description: an indented body status line must survive --fix
metadata:
  type: reference
created: 2026-01-01
updated: 2026-01-02
---
Example config:
\`\`\`yaml
service:
  status: keep_me_in_body
  updated: 2020-01-01
\`\`\`
EOF
printf -- '- [Body Trap](body_trap.md) — an indented body status line must survive --fix\n' > "$btstore/MEMORY.md"
bash "$LINT" --fix --store "$btstore" > /dev/null 2>&1
assert_contains fix_body_status_preserved  "$(cat "$btstore/body_trap.md")" "status: keep_me_in_body"
assert_contains fix_body_updated_preserved  "$(cat "$btstore/body_trap.md")" "updated: 2020-01-01"
assert_contains fix_body_toplevel_added     "$(grep -E '^status:' "$btstore/body_trap.md" || true)" "status: active"

# --- finding 3 regression: reviewer role → exit 6, refusal surfaced, no write --
rvstore="$(bootstrap_store "$TMP/reviewer")"
cat > "$rvstore/needs_status.md" <<EOF
---
schema_version: 1
name: Needs Status
description: canonical missing status
metadata:
  type: reference
created: 2026-01-01
updated: 2026-01-02
---
Body.
EOF
printf -- '- [Needs Status](needs_status.md) — canonical missing status\n' > "$rvstore/MEMORY.md"
h_before="$(sha "$rvstore/needs_status.md")"
# The normalizer relays the writer's reviewer refusal to STDERR and exits 6
# (proper error semantics — not a stdout report row).
rout="$(KNOWLEDGE_PANE_NAME=demo-reviewer bash "$LINT" --fix --store "$rvstore" 2>&1)"; rrc=$?
assert_rc       fix_reviewer_exit6       6 "$rrc"
assert_contains fix_reviewer_refused     "$rout" "refused"
assert_eq       fix_reviewer_no_mutation "$h_before" "$(sha "$rvstore/needs_status.md")"

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
