#!/usr/bin/env bash
# test-batch-search.sh — memory-search.sh --batch must be byte-identical to
# the per-query loop it replaces (0.3.24), including --explain provenance,
# degraded-query fallback, status demotion, --limit truncation and stderr;
# and every invalid line must fail the whole batch before any output.
#
# Accumulating, not fail-fast. Uses a throwaway fixture store only.
set -uo pipefail

# --- test isolation (do not remove) ---------------------------------------
unset KNOWLEDGE_MEMORY_HOME
unset KNOWLEDGE_AUTO_RECALL KNOWLEDGE_AUTO_RECALL_LIMIT KNOWLEDGE_AUTO_RECALL_TERMS
unset KNOWLEDGE_AUTO_RECALL_BUDGET KNOWLEDGE_AUTO_RECALL_GRAPH KNOWLEDGE_CONSOLIDATE_NUDGE
# ---------------------------------------------------------------------------

HERE="$(cd "$(dirname "$0")" && pwd)"
SEARCH="$HERE/memory-search.sh"

PASS=0
FAIL=0
FAILURES=()
pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1: $2"); echo "  FAIL  $1 -- $2"; }

TMP="$(mktemp -d -t kmbatch-test-XXXXXX)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
# The store resolver requires a git repository around the store.
git -C "$TMP" init -q 2>/dev/null
STORE="$TMP/.agents/memory"
mkdir -p "$STORE"
: > "$STORE/MEMORY.md"

# mem <slug> <type> <status> <description> <tags-csv> <body>
mem() {
  local slug="$1" type="$2" status="$3" desc="$4" tags="$5" body="$6"
  {
    printf -- '---\nschema_version: 1\nname: %s\ndescription: %s\nmetadata:\n  type: %s\ncreated: 2026-01-01\nupdated: 2026-01-02\nstatus: %s\ntags:\n' "$slug" "$desc" "$type" "$status"
    local IFS=','
    for t in $tags; do printf '  - %s\n' "$t"; done
    printf -- '---\n# %s\n\n%s\n' "$slug" "$body"
  } > "$STORE/$slug.md"
  printf -- '- [%s](%s.md) — %s\n' "$slug" "$slug" "$desc" >> "$STORE/MEMORY.md"
}

mem project_release_flow project active "Release flow and version bump sites" "release,versions" "Bump every manifest before a release. The release checklist lives here."
mem feedback_release_gate feedback active "Release gate must run the validator" "release,gate" "Run validate-release before any release tag."
mem reference_queue_lock reference active "Queue lock and dispatch ordering" "queue,lock" "The dispatch queue lock serialises fan-in. Lock wait resets when the queue moves."
mem project_stale_release project stale "Old release notes (stale)" "release" "Superseded release procedure kept for history."
mem project_archived_lock project archived "Archived lock design" "lock" "Archived note about the queue lock."
mem reference_tmux_panes reference active "tmux pane naming and resolve rules" "tmux,panes" "Pane labels must stay in the safe charset."
mem project_prefix_alpha project active "Prefix alpha test memory" "prefix" "alphabet alphanumeric alpine words for prefix matching."
mem project_many_release project active "Release mention one" "release" "release release release everywhere in this body for limit testing."
mem project_many_release_two project active "Release mention two" "release" "another release heavy memory body release."
mem project_many_release_three project active "Release mention three" "release" "third release heavy memory body release."

QUERIES=$(printf '%s\n' \
  'release' \
  '"queue lock"' \
  'alp*' \
  'release nonexistentzzz' \
  'nonexistentzzz' \
  'lock' \
  'release')

TAB="$(printf '\t')"

loop_run() { # $1 = extra flags (may be empty)
  local flags="$1"
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    # shellcheck disable=SC2086
    bash "$SEARCH" --store "$STORE" --limit 2 $flags "$q" 2>>"$TMP/loop.err" | awk -F "$TAB" -v t="$q" '{ print $0 "\t" t }'
  done <<EOF
$QUERIES
EOF
}

# --- 1. plain batch == per-query loop --------------------------------------
: > "$TMP/loop.err"
loop_run "" > "$TMP/loop.out"
printf '%s\n' "$QUERIES" | bash "$SEARCH" --batch --store "$STORE" --limit 2 > "$TMP/batch.out" 2> "$TMP/batch.err"
rc=$?
[ "$rc" -eq 0 ] && pass "plain batch exits 0" || fail "plain batch exits 0" "rc=$rc"
if cmp -s "$TMP/loop.out" "$TMP/batch.out"; then pass "plain batch stdout == loop stdout"; else fail "plain batch stdout == loop stdout" "$(diff "$TMP/loop.out" "$TMP/batch.out" | head -5)"; fi
[ -s "$TMP/batch.out" ] && pass "plain batch produced rows" || fail "plain batch produced rows" "empty"

# --- 2. --explain batch == loop, byte-identical incl. provenance -----------
: > "$TMP/loop.err"
loop_run "--explain" > "$TMP/loop-x.out"
printf '%s\n' "$QUERIES" | bash "$SEARCH" --batch --store "$STORE" --limit 2 --explain > "$TMP/batch-x.out" 2> "$TMP/batch-x.err"
if cmp -s "$TMP/loop-x.out" "$TMP/batch-x.out"; then pass "explain batch stdout == loop stdout"; else fail "explain batch stdout == loop stdout" "$(diff "$TMP/loop-x.out" "$TMP/batch-x.out" | head -5)"; fi
cols=$(awk -F "$TAB" 'NR==1 { print NF }' "$TMP/batch-x.out")
[ "$cols" = "7" ] && pass "explain batch rows have 7 columns" || fail "explain batch rows have 7 columns" "got $cols"

# --- 3. stderr parity (degraded + truncated lines) -------------------------
if cmp -s "$TMP/loop.err" "$TMP/batch-x.err"; then pass "stderr parity (degraded/truncated)"; else fail "stderr parity (degraded/truncated)" "$(diff "$TMP/loop.err" "$TMP/batch-x.err" | head -5)"; fi
grep -q "degraded" "$TMP/batch-x.err" && pass "degraded fallback exercised" || fail "degraded fallback exercised" "no degraded line in stderr"
# --limit applies per query: 'release' matches 6 memories but each occurrence
# of the query yields exactly 2 rows (asserted in section 4 as 2 x 2).

# --- 4. semantics inside the batch ----------------------------------------
n_rel=$(awk -F "$TAB" '$NF == "release"' "$TMP/batch-x.out" | wc -l | tr -d ' ')
[ "$n_rel" = "4" ] && pass "repeated query line repeats its rows (2 x limit 2)" || fail "repeated query line repeats its rows" "got $n_rel rows for release"
awk -F "$TAB" '$NF == "lock" && $2 == "project_archived_lock" && $4 == "archived" { found=1 } END { exit !found }' "$TMP/batch-x.out" \
  && pass "inactive-status row carried with status column" || fail "inactive-status row carried with status column" "archived slug missing"
awk -F "$TAB" '$NF == "lock" { print $1 "\t" $2 }' "$TMP/batch-x.out" > "$TMP/lock.rows"
head -1 "$TMP/lock.rows" | grep -q "reference_queue_lock" && pass "active slug outranks archived (status demotion)" || fail "active slug outranks archived" "$(cat "$TMP/lock.rows")"
awk -F "$TAB" '$NF == "nonexistentzzz"' "$TMP/batch-x.out" | grep -q . && fail "zero-hit term contributes no rows" "rows present" || pass "zero-hit term contributes no rows"

# --- 5. CONTROL: the comparison can fail -----------------------------------
sed '1s/^/X/' "$TMP/batch-x.out" > "$TMP/mutated.out"
if cmp -s "$TMP/loop-x.out" "$TMP/mutated.out"; then fail "control: mutated row is detected" "cmp still equal"; else pass "control: mutated row is detected"; fi

# --- 6. error paths --------------------------------------------------------
out=$(printf 'a\tb\n' | bash "$SEARCH" --batch --store "$STORE" 2>"$TMP/e1"); rc=$?
[ "$rc" -eq 2 ] && [ -z "$out" ] && pass "tab in query line -> exit 2, empty stdout" || fail "tab in query line -> exit 2, empty stdout" "rc=$rc out=[$out]"
out=$(printf 'release\r\n' | bash "$SEARCH" --batch --store "$STORE" 2>/dev/null); rc=$?
[ "$rc" -eq 2 ] && [ -z "$out" ] && pass "CR in query line -> exit 2" || fail "CR in query line -> exit 2" "rc=$rc"
out=$(printf 'release\n"unbalanced\nlock\n' | bash "$SEARCH" --batch --store "$STORE" 2>"$TMP/e2"); rc=$?
[ "$rc" -eq 2 ] && [ -z "$out" ] && pass "invalid query anywhere -> whole batch exit 2, no output" || fail "invalid query anywhere -> whole batch exit 2, no output" "rc=$rc out=[$out]"
grep -q "invalid query" "$TMP/e2" && pass "invalid query reported on stderr" || fail "invalid query reported on stderr" "$(cat "$TMP/e2")"
out=$(bash "$SEARCH" --batch --store "$STORE" positional 2>/dev/null </dev/null); rc=$?
[ "$rc" -eq 2 ] && pass "--batch with positional arg -> exit 2" || fail "--batch with positional arg -> exit 2" "rc=$rc"
out=$(printf 'release\n' | bash "$SEARCH" --batch --json --store "$STORE" 2>/dev/null); rc=$?
[ "$rc" -eq 2 ] && pass "--batch --json -> exit 2" || fail "--batch --json -> exit 2" "rc=$rc"
out=$(printf 'release\n' | bash "$SEARCH" --batch --recall --store "$STORE" 2>/dev/null); rc=$?
[ "$rc" -eq 2 ] && pass "--batch --recall -> exit 2" || fail "--batch --recall -> exit 2" "rc=$rc"
out=$(printf '' | bash "$SEARCH" --batch --store "$STORE" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && pass "empty stdin -> exit 0, no output" || fail "empty stdin -> exit 0, no output" "rc=$rc out=[$out]"
out=$(printf '\n\n' | bash "$SEARCH" --batch --store "$STORE" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && pass "blank lines only -> exit 0, no output" || fail "blank lines only -> exit 0, no output" "rc=$rc"

# --- 7. single-query path unchanged (no --batch) --------------------------
single=$(bash "$SEARCH" --store "$STORE" --limit 2 --explain release 2>/dev/null)
cols=$(printf '%s\n' "$single" | awk -F "$TAB" 'NR==1 { print NF }')
[ "$cols" = "6" ] && pass "single --explain call still has 6 columns" || fail "single --explain call still has 6 columns" "got $cols"

echo
echo "=== $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
