#!/usr/bin/env bash
# test-capture.sh — hermetic tests for Phase B3 (candidate capture):
# memory-remember.sh's planner/normalizer contract (--staged and --list
# modes), the `.inbox/` lifecycle (the remember contract
# bullet + capture grammar), and the remember->list->purge id pipeline
# through memory-write.sh purge. All fixture content is synthetic
# (ProjectA/ProjectB-style), never real project names. Uses isolated git
# repos under a temp dir; cleans up on exit.
#
# This suite intentionally does not re-test memory-write.sh's OWN
# lock/journal/recovery/apply-transaction internals (test-memory-kernel.sh
# already covers those exhaustively) — it tests the NEW B3 surface
# (memory-remember.sh) end to end, plus the parts of the writer's capture/
# purge contract that are directly on the remember->list->purge path.
#
# Usage: bash test-capture.sh [-v]
set -uo pipefail

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
unset KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING KNOWLEDGE_AUTO_CAPTURE_MAX_BYTES KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT
unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID
# KNOWLEDGE_PANE_NAME is deliberately NOT unset: it is the writer's role-detection
# identity, and clearing it pushes role checks onto a tmux probe that fails closed
# for an unnamed pane. Suites that test role behaviour set it explicitly.
# ---------------------------------------------------------------------------

HERE="$(cd "$(dirname "$0")" && pwd)"
WRITER="$HERE/memory-write.sh"
REMEMBER="$HERE/memory-remember.sh"
LINT="$HERE/memory-lint.sh"
INDEXTOOL="$HERE/memory-index.sh"

PASS=0
FAIL=0
FAILURES=()
TMP="$(mktemp -d -t kmcapture-test-XXXXXX)"
TMP="$(cd "$TMP" && pwd -P)"

cleanup() {
  chmod -R u+rwx "$TMP" 2>/dev/null || true
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1: $2"); echo "  FAIL  $1 -- $2"; }

# Default identity: a non-reviewer executor name, so writes proceed by
# default. Role-refusal tests override/unset this per invocation.
export KNOWLEDGE_PANE_NAME=test-executor
unset SESSION_CHAT_PANE_NAME 2>/dev/null || true

echo "=== capture (Phase B3) tests (tmp: $TMP) ==="

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
new_repo() {
  local d="$1"
  rm -rf "$d"
  mkdir -p "$d"
  (cd "$d" && git init -q .)
}

# bootstrap_store <repo-dir> -> echoes the canonical store path
bootstrap_store() {
  local d="$1" store
  new_repo "$d"
  (cd "$d" && echo ".agents/memory/" >> .gitignore && git add .gitignore && git commit -q -m init)
  store="$d/.agents/memory"
  bash "$WRITER" bootstrap --store "$store" > /dev/null 2>&1
  (cd "$store" && pwd -P)
}

mw_call() {
  bash -c "source '$WRITER'; $1"
}

assert_rc() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label" "expected rc=$expected got rc=$actual"
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label" "expected [$expected] got [$actual]"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label" "expected output to contain [$needle], got: $haystack" ;;
  esac
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) fail "$label" "expected output NOT to contain [$needle], got: $haystack" ;;
    *) pass "$label" ;;
  esac
}

assert_file_absent() {
  local label="$1" path="$2"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    pass "$label"
  else
    fail "$label" "expected $path to be absent"
  fi
}

assert_file_present() {
  local label="$1" path="$2"
  if [ -e "$path" ]; then
    pass "$label"
  else
    fail "$label" "expected $path to be present"
  fi
}

# tree_hash <dir> [name-pattern] -- stable aggregate hash of relpath+content
# for every regular file under dir (sorted); used to prove a read surface
# left the tree byte-identical. Plain shasum, not km_sha256_file (this is a
# test-only content fingerprint, not a store-safety check).
tree_hash() {
  local dir="$1" pattern="${2:-*}" f rel
  {
    find "$dir" -type f -name "$pattern" 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
      rel="${f#"$dir"/}"
      printf '%s\n' "$rel"
      shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
    done
  } | shasum -a 256 | awk '{print $1}'
}

# write_canonical <path> <type> <name> <desc> [created] [updated]
write_canonical() {
  local path="$1" type="$2" name="$3" desc="$4" created="${5:-2026-01-01}" updated="${6:-2026-01-02}"
  cat > "$path" <<EOF
---
schema_version: 1
name: $name
description: $desc
metadata:
  type: $type
created: $created
updated: $updated
---
**Why:** synthetic fixture reason.

**How to apply:** synthetic fixture application.
EOF
}

# stage_candidate <path> <source> <sensitivity> <name> <desc> <type> [body]
stage_candidate() {
  local path="$1" src="$2" sens="$3" name="$4" desc="$5" type="$6" body="${7:-**Why:** synthetic capture.

**How to apply:** n/a.}"
  {
    echo "---"
    echo "source: $src"
    echo "sensitivity: $sens"
    echo "proposed:"
    echo "  schema_version: \"1\""
    echo "  name: $name"
    echo "  description: $desc"
    echo "  metadata:"
    echo "    type: $type"
    echo "---"
    printf '%s\n' "$body"
  } > "$path"
}

# expected_key <staged-file> -> the canonical idempotency key an
# independent (non-memory-remember.sh) computation derives, used to prove
# the planner and the writer agree byte-for-byte.
expected_key() {
  mw_call "km_parse_capture '$1' staged >/dev/null 2>&1 && km_capture_canonical_hash"
}

# ===========================================================================
# 1. BASIC CAPTURE via the planner: location, permissions, key ordering
# ===========================================================================
echo "--- basic capture ---"

store=$(bootstrap_store "$TMP/basic")
f1="$TMP/basic_staged1.md"
stage_candidate "$f1" "sess-basic-1" "normal" "ProjectA Deploy Fix" "fixed the deploy timeout" project

out=$(bash "$REMEMBER" --store "$store" --staged "$f1" 2>&1); rc=$?
assert_rc "basic_capture_exit0" 0 "$rc"
key1=$(printf '%s\n' "$out" | grep '^capture_id: ' | sed 's/^capture_id: //')
exp_key1=$(expected_key "$f1")
assert_eq "basic_capture_key_matches_expected" "$exp_key1" "$key1"
assert_contains "basic_capture_created_reported" "$out" "created: "

assert_file_present "basic_capture_lands_in_inbox" "$store/.inbox/${key1}.md"
count_root_md=$(find "$store" -mindepth 1 -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')
[ "$count_root_md" = "1" ] && pass "basic_capture_not_in_store_root" || fail "basic_capture_not_in_store_root" "found $count_root_md root .md files (expected only MEMORY.md)"

dir_mode=$(mw_call "km_path_mode '$store/.inbox'")
assert_eq "basic_capture_inbox_mode_700" "700" "$dir_mode"
file_mode=$(mw_call "km_path_mode '$store/.inbox/${key1}.md'")
assert_eq "basic_capture_file_mode_600" "600" "$file_mode"

# capture_id, created, origin_session, origin_pane (writer-assigned), followed by
# the envelope keys as staged (source, sensitivity, proposed:, ...).
mapfile_lines=()
while IFS= read -r line; do mapfile_lines+=("$line"); done < "$store/.inbox/${key1}.md"
assert_eq "basic_capture_line1_fence" "---" "${mapfile_lines[0]}"
assert_eq "basic_capture_line2_capture_id" "capture_id: ${key1}" "${mapfile_lines[1]}"
case "${mapfile_lines[2]}" in
  "created: "*) pass "basic_capture_line3_created" ;;
  *) fail "basic_capture_line3_created" "got: ${mapfile_lines[2]}" ;;
esac
assert_eq "basic_capture_line4_origin_session" "origin_session: unknown" "${mapfile_lines[3]}"
assert_eq "basic_capture_line5_origin_pane" "origin_pane: test-executor" "${mapfile_lines[4]}"
assert_eq "basic_capture_line6_source" "source: sess-basic-1" "${mapfile_lines[5]}"
assert_eq "basic_capture_line7_sensitivity" "sensitivity: normal" "${mapfile_lines[6]}"
assert_eq "basic_capture_line8_proposed" "proposed:" "${mapfile_lines[7]}"

# ===========================================================================
# 2. IDEMPOTENT DUPLICATE CAPTURE
# ===========================================================================
echo "--- idempotent duplicate ---"

out=$(bash "$REMEMBER" --store "$store" --staged "$f1" 2>&1); rc=$?
assert_rc "dup_capture_exit0" 0 "$rc"
assert_contains "dup_capture_reports_noop" "$out" "no-op"
key_dup=$(printf '%s\n' "$out" | grep '^capture_id: ' | sed 's/^capture_id: //')
assert_eq "dup_capture_same_id" "$key1" "$key_dup"
inbox_count=$(find "$store/.inbox" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')
assert_eq "dup_capture_single_file" "1" "$inbox_count"

# ===========================================================================
# 3. CONTENT VARIANTS -> DISTINCT CAPTURE IDS (planner/writer key agreement)
# ===========================================================================
echo "--- content variants (distinct keys) ---"

f_sens="$TMP/basic_staged_sens.md"
stage_candidate "$f_sens" "sess-basic-1" "sensitive" "ProjectA Deploy Fix" "fixed the deploy timeout" project
out=$(bash "$REMEMBER" --store "$store" --staged "$f_sens" 2>&1); rc=$?
assert_rc "variant_sensitivity_exit0" 0 "$rc"
key_sens=$(printf '%s\n' "$out" | grep '^capture_id: ' | sed 's/^capture_id: //')
[ "$key_sens" != "$key1" ] && pass "variant_sensitivity_new_key" || fail "variant_sensitivity_new_key" "key unchanged: $key_sens"
assert_eq "variant_sensitivity_key_matches_expected" "$(expected_key "$f_sens")" "$key_sens"

f_type="$TMP/basic_staged_type.md"
stage_candidate "$f_type" "sess-basic-1" "normal" "ProjectA Deploy Fix" "fixed the deploy timeout" reference
out=$(bash "$REMEMBER" --store "$store" --staged "$f_type" 2>&1); rc=$?
assert_rc "variant_type_exit0" 0 "$rc"
key_type=$(printf '%s\n' "$out" | grep '^capture_id: ' | sed 's/^capture_id: //')
[ "$key_type" != "$key1" ] && pass "variant_type_new_key" || fail "variant_type_new_key" "key unchanged: $key_type"

f_body="$TMP/basic_staged_body.md"
stage_candidate "$f_body" "sess-basic-1" "normal" "ProjectA Deploy Fix" "fixed the deploy timeout" project "**Why:** a different reason entirely.

**How to apply:** n/a."
out=$(bash "$REMEMBER" --store "$store" --staged "$f_body" 2>&1); rc=$?
assert_rc "variant_body_exit0" 0 "$rc"
key_body=$(printf '%s\n' "$out" | grep '^capture_id: ' | sed 's/^capture_id: //')
[ "$key_body" != "$key1" ] && pass "variant_body_new_key" || fail "variant_body_new_key" "key unchanged: $key_body"

inbox_count=$(find "$store/.inbox" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')
assert_eq "variant_four_distinct_candidates" "4" "$inbox_count"

# ===========================================================================
# 4. WRITER-ASSIGNED FIELDS REJECTED IN STAGED FILE
# ===========================================================================
echo "--- writer-assigned fields rejected ---"

f_capid="$TMP/bad_capture_id.md"
{
  echo "---"
  echo "capture_id: forged"
  echo "source: sess-x"
  echo "sensitivity: normal"
  echo "proposed:"
  echo "  schema_version: \"1\""
  echo "  name: X"
  echo "  description: d"
  echo "  metadata:"
  echo "    type: project"
  echo "---"
  echo "body"
} > "$f_capid"
out=$(bash "$REMEMBER" --store "$store" --staged "$f_capid" 2>&1); rc=$?
assert_rc "staged_capture_id_rejected_exit2" 2 "$rc"

f_created="$TMP/bad_created.md"
{
  echo "---"
  echo "created: 2020-01-01T00:00:00Z"
  echo "source: sess-x"
  echo "sensitivity: normal"
  echo "proposed:"
  echo "  schema_version: \"1\""
  echo "  name: X"
  echo "  description: d"
  echo "  metadata:"
  echo "    type: project"
  echo "---"
  echo "body"
} > "$f_created"
out=$(bash "$REMEMBER" --store "$store" --staged "$f_created" 2>&1); rc=$?
assert_rc "staged_created_rejected_exit2" 2 "$rc"

# ===========================================================================
# 5. ENVELOPE VIOLATIONS (closed lexical subset, caught at plan level)
# ===========================================================================
echo "--- envelope violations ---"

envelope_case() {
  local label="$1" content="$2"
  local f="$TMP/env_${label}.md"
  printf '%s\n' "$content" > "$f"
  local out rc
  out=$(bash "$REMEMBER" --store "$store" --staged "$f" 2>&1); rc=$?
  assert_rc "envelope_${label}_exit2" 2 "$rc"
}

envelope_case "missing_source" '---
sensitivity: normal
proposed:
  schema_version: "1"
  name: X
  description: d
  metadata:
    type: project
---
body'

envelope_case "empty_source" '---
source: ""
sensitivity: normal
proposed:
  schema_version: "1"
  name: X
  description: d
  metadata:
    type: project
---
body'

envelope_case "bad_sensitivity" '---
source: sess-x
sensitivity: maybe
proposed:
  schema_version: "1"
  name: X
  description: d
  metadata:
    type: project
---
body'

envelope_case "unknown_top_field" '---
source: sess-x
sensitivity: normal
extra: nope
proposed:
  schema_version: "1"
  name: X
  description: d
  metadata:
    type: project
---
body'

envelope_case "duplicate_source_key" '---
source: sess-x
source: sess-y
sensitivity: normal
proposed:
  schema_version: "1"
  name: X
  description: d
  metadata:
    type: project
---
body'

envelope_case "yaml_alias" '---
source: &anchor sess-x
sensitivity: normal
proposed:
  schema_version: "1"
  name: X
  description: d
  metadata:
    type: project
---
body'

envelope_case "flow_list" '---
source: sess-x
sensitivity: normal
proposed:
  schema_version: "1"
  name: X
  description: d
  tags: [a, b]
  metadata:
    type: project
---
body'

envelope_case "deep_nesting" '---
source: sess-x
sensitivity: normal
proposed:
  schema_version: "1"
  name: X
  description: d
  metadata:
    type: project
      nested: oops
---
body'

envelope_case "blank_line_in_frontmatter" '---
source: sess-x

sensitivity: normal
proposed:
  schema_version: "1"
  name: X
  description: d
  metadata:
    type: project
---
body'

# ===========================================================================
# 6. WRITER-RECOMPUTATION KEY-MISMATCH (direct writer call — the planner
# never sends a mismatched key by construction, so this exercises the
# writer's own authority check, which memory-remember.sh's delegation
# relies on).
# ===========================================================================
echo "--- key-mismatch (writer recomputation) ---"

f_km="$TMP/keymismatch.md"
stage_candidate "$f_km" "sess-km" "normal" "KeyMismatch Item" "fixture" project
out=$(bash "$WRITER" capture --store "$store" --staged "$f_km" --idempotency-key "1111111111111111111111111111111111111111111111111111111111111111" 2>&1); rc=$?
assert_rc "writer_key_mismatch_exit2" 2 "$rc"
assert_file_absent "writer_key_mismatch_no_candidate_written" "$store/.inbox/1111111111111111111111111111111111111111111111111111111111111111.md"

# ===========================================================================
# 7. EXISTING-CANDIDATE CANONICAL-MISMATCH (tampered candidate) -> exit 4
# ===========================================================================
echo "--- existing-candidate tamper detection ---"

tstore=$(bootstrap_store "$TMP/tamper")
f_t="$TMP/tamper_staged.md"
stage_candidate "$f_t" "sess-tamper" "normal" "Tamper Target" "fixture" project
out=$(bash "$REMEMBER" --store "$tstore" --staged "$f_t" 2>&1)
tkey=$(printf '%s\n' "$out" | grep '^capture_id: ' | sed 's/^capture_id: //')
assert_file_present "tamper_setup_candidate_present" "$tstore/.inbox/${tkey}.md"

sed -i.bak 's/Tamper Target/Tamper Target CHANGED/' "$tstore/.inbox/${tkey}.md"
rm -f "$tstore/.inbox/${tkey}.md.bak"

out=$(bash "$REMEMBER" --store "$tstore" --staged "$f_t" 2>&1); rc=$?
assert_rc "tamper_recapture_exit4" 4 "$rc"
assert_file_present "tamper_candidate_retained" "$tstore/.inbox/${tkey}.md"

# ===========================================================================
# 8. RESERVED-NAME FAIL-CLOSED (.inbox pre-existing as unsafe path)
# ===========================================================================
echo "--- reserved-name fail-closed ---"

rstore_root="$TMP/reserved"
new_repo "$rstore_root"
(cd "$rstore_root" && printf '.agents/memory_file/\n.agents/memory_symlink/\n.agents/memory_mode/\n' >> .gitignore && git add .gitignore && git commit -q -m init)
mkdir -p "$rstore_root/.agents"

rstore_file="$rstore_root/.agents/memory_file"
bash "$WRITER" bootstrap --store "$rstore_file" > /dev/null 2>&1
touch "$rstore_file/.inbox"
f_r="$TMP/reserved_staged.md"
stage_candidate "$f_r" "sess-r" "normal" "Reserved Item" "fixture" project
out=$(bash "$REMEMBER" --store "$rstore_file" --list 2>&1); rc=$?
assert_rc "reserved_inbox_as_file_list_exit4" 4 "$rc"
out=$(bash "$REMEMBER" --store "$rstore_file" --staged "$f_r" 2>&1); rc=$?
assert_rc "reserved_inbox_as_file_staged_exit4" 4 "$rc"

rstore_symlink="$rstore_root/.agents/memory_symlink"
bash "$WRITER" bootstrap --store "$rstore_symlink" > /dev/null 2>&1
ln -s /tmp "$rstore_symlink/.inbox"
out=$(bash "$REMEMBER" --store "$rstore_symlink" --list 2>&1); rc=$?
assert_rc "reserved_inbox_as_symlink_list_exit4" 4 "$rc"
out=$(bash "$REMEMBER" --store "$rstore_symlink" --staged "$f_r" 2>&1); rc=$?
assert_rc "reserved_inbox_as_symlink_staged_exit4" 4 "$rc"

rstore_mode="$rstore_root/.agents/memory_mode"
bash "$WRITER" bootstrap --store "$rstore_mode" > /dev/null 2>&1
mkdir -m 755 "$rstore_mode/.inbox"
out=$(bash "$REMEMBER" --store "$rstore_mode" --list 2>&1); rc=$?
assert_rc "reserved_inbox_wrong_mode_list_exit4" 4 "$rc"
chmod 700 "$rstore_mode/.inbox"

# ===========================================================================
# 9. ROLE SAFETY: reviewer refusal / unresolved fleet identity (--staged
# only; --list is a read surface and must never refuse).
# ===========================================================================
echo "--- role safety ---"

f_role="$TMP/role_staged.md"
stage_candidate "$f_role" "sess-role" "normal" "Role Item" "fixture" project

out=$(KNOWLEDGE_PANE_NAME=fleet-reviewer bash "$REMEMBER" --store "$store" --staged "$f_role" 2>&1); rc=$?
assert_rc "reviewer_refused_staged_exit6" 6 "$rc"
assert_contains "reviewer_refused_message" "$out" "reviewer role: memory writes refused"

out=$(env -u KNOWLEDGE_PANE_NAME -u SESSION_CHAT_PANE_NAME TMUX=/fake/sock,1,1 bash "$REMEMBER" --store "$store" --staged "$f_role" 2>&1); rc=$?
assert_rc "unresolved_fleet_identity_staged_exit6" 6 "$rc"
assert_contains "unresolved_fleet_identity_message" "$out" "unresolved pane identity"

out=$(KNOWLEDGE_PANE_NAME=fleet-reviewer bash "$REMEMBER" --store "$store" --list 2>&1); rc=$?
assert_rc "reviewer_allowed_list_exit0" 0 "$rc"

out=$(env -u KNOWLEDGE_PANE_NAME -u SESSION_CHAT_PANE_NAME TMUX=/fake/sock,1,1 bash "$REMEMBER" --store "$store" --list 2>&1); rc=$?
assert_rc "unresolved_fleet_identity_list_still_allowed_exit0" 0 "$rc"

# ===========================================================================
# 10. EXPIRY COMPUTED READ-ONLY (marks, never deletes; byte-identical proof)
# ===========================================================================
echo "--- expiry computed read-only ---"

estore=$(bootstrap_store "$TMP/expiry")
f_e1="$TMP/expiry1.md"
stage_candidate "$f_e1" "sess-e1" "normal" "Expiry Item One" "fixture" project
out1=$(bash "$REMEMBER" --store "$estore" --staged "$f_e1" 2>&1)
ekey1=$(printf '%s\n' "$out1" | grep '^capture_id: ' | sed 's/^capture_id: //')
created1=$(printf '%s\n' "$out1" | grep '^created: ' | sed 's/^created: //')

before_hash=$(tree_hash "$estore/.inbox")

out_list=$(bash "$REMEMBER" --store "$estore" --list 2>&1); rc=$?
assert_rc "expiry_list_default_retention_exit0" 0 "$rc"
assert_eq "expiry_list_row_byte_exact" "$(printf '%s\t%s\t0\tactive\tnormal' "$ekey1" "$created1")" "$out_list"

out_list_expired0=$(KNOWLEDGE_INBOX_RETENTION_DAYS=0 bash "$REMEMBER" --store "$estore" --list 2>&1)
assert_contains "expiry_retention_zero_marks_expired" "$out_list_expired0" $'\texpired\t'

after_hash=$(tree_hash "$estore/.inbox")
assert_eq "expiry_list_never_mutates_candidate_bytes" "$before_hash" "$after_hash"
assert_file_present "expiry_candidate_never_deleted_by_list" "$estore/.inbox/${ekey1}.md"

# ===========================================================================
# 11. --expired-only FILTER
# ===========================================================================
echo "--- --expired-only filter ---"

f_e2="$TMP/expiry2.md"
stage_candidate "$f_e2" "sess-e2" "normal" "Expiry Item Two" "fixture" project
out2=$(bash "$REMEMBER" --store "$estore" --staged "$f_e2" 2>&1)
ekey2=$(printf '%s\n' "$out2" | grep '^capture_id: ' | sed 's/^capture_id: //')

# Backdate ekey1's stored created so only it is expired under a 5-day retention.
old_created="2020-01-01T00:00:00Z"
sed -i.bak "s/^created: .*/created: ${old_created}/" "$estore/.inbox/${ekey1}.md"
rm -f "$estore/.inbox/${ekey1}.md.bak"

out_expired=$(KNOWLEDGE_INBOX_RETENTION_DAYS=5 bash "$REMEMBER" --store "$estore" --list --expired-only 2>&1); rc=$?
assert_rc "expired_only_exit0" 0 "$rc"
assert_contains "expired_only_includes_backdated" "$out_expired" "$ekey1"
assert_not_contains "expired_only_excludes_fresh" "$out_expired" "$ekey2"
line_count=$(printf '%s\n' "$out_expired" | grep -c . || true)
assert_eq "expired_only_single_row" "1" "$line_count"

out_all=$(KNOWLEDGE_INBOX_RETENTION_DAYS=5 bash "$REMEMBER" --store "$estore" --list 2>&1)
assert_contains "expired_only_all_still_shows_both" "$out_all" "$ekey1"
assert_contains "expired_only_all_still_shows_both_2" "$out_all" "$ekey2"

# ===========================================================================
# 12. USAGE / ARGV EXHAUSTIVENESS
# ===========================================================================
echo "--- usage / argv exhaustiveness ---"

out=$(bash "$REMEMBER" --store "$store" 2>&1); rc=$?
assert_rc "usage_neither_mode_exit2" 2 "$rc"

out=$(bash "$REMEMBER" --store "$store" --staged "$f1" --list 2>&1); rc=$?
assert_rc "usage_both_modes_exit2" 2 "$rc"

out=$(bash "$REMEMBER" --store "$store" --expired-only 2>&1); rc=$?
assert_rc "usage_expired_only_without_list_exit2" 2 "$rc"

out=$(bash "$REMEMBER" --store "$store" --list --bogus 2>&1); rc=$?
assert_rc "usage_unknown_flag_exit2" 2 "$rc"

out=$(bash "$REMEMBER" --staged "$f1" --store 2>&1); rc=$?
assert_rc "usage_store_missing_value_exit2" 2 "$rc"

# ===========================================================================
# 13. STORE-RESOLUTION FAILURES (propagated exit 3)
# ===========================================================================
echo "--- store-resolution failures ---"

zstore_root="$TMP/zero_store"
new_repo "$zstore_root"
out=$(cd "$zstore_root" && bash "$REMEMBER" --list 2>&1); rc=$?
assert_rc "zero_store_list_exit3" 3 "$rc"
assert_contains "zero_store_list_message" "$out" "no memory store found"

out=$(cd "$zstore_root" && bash "$REMEMBER" --staged "$f1" 2>&1); rc=$?
assert_rc "zero_store_staged_exit3" 3 "$rc"

ambig_root="$TMP/ambig_store"
new_repo "$ambig_root"
mkdir -p "$ambig_root/.agents/memory/childA" "$ambig_root/.agents/memory/childB"
touch "$ambig_root/.agents/memory/childA/MEMORY.md" "$ambig_root/.agents/memory/childB/MEMORY.md"
out=$(cd "$ambig_root" && bash "$REMEMBER" --list 2>&1); rc=$?
assert_rc "ambiguous_store_list_exit3" 3 "$rc"
assert_contains "ambiguous_store_message" "$out" "ambiguous memory store"

# ===========================================================================
# 14. PURGE INTEGRATION: the remember -> list -> purge id pipeline
# ===========================================================================
echo "--- purge integration (remember -> list -> purge) ---"

pstore=$(bootstrap_store "$TMP/purge_pipeline")
f_p1="$TMP/purge1.md"; stage_candidate "$f_p1" "sess-p1" "normal" "Purge A" "a" project
f_p2="$TMP/purge2.md"; stage_candidate "$f_p2" "sess-p2" "normal" "Purge B" "b" project
out_p1=$(bash "$REMEMBER" --store "$pstore" --staged "$f_p1" 2>&1)
out_p2=$(bash "$REMEMBER" --store "$pstore" --staged "$f_p2" 2>&1)
pkey1=$(printf '%s\n' "$out_p1" | grep '^capture_id: ' | sed 's/^capture_id: //')
pkey2=$(printf '%s\n' "$out_p2" | grep '^capture_id: ' | sed 's/^capture_id: //')

out_list=$(bash "$REMEMBER" --store "$pstore" --list 2>&1)
assert_contains "purge_pipeline_list_shows_both_a" "$out_list" "$pkey1"
assert_contains "purge_pipeline_list_shows_both_b" "$out_list" "$pkey2"

# PLAN under a zero-day retention so both are expired.
KNOWLEDGE_INBOX_RETENTION_DAYS=0 bash "$WRITER" purge --store "$pstore" --expired > "$TMP/purge_plan.txt" 2>"$TMP/purge_plan.err"
plan_rc=$?
assert_rc "purge_plan_exit0" 0 "$plan_rc"
plan_lines=$(wc -l < "$TMP/purge_plan.txt" | tr -d ' ')
assert_eq "purge_plan_lists_both" "2" "$plan_lines"
assert_file_present "purge_plan_deletes_nothing_a" "$pstore/.inbox/${pkey1}.md"
assert_file_present "purge_plan_deletes_nothing_b" "$pstore/.inbox/${pkey2}.md"

# Confirmation-token mismatch: --confirm must byte-equal --store.
out=$(KNOWLEDGE_INBOX_RETENTION_DAYS=0 bash "$WRITER" purge --store "$pstore" --expired --manifest "$TMP/purge_plan.txt" --confirm "${pstore}/" 2>&1); rc=$?
assert_rc "purge_confirm_mismatch_exit2" 2 "$rc"
assert_file_present "purge_confirm_mismatch_deletes_nothing" "$pstore/.inbox/${pkey1}.md"

# APPLY with the correct confirmation token.
out=$(KNOWLEDGE_INBOX_RETENTION_DAYS=0 bash "$WRITER" purge --store "$pstore" --expired --manifest "$TMP/purge_plan.txt" --confirm "$pstore" 2>&1); rc=$?
assert_rc "purge_apply_exit0" 0 "$rc"
assert_contains "purge_apply_reports_a" "$out" "purged: ${pkey1}"
assert_contains "purge_apply_reports_b" "$out" "purged: ${pkey2}"
assert_file_absent "purge_apply_removed_a" "$pstore/.inbox/${pkey1}.md"
assert_file_absent "purge_apply_removed_b" "$pstore/.inbox/${pkey2}.md"

out_list_after=$(bash "$REMEMBER" --store "$pstore" --list 2>&1); rc=$?
assert_rc "purge_pipeline_list_empty_after_exit0" 0 "$rc"
assert_eq "purge_pipeline_list_empty_after" "" "$out_list_after"

# --ids selector: the id column from --list feeds --ids directly.
f_p3="$TMP/purge3.md"; stage_candidate "$f_p3" "sess-p3" "normal" "Purge C" "c" project
out_p3=$(bash "$REMEMBER" --store "$pstore" --staged "$f_p3" 2>&1)
pkey3=$(printf '%s\n' "$out_p3" | grep '^capture_id: ' | sed 's/^capture_id: //')
bash "$WRITER" purge --store "$pstore" --ids "$pkey3" > "$TMP/purge_plan_ids.txt" 2>/dev/null
out=$(bash "$WRITER" purge --store "$pstore" --ids "$pkey3" --manifest "$TMP/purge_plan_ids.txt" --confirm "$pstore" 2>&1); rc=$?
assert_rc "purge_by_ids_exit0" 0 "$rc"
assert_file_absent "purge_by_ids_removed" "$pstore/.inbox/${pkey3}.md"

# ===========================================================================
# 15. SCANNER BOUNDARY: candidates never appear in lint/index output
# ===========================================================================
echo "--- scanner boundary ---"

sbstore=$(bootstrap_store "$TMP/scanner_boundary")
write_canonical "$sbstore/authoritative_item.md" project "Authoritative Item" "a real memory file"
cat >> "$sbstore/MEMORY.md" <<'EOF'
- [Authoritative Item](authoritative_item.md) — a real memory file
EOF

lint_before=$(bash "$LINT" --store "$sbstore" 2>&1); lint_before_rc=$?
index_before=$(bash "$INDEXTOOL" --store "$sbstore" 2>&1); index_before_rc=$?
auth_hash_before=$(find "$sbstore" -mindepth 1 -maxdepth 1 -name '*.md' -exec shasum -a 256 {} \; | LC_ALL=C sort | shasum -a 256 | awk '{print $1}')

f_sb="$TMP/scanner_boundary_staged.md"
stage_candidate "$f_sb" "sess-sb" "normal" "Scanner Boundary Item" "should never be indexed" project
out=$(bash "$REMEMBER" --store "$sbstore" --staged "$f_sb" 2>&1)
sbkey=$(printf '%s\n' "$out" | grep '^capture_id: ' | sed 's/^capture_id: //')
assert_file_present "scanner_boundary_candidate_captured" "$sbstore/.inbox/${sbkey}.md"

lint_after=$(bash "$LINT" --store "$sbstore" 2>&1); lint_after_rc=$?
index_after=$(bash "$INDEXTOOL" --store "$sbstore" 2>&1); index_after_rc=$?

assert_eq "scanner_boundary_lint_output_unchanged" "$lint_before" "$lint_after"
assert_eq "scanner_boundary_lint_rc_unchanged" "$lint_before_rc" "$lint_after_rc"
assert_eq "scanner_boundary_index_output_unchanged" "$index_before" "$index_after"
assert_eq "scanner_boundary_index_rc_unchanged" "$index_before_rc" "$index_after_rc"
assert_not_contains "scanner_boundary_lint_never_mentions_candidate" "$lint_after" "$sbkey"
assert_not_contains "scanner_boundary_index_never_mentions_candidate" "$index_after" "$sbkey"

# Authoritative-file tree (excluding .inbox) is byte-identical: lint/index
# are read-only, and capture never touches anything outside .inbox.
auth_hash_after=$(find "$sbstore" -mindepth 1 -maxdepth 1 -name '*.md' -exec shasum -a 256 {} \; | LC_ALL=C sort | shasum -a 256 | awk '{print $1}')
assert_eq "scanner_boundary_authoritative_files_untouched" "$auth_hash_before" "$auth_hash_after"

if [ -x "$HERE/memory-search.sh" ]; then
  search_out=$(bash "$HERE/memory-search.sh" --store "$sbstore" "Scanner Boundary" 2>&1)
  assert_not_contains "scanner_boundary_search_excludes_candidate" "$search_out" "$sbkey"
else
  echo "  SKIP  scanner_boundary_search -- memory-search.sh does not exist yet (Phase B2 concurrent, not landed)"
fi
if [ -x "$HERE/memory-backlinks.sh" ]; then
  bl_out=$(bash "$HERE/memory-backlinks.sh" --store "$sbstore" orphans 2>&1)
  assert_not_contains "scanner_boundary_backlinks_excludes_candidate" "$bl_out" "$sbkey"
else
  echo "  SKIP  scanner_boundary_backlinks -- memory-backlinks.sh does not exist yet (Phase B2 concurrent, not landed)"
fi

# ===========================================================================
# 15b. EVIDENCE + ORIGIN PROVENANCE + PENDING CAPS (knowledge 0.5.0)
# ===========================================================================
echo "--- evidence / origin / caps ---"

# stage_ev <path> <source> <name> <evidence-line-or-empty>
# Staged candidate with a UNIQUE name/description (the wrapper de-duplicates
# on those) and an optional raw `evidence:` line (passed verbatim).
stage_ev() {
  local path="$1" src="$2" name="$3" ev="${4:-}"
  {
    echo "---"
    echo "source: $src"
    echo "sensitivity: normal"
    [ -z "$ev" ] || echo "$ev"
    echo "proposed:"
    echo "  schema_version: \"1\""
    echo "  name: $name"
    echo "  description: unique description for $name"
    echo "  metadata:"
    echo "    type: project"
    echo "---"
    printf '%s\n' "**Why:** synthetic $name."
  } > "$path"
}
pending_count() { find "$1/.inbox" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' '; }

unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID SESSION_CHAT_PANE_NAME KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT

# --- evidence required for auto_capture; positive control with evidence ---
evs=$(bootstrap_store "$TMP/ev_store")
f="$TMP/ev_none.md"; stage_ev "$f" auto_capture "Ev None" ""
out=$(CLAUDE_CODE_SESSION_ID=sessA bash "$REMEMBER" --store "$evs" --staged "$f" 2>&1); rc=$?
assert_rc "evidence_auto_capture_without_evidence_rejected_rc7" 7 "$rc"
assert_eq "evidence_auto_capture_without_evidence_writes_nothing" "0" "$(pending_count "$evs")"
f="$TMP/ev_ok.md"; stage_ev "$f" auto_capture "Ev Ok" "evidence: src/app.sh:42"
out=$(CLAUDE_CODE_SESSION_ID=sessA bash "$REMEMBER" --store "$evs" --staged "$f" 2>&1); rc=$?
assert_rc "evidence_auto_capture_with_evidence_accepted" 0 "$rc"
assert_eq "evidence_auto_capture_with_evidence_written" "1" "$(pending_count "$evs")"
f="$TMP/ev_manual.md"; stage_ev "$f" sess-manual "Ev Manual" ""
out=$(CLAUDE_CODE_SESSION_ID=sessA bash "$REMEMBER" --store "$evs" --staged "$f" 2>&1); rc=$?
assert_rc "evidence_manual_capture_without_evidence_still_accepted" 0 "$rc"

# --- evidence grammar: too long / multiline / empty / duplicate (+control) ---
long=$(printf 'x%.0s' $(seq 1 301)); ok300=$(printf 'x%.0s' $(seq 1 300))
f="$TMP/ev_long.md"; stage_ev "$f" sess-g "Ev Long" "evidence: $long"
bash "$REMEMBER" --store "$evs" --staged "$f" >/dev/null 2>&1; assert_rc "evidence_301_bytes_rejected" 2 $?
f="$TMP/ev_300.md"; stage_ev "$f" sess-g "Ev Three Hundred" "evidence: $ok300"
bash "$REMEMBER" --store "$evs" --staged "$f" >/dev/null 2>&1; assert_rc "evidence_300_bytes_accepted_control" 0 $?
f="$TMP/ev_multi.md"; stage_ev "$f" sess-g "Ev Multi" $'evidence: first line\n  continued line'
bash "$REMEMBER" --store "$evs" --staged "$f" >/dev/null 2>&1; assert_rc "evidence_multiline_rejected" 2 $?
f="$TMP/ev_empty.md"; stage_ev "$f" sess-g "Ev Empty" "evidence:"
bash "$REMEMBER" --store "$evs" --staged "$f" >/dev/null 2>&1; assert_rc "evidence_empty_rejected" 2 $?
f="$TMP/ev_dup.md"; stage_ev "$f" sess-g "Ev Dup" $'evidence: one\nevidence: two'
bash "$REMEMBER" --store "$evs" --staged "$f" >/dev/null 2>&1; assert_rc "evidence_duplicate_rejected" 2 $?
f="$TMP/ev_quoted.md"; stage_ev "$f" sess-g "Ev Quoted" 'evidence: "user said: keep it"'
bash "$REMEMBER" --store "$evs" --staged "$f" >/dev/null 2>&1; assert_rc "evidence_quoted_scalar_accepted_control" 0 $?

# --- staged origin_* rejected; control: same file without them accepted ---
f="$TMP/ev_osess.md"; stage_ev "$f" sess-g "Ev Osess" "origin_session: forged"
bash "$REMEMBER" --store "$evs" --staged "$f" >/dev/null 2>&1; assert_rc "staged_origin_session_rejected" 2 $?
f="$TMP/ev_opane.md"; stage_ev "$f" sess-g "Ev Opane" "origin_pane: forged"
bash "$REMEMBER" --store "$evs" --staged "$f" >/dev/null 2>&1; assert_rc "staged_origin_pane_rejected" 2 $?
f="$TMP/ev_noorigin.md"; stage_ev "$f" sess-g "Ev No Origin" ""
bash "$REMEMBER" --store "$evs" --staged "$f" >/dev/null 2>&1; assert_rc "staged_without_origin_accepted_control" 0 $?

# --- legacy stored candidate (no evidence/origin): parses, hash verifies ---
# Fixture hash was computed by the pre-0.5.0 (HEAD) writer; it must not change.
LEGACY_ID=599fd577c258e208939f3a5d828b5d06d28fb9c2d9f3149f710596dba78aed9c
lgs=$(bootstrap_store "$TMP/legacy_store")
mkdir -p "$lgs/.inbox"; chmod 700 "$lgs/.inbox"
{
  echo "---"; echo "capture_id: $LEGACY_ID"; echo "created: 2026-01-01T00:00:00Z"
  echo "source: sess-legacy-fixture"; echo "sensitivity: normal"; echo "proposed:"
  echo '  schema_version: "1"'; echo "  name: Legacy Fixture Item"
  echo "  description: pre-0.5.0 candidate without evidence"
  echo "  metadata:"; echo "    type: project"; echo "---"
  printf '%s\n' "**Why:** synthetic legacy fixture."; echo; printf '%s\n' "**How to apply:** n/a."
} > "$lgs/.inbox/$LEGACY_ID.md"
chmod 600 "$lgs/.inbox/$LEGACY_ID.md"
got=$(mw_call "km_parse_capture '$lgs/.inbox/$LEGACY_ID.md' stored && km_capture_canonical_hash")
assert_eq "legacy_stored_candidate_hash_unchanged" "$LEGACY_ID" "$got"
got=$(mw_call "km_parse_capture '$lgs/.inbox/$LEGACY_ID.md' stored && printf '[%s][%s]' \"\$KM_CAP_ORIGIN_SESSION\" \"\$KM_CAP_ORIGIN_PANE\"")
assert_eq "legacy_stored_candidate_has_no_origin" "[][]" "$got"
write_legacy_staged() {
  cat > "$1" <<'LEG'
---
source: sess-legacy-fixture
sensitivity: normal
LEG
  [ -z "${2:-}" ] || echo "$2" >> "$1"
  cat >> "$1" <<'LEG'
proposed:
  schema_version: "1"
  name: Legacy Fixture Item
  description: pre-0.5.0 candidate without evidence
  metadata:
    type: project
---
**Why:** synthetic legacy fixture.

**How to apply:** n/a.
LEG
}
f="$TMP/legacy_staged.md"; write_legacy_staged "$f" ""
assert_eq "legacy_staged_recapture_same_id" "$LEGACY_ID" "$(expected_key "$f")"
# control: evidence DOES change the id
f2="$TMP/legacy_staged_ev.md"; write_legacy_staged "$f2" "evidence: x"
[ "$(expected_key "$f2")" != "$LEGACY_ID" ] && pass "evidence_changes_capture_id_control" || fail "evidence_changes_capture_id_control" "hash identical with evidence"
# origin lines are not hashed: adding them to a stored file leaves the hash unchanged
sed -i.bak 's/^created: .*/&\norigin_session: sessZ\norigin_pane: paneZ/' "$lgs/.inbox/$LEGACY_ID.md"; rm -f "$lgs/.inbox/$LEGACY_ID.md.bak"
got=$(mw_call "km_parse_capture '$lgs/.inbox/$LEGACY_ID.md' stored && km_capture_canonical_hash")
assert_eq "stored_origin_lines_excluded_from_hash" "$LEGACY_ID" "$got"
# stored duplicate origin rejected (control above: single origin parses)
sed -i.bak 's/^origin_pane: .*/&\norigin_pane: dup/' "$lgs/.inbox/$LEGACY_ID.md"; rm -f "$lgs/.inbox/$LEGACY_ID.md.bak"
mw_call "km_parse_capture '$lgs/.inbox/$LEGACY_ID.md' stored" >/dev/null 2>&1; assert_rc "stored_duplicate_origin_pane_rejected" 2 $?

# --- origin lines written from env for ALL new captures ---
ors=$(bootstrap_store "$TMP/origin_store")
f="$TMP/or1.md"; stage_ev "$f" sess-manual "Or One" ""
out=$(CLAUDE_CODE_SESSION_ID=sessA KNOWLEDGE_PANE_NAME=paneA bash "$REMEMBER" --store "$ors" --staged "$f" 2>&1)
k=$(printf '%s\n' "$out" | sed -n 's/^capture_id: //p')
assert_eq "origin_lines_after_created" "origin_session: sessA|origin_pane: paneA" "$(sed -n '4p;5p' "$ors/.inbox/$k.md" | paste -sd'|' -)"
f="$TMP/or2.md"; stage_ev "$f" sess-manual "Or Two" ""
out=$(env -u CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID=thr-9 KNOWLEDGE_PANE_NAME=paneB bash "$REMEMBER" --store "$ors" --staged "$f" 2>&1)
k=$(printf '%s\n' "$out" | sed -n 's/^capture_id: //p')
assert_eq "origin_codex_thread_fallback" "origin_session: thr-9" "$(sed -n '4p' "$ors/.inbox/$k.md")"
f="$TMP/or3.md"; stage_ev "$f" sess-manual "Or Three" ""
out=$(CLAUDE_CODE_SESSION_ID='bad value;rm' env -u KNOWLEDGE_PANE_NAME SESSION_CHAT_PANE_NAME=chatpane bash "$REMEMBER" --store "$ors" --staged "$f" 2>&1)
k=$(printf '%s\n' "$out" | sed -n 's/^capture_id: //p')
assert_eq "origin_invalid_session_unknown_and_chat_pane_fallback" "origin_session: unknown|origin_pane: chatpane" "$(sed -n '4p;5p' "$ors/.inbox/$k.md" | paste -sd'|' -)"

# --- identical content from two sessions: same id, second is a no-op even at the cap ---
dps=$(bootstrap_store "$TMP/dup_store")
f="$TMP/dup.md"; stage_ev "$f" auto_capture "Dup Item" "evidence: a.sh:1"
o1=$(CLAUDE_CODE_SESSION_ID=sessA KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT=1 bash "$REMEMBER" --store "$dps" --staged "$f" 2>&1); r1=$?
CLAUDE_CODE_SESSION_ID=sessA KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT=1 bash "$REMEMBER" --store "$dps" --staged "$f" >/dev/null 2>&1; r2=$?
o3=$(CLAUDE_CODE_SESSION_ID=sessB KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT=0 KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING=0 bash "$REMEMBER" --store "$dps" --staged "$f" 2>&1); r3=$?
assert_rc "dup_first_capture_ok" 0 "$r1"
assert_rc "dup_recapture_same_session_at_cap_noop_not_refused" 0 "$r2"
assert_rc "dup_recapture_other_session_with_zero_caps_noop" 0 "$r3"
assert_contains "dup_other_session_reports_noop" "$o3" "no-op"
assert_eq "dup_same_capture_id" "$(printf '%s\n' "$o1" | sed -n 's/^capture_id: //p')" "$(printf '%s\n' "$o3" | sed -n 's/^capture_id: //p')"
assert_eq "dup_single_candidate_stored" "1" "$(pending_count "$dps")"
dk=$(printf '%s\n' "$o1" | sed -n 's/^capture_id: //p')
assert_eq "dup_origin_stays_first_session" "origin_session: sessA" "$(sed -n '4p' "$dps/.inbox/$dk.md")"

# --- per-session pending cap (writer, direct) ---
sls=$(bootstrap_store "$TMP/sess_cap_store")
for n in 1 2; do
  f="$TMP/sc_a$n.md"; stage_ev "$f" auto_capture "Sc A$n" "evidence: a.sh:$n"
  CLAUDE_CODE_SESSION_ID=sessA KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT=2 bash "$REMEMBER" --store "$sls" --staged "$f" >/dev/null 2>&1; assert_rc "session_cap_a${n}_accepted" 0 $?
done
f="$TMP/sc_a3.md"; stage_ev "$f" auto_capture "Sc A3" "evidence: a.sh:3"
CLAUDE_CODE_SESSION_ID=sessA KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT=2 bash "$REMEMBER" --store "$sls" --staged "$f" >/dev/null 2>&1; assert_rc "session_cap_third_from_session_a_refused_rc7" 7 $?
f="$TMP/sc_b1.md"; stage_ev "$f" auto_capture "Sc B1" "evidence: b.sh:1"
CLAUDE_CODE_SESSION_ID=sessB KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT=2 bash "$REMEMBER" --store "$sls" --staged "$f" >/dev/null 2>&1; assert_rc "session_cap_session_b_accepted_control" 0 $?
f="$TMP/sc_a4.md"; stage_ev "$f" sess-manual "Sc Manual A" ""
CLAUDE_CODE_SESSION_ID=sessA KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT=2 bash "$REMEMBER" --store "$sls" --staged "$f" >/dev/null 2>&1; assert_rc "session_cap_does_not_cap_manual_captures" 0 $?
assert_eq "session_cap_inbox_count" "4" "$(pending_count "$sls")"
f="$TMP/sc_nonnum.md"; stage_ev "$f" auto_capture "Sc Nonnum" "evidence: n.sh:1"
CLAUDE_CODE_SESSION_ID=sessC KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT=abc bash "$REMEMBER" --store "$sls" --staged "$f" >/dev/null 2>&1; assert_rc "session_cap_non_numeric_falls_back_to_default" 0 $?
# direct writer call (no planner) enforces the same cap
f="$TMP/sc_direct.md"; stage_ev "$f" auto_capture "Sc Direct" "evidence: d.sh:1"
dkey=$(expected_key "$f")
CLAUDE_CODE_SESSION_ID=sessA KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT=2 bash "$WRITER" capture --store "$sls" --staged "$f" --idempotency-key "$dkey" >/dev/null 2>&1; assert_rc "session_cap_enforced_by_direct_writer_call" 7 $?
assert_file_absent "session_cap_refused_candidate_not_written" "$sls/.inbox/$dkey.md"

# --- unknown-session bucket is one shared cap ---
uks=$(bootstrap_store "$TMP/unknown_store")
for n in 1 2; do
  f="$TMP/uk$n.md"; stage_ev "$f" auto_capture "Uk $n" "evidence: u.sh:$n"
  env -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT=2 bash "$REMEMBER" --store "$uks" --staged "$f" >/dev/null 2>&1; assert_rc "unknown_bucket_capture_${n}_accepted" 0 $?
done
f="$TMP/uk3.md"; stage_ev "$f" auto_capture "Uk 3" "evidence: u.sh:3"
env -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT=2 bash "$REMEMBER" --store "$uks" --staged "$f" >/dev/null 2>&1; assert_rc "unknown_bucket_shared_cap_refused_rc7" 7 $?
CLAUDE_CODE_SESSION_ID=sessK KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT=2 bash "$REMEMBER" --store "$uks" --staged "$f" >/dev/null 2>&1; assert_rc "unknown_bucket_does_not_cap_named_session_control" 0 $?

# --- MAX_PENDING enforced by the writer when invoked directly ---
mps=$(bootstrap_store "$TMP/maxpend_store")
for n in 1 2; do
  f="$TMP/mp$n.md"; stage_ev "$f" auto_capture "Mp $n" "evidence: m.sh:$n"
  CLAUDE_CODE_SESSION_ID="s$n" KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING=2 bash "$REMEMBER" --store "$mps" --staged "$f" >/dev/null 2>&1; assert_rc "max_pending_capture_${n}_accepted" 0 $?
done
f="$TMP/mp3.md"; stage_ev "$f" auto_capture "Mp 3" "evidence: m.sh:3"
mkey=$(expected_key "$f")
CLAUDE_CODE_SESSION_ID=s3 KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING=2 bash "$WRITER" capture --store "$mps" --staged "$f" --idempotency-key "$mkey" >/dev/null 2>&1; assert_rc "max_pending_enforced_by_direct_writer_rc7" 7 $?
assert_file_absent "max_pending_refused_not_written" "$mps/.inbox/$mkey.md"
CLAUDE_CODE_SESSION_ID=s3 KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING=3 bash "$WRITER" capture --store "$mps" --staged "$f" --idempotency-key "$mkey" >/dev/null 2>&1; assert_rc "max_pending_raised_limit_accepts_control" 0 $?

# --- wrapper: evidence fast path, session fast path, rc7 mapping, purge rejection ---
AUTOCAP="$HERE/memory-auto-capture.sh"
was=$(bootstrap_store "$TMP/wrap_store")
f="$TMP/w_noev.md"; stage_ev "$f" auto_capture "W Noev" ""
out=$(CLAUDE_CODE_SESSION_ID=sessA bash "$AUTOCAP" --store "$was" --staged "$f" 2>&1); rc=$?
assert_rc "wrapper_missing_evidence_rejects_candidate_exit0" 0 "$rc"
assert_contains "wrapper_missing_evidence_message" "$out" "without an evidence"
assert_eq "wrapper_missing_evidence_writes_nothing" "0" "$(pending_count "$was")"
f="$TMP/w_ev.md"; stage_ev "$f" auto_capture "W Ev" "evidence: w.sh:1"
out=$(CLAUDE_CODE_SESSION_ID=sessA bash "$AUTOCAP" --store "$was" --staged "$f" 2>&1)
assert_contains "wrapper_with_evidence_captures_control" "$out" "captured: "
for n in 2 3; do f="$TMP/w_ev$n.md"; stage_ev "$f" auto_capture "W Ev$n" "evidence: w.sh:$n"; done
out=$(CLAUDE_CODE_SESSION_ID=sessA KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT=1 bash "$AUTOCAP" --store "$was" --staged "$TMP/w_ev2.md" 2>&1)
assert_contains "wrapper_session_limit_fast_path_rejects" "$out" "SESSION_LIMIT=1"
out=$(CLAUDE_CODE_SESSION_ID=sessB KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT=1 bash "$AUTOCAP" --store "$was" --staged "$TMP/w_ev3.md" 2>&1)
assert_contains "wrapper_session_limit_other_session_captures_control" "$out" "captured: "
# writer rc 7 -> per-candidate rejection: run the wrapper from a copy whose
# memory-remember.sh is a stub (rc 7 = policy refusal; rc 1 = control).
STUB="$TMP/stub_scripts"; rm -rf "$STUB"; cp -R "$HERE" "$STUB"
printf '#!/usr/bin/env bash\nexit 7\n' > "$STUB/memory-remember.sh"
out=$(CLAUDE_CODE_SESSION_ID=sessE bash "$STUB/memory-auto-capture.sh" --store "$was" --staged "$TMP/w_ev2.md" 2>&1); rc=$?
assert_rc "wrapper_maps_writer_rc7_to_candidate_rejection_exit0" 0 "$rc"
assert_contains "wrapper_rc7_message" "$out" "capture policy"
assert_contains "wrapper_rc7_counts_rejected" "$out" "1 rejected"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/memory-remember.sh"
out=$(CLAUDE_CODE_SESSION_ID=sessE bash "$STUB/memory-auto-capture.sh" --store "$was" --staged "$TMP/w_ev2.md" 2>&1)
assert_not_contains "wrapper_generic_failure_is_not_policy_message_control" "$out" "capture policy"
for flag in --purge --confirm; do
  bash "$AUTOCAP" --store "$was" --staged "$TMP/w_ev2.md" "$flag" x >/dev/null 2>&1; assert_rc "wrapper_rejects_${flag#--}_flag" 2 $?
done
bash "$AUTOCAP" --store "$was" --staged "$TMP/w_ev2.md" --nonsense >/dev/null 2>&1; assert_rc "wrapper_unknown_flag_rejected_control" 2 $?
out=$(CLAUDE_CODE_SESSION_ID=sessD bash "$AUTOCAP" --store "$was" --staged "$TMP/w_ev2.md" 2>&1); rc=$?
assert_rc "wrapper_plain_invocation_ok_control" 0 "$rc"

# --- bounded numeric tunables (no octal parse, no overflow, fail to default) ---
for case_ in "0005:9:5" "0008:9:8" "0:9:0" "999999:9:999999" "99999999999999999999:9:9" "1234567:9:9" ":9:9" "-1:9:9" "abc:9:9" "0x10:9:9" "007:9:7"; do
  v="${case_%%:*}"; rest="${case_#*:}"; d="${rest%%:*}"; want="${rest#*:}"
  got=$(mw_call "km_bounded_int '$v' $d")
  assert_eq "bounded_int_[$v]" "$want" "$got"
done
# writer: zero-padded limit is honoured (control: plain 2), huge limit falls back to the default 5 (fail closed)
bis=$(bootstrap_store "$TMP/bounded_store")
for n in 1 2; do
  f="$TMP/bi$n.md"; stage_ev "$f" auto_capture "Bi $n" "evidence: b.sh:$n"
  CLAUDE_CODE_SESSION_ID=sessP KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT=0002 bash "$REMEMBER" --store "$bis" --staged "$f" >/dev/null 2>&1; assert_rc "bounded_zero_padded_limit_accepts_$n" 0 $?
done
f="$TMP/bi3.md"; stage_ev "$f" auto_capture "Bi 3" "evidence: b.sh:3"
CLAUDE_CODE_SESSION_ID=sessP KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT=0002 bash "$REMEMBER" --store "$bis" --staged "$f" >/dev/null 2>&1; assert_rc "bounded_zero_padded_limit_enforced_rc7" 7 $?
CLAUDE_CODE_SESSION_ID=sessP KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT=0003 bash "$REMEMBER" --store "$bis" --staged "$f" >/dev/null 2>&1; assert_rc "bounded_zero_padded_larger_limit_accepts_control" 0 $?
for n in 4 5; do
  f="$TMP/bi$n.md"; stage_ev "$f" auto_capture "Bi $n" "evidence: b.sh:$n"
  CLAUDE_CODE_SESSION_ID=sessQ bash "$REMEMBER" --store "$bis" --staged "$f" >/dev/null 2>&1
done
f="$TMP/bi6.md"; stage_ev "$f" auto_capture "Bi 6" "evidence: b.sh:6"
CLAUDE_CODE_SESSION_ID=sessQ KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT=99999999999999999999 bash "$REMEMBER" --store "$bis" --staged "$f" >/dev/null 2>&1; assert_rc "bounded_huge_limit_below_default_cap_accepts" 0 $?
for n in 7 8 9 10; do
  f="$TMP/bi$n.md"; stage_ev "$f" auto_capture "Bi $n" "evidence: b.sh:$n"
  CLAUDE_CODE_SESSION_ID=sessQ bash "$REMEMBER" --store "$bis" --staged "$f" >/dev/null 2>&1
done
f="$TMP/bi11.md"; stage_ev "$f" auto_capture "Bi 11" "evidence: b.sh:11"
CLAUDE_CODE_SESSION_ID=sessQ KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT=99999999999999999999 bash "$REMEMBER" --store "$bis" --staged "$f" >/dev/null 2>&1; assert_rc "bounded_huge_limit_falls_back_to_default_cap_rc7" 7 $?
CLAUDE_CODE_SESSION_ID=sessQ KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT=9 bash "$REMEMBER" --store "$bis" --staged "$f" >/dev/null 2>&1; assert_rc "bounded_explicit_larger_limit_accepts_control" 0 $?
# huge MAX_PENDING also falls back to its default (20): 20 pending then refused
f="$TMP/bi_mp.md"; stage_ev "$f" auto_capture "Bi Mp" "evidence: b.sh:mp"
for n in $(seq 1 20); do ff="$TMP/bimp$n.md"; stage_ev "$ff" sess-manual "Bimp $n" ""; CLAUDE_CODE_SESSION_ID=sessR bash "$REMEMBER" --store "$bis" --staged "$ff" >/dev/null 2>&1; done
CLAUDE_CODE_SESSION_ID=sessR KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING=99999999999999999999 bash "$REMEMBER" --store "$bis" --staged "$f" >/dev/null 2>&1; assert_rc "bounded_huge_max_pending_falls_back_to_default_rc7" 7 $?
CLAUDE_CODE_SESSION_ID=sessR KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING=0100 bash "$REMEMBER" --store "$bis" --staged "$f" >/dev/null 2>&1; assert_rc "bounded_zero_padded_max_pending_accepts_control" 0 $?

# --- wrapper: LIMIT bounded; no-op reporting; source forgery ---
wl=$(bootstrap_store "$TMP/wrap_limit_store")
mkdir -p "$TMP/wl_batch"; rm -f "$TMP/wl_batch"/*.md
for n in 1 2 3 4; do stage_ev "$TMP/wl_batch/$n.md" auto_capture "Wl $n" "evidence: wl.sh:$n"; done
args=(); for n in 1 2 3 4; do args+=(--staged "$TMP/wl_batch/$n.md"); done
out=$(CLAUDE_CODE_SESSION_ID=sessW KNOWLEDGE_AUTO_CAPTURE_LIMIT=99999999999999999999 bash "$AUTOCAP" --store "$wl" "${args[@]}" 2>/dev/null)
assert_eq "wrapper_huge_limit_falls_back_to_default_3" "3" "$(printf '%s\n' "$out" | grep -c '^captured: ')"
wl2=$(bootstrap_store "$TMP/wrap_limit_store2")
out=$(CLAUDE_CODE_SESSION_ID=sessW KNOWLEDGE_AUTO_CAPTURE_LIMIT=0004 bash "$AUTOCAP" --store "$wl2" "${args[@]}" 2>/dev/null)
assert_eq "wrapper_zero_padded_limit_4_captures_4_control" "4" "$(printf '%s\n' "$out" | grep -c '^captured: ')"

nos=$(bootstrap_store "$TMP/wrap_noop_store")
f="$TMP/noop.md"; stage_ev "$f" auto_capture "Noop Item" "evidence: noop.sh:1"
out=$(CLAUDE_CODE_SESSION_ID=sessN bash "$AUTOCAP" --store "$nos" --staged "$f" 2>/dev/null)
assert_contains "wrapper_new_candidate_prints_captured_control" "$out" "captured: "
nid=$(printf '%s\n' "$out" | sed -n 's/^captured: //p')
out=$(CLAUDE_CODE_SESSION_ID=sessN bash "$AUTOCAP" --store "$nos" --staged "$f" 2>/dev/null)
assert_contains "wrapper_unchanged_existing_prints_skipped" "$out" "skipped: $nid (no-op"
assert_not_contains "wrapper_unchanged_existing_not_captured" "$out" "captured:"
assert_eq "wrapper_unchanged_existing_still_one_pending" "1" "$(pending_count "$nos")"
dh=$(shasum -a 256 "$nos/.inbox/$nid.md" | awk '{print $1}')
bash "$WRITER" dismiss --store "$nos" --candidate "$nid" --expect-candidate "$dh" >/dev/null 2>&1; assert_rc "wrapper_noop_fixture_dismiss_ok" 0 $?
out=$(CLAUDE_CODE_SESSION_ID=sessN bash "$AUTOCAP" --store "$nos" --staged "$f" 2>/dev/null)
assert_contains "wrapper_dismissed_prints_skipped" "$out" "skipped: $nid (no-op (dismissed))"
assert_not_contains "wrapper_dismissed_not_captured" "$out" "captured:"
assert_eq "wrapper_dismissed_not_requeued" "0" "$(pending_count "$nos")"
# a no-op at the session cap is still a no-op (not cap-refused)
out=$(CLAUDE_CODE_SESSION_ID=sessN KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT=0 bash "$AUTOCAP" --store "$nos" --staged "$f" 2>&1)
assert_contains "wrapper_dismissed_noop_even_at_zero_session_limit" "$out" "skipped: $nid"

fs=$(bootstrap_store "$TMP/wrap_forge_store")
f="$TMP/forged.md"; stage_ev "$f" sess-manual "Forged Source" "evidence: forged.sh:1"
out=$(CLAUDE_CODE_SESSION_ID=sessF bash "$AUTOCAP" --store "$fs" --staged "$f" 2>&1); rc=$?
assert_rc "wrapper_forged_manual_source_exit0" 0 "$rc"
assert_contains "wrapper_forged_source_rejected_message" "$out" "source is not auto_capture"
assert_eq "wrapper_forged_source_writes_nothing" "0" "$(pending_count "$fs")"
f="$TMP/genuine.md"; stage_ev "$f" auto_capture "Genuine Source" "evidence: genuine.sh:1"
out=$(CLAUDE_CODE_SESSION_ID=sessF bash "$AUTOCAP" --store "$fs" --staged "$f" 2>&1)
assert_contains "wrapper_genuine_auto_capture_accepted_control" "$out" "captured: "
assert_eq "wrapper_genuine_auto_capture_written" "1" "$(pending_count "$fs")"

# ===========================================================================
# 16. CROSS-PROVIDER LIST VISIBILITY
# ===========================================================================
echo "--- cross-provider visibility ---"

CLAUDE_REMEMBER="$HERE/../../../../plugins/knowledge/scripts/memory-remember.sh"
cpstore=$(bootstrap_store "$TMP/cross_provider")
f_cp="$TMP/cross_provider_staged.md"
stage_candidate "$f_cp" "sess-cp-codex" "normal" "Cross Provider Item" "captured under provider A" project

if [ -f "$CLAUDE_REMEMBER" ]; then
  echo "  (claude mirror's memory-remember.sh exists — running the real cross-provider fixture)"
  out=$(bash "$REMEMBER" --store "$cpstore" --staged "$f_cp" 2>&1)
  cpkey=$(printf '%s\n' "$out" | grep '^capture_id: ' | sed 's/^capture_id: //')
  out_claude_list=$(bash "$CLAUDE_REMEMBER" --store "$cpstore" --list 2>&1); rc=$?
  assert_rc "cross_provider_claude_list_exit0" 0 "$rc"
  assert_contains "cross_provider_claude_sees_codex_capture" "$out_claude_list" "$cpkey"
else
  # The Claude mirror's memory-remember.sh is unexpectedly unavailable.
  # this same check, run at test time so it self-upgrades once it does).
  # Simulate cross-invocation visibility: capture and list are two entirely
  # separate process invocations against the SAME provider-neutral,
  # gitignored store — the inbox mechanics never assume same-process state.
  # True cross-PROVIDER coverage (Codex capture visible to a genuinely
  # separate Claude script) resumes once the Claude mirror is available.
  echo "  NOTE  plugins/knowledge/scripts/memory-remember.sh not present -- asserting same-store cross-invocation visibility only; full cross-provider fixture unavailable"
  out=$(bash "$REMEMBER" --store "$cpstore" --staged "$f_cp" 2>&1)
  cpkey=$(printf '%s\n' "$out" | grep '^capture_id: ' | sed 's/^capture_id: //')
  out_second_invocation=$(bash "$REMEMBER" --store "$cpstore" --list 2>&1); rc=$?
  assert_rc "cross_invocation_list_exit0" 0 "$rc"
  assert_contains "cross_invocation_sees_prior_capture" "$out_second_invocation" "$cpkey"
fi

# ===========================================================================
# temp-file-free capture hash: equivalence, sandboxed-mktemp, fail-closed,
# and bounded wrapper diagnostics
# ===========================================================================
echo "--- tempfile-free canonical hash / wrapper diagnostics ---"

# Frozen reference: the pre-change (HEAD at 0.5.1) file-based implementation,
# verbatim apart from the function names. Independent of git state so the
# equivalence check keeps its meaning after this change is committed.
REFLIB="$TMP/ref_hash_lib.sh"
cat > "$REFLIB" <<'REFEOF'
_ref_emit_field() {
  local out="$1" name="$2" value="$3" len
  printf '%s\n' "$name" >> "$out"
  len=$(printf '%s' "$value" | wc -c | tr -d ' ')
  printf '%s\n' "$len" >> "$out"
  printf '%s' "$value" >> "$out"
  printf '\n' >> "$out"
}
ref_capture_canonical_hash() {
  local tmp sortfile hash
  tmp=$(mktemp) || return 1
  sortfile=$(mktemp) || { rm -f "$tmp"; return 1; }
  _ref_emit_field "$tmp" "source" "$KM_CAP_SOURCE"
  _ref_emit_field "$tmp" "sensitivity" "$KM_CAP_SENSITIVITY"
  if [ -n "${KM_CAP_EVIDENCE:-}" ]; then
    _ref_emit_field "$tmp" "evidence" "$KM_CAP_EVIDENCE"
  fi
  local i
  : > "$sortfile"
  for ((i = 0; i < ${#KM_CAP_PROPOSED_NAMES[@]}; i++)); do
    printf '%s\t%d\n' "${KM_CAP_PROPOSED_NAMES[i]}" "$i" >> "$sortfile"
  done
  local nm idx val joined first item
  while IFS=$'\t' read -r nm idx; do
    [ -n "$nm" ] || continue
    if [ "${KM_CAP_PROPOSED_TYPES[idx]}" = "list" ]; then
      val="${KM_CAP_PROPOSED_VALUES[idx]}"
      joined="" first=1
      if [ -n "$val" ]; then
        local -a items=()
        IFS=$'\x1f' read -r -a items <<< "$val"
        local ii
        for ((ii = 0; ii < ${#items[@]}; ii++)); do
          item="${items[ii]}"
          if [ "$first" -eq 1 ]; then
            joined="$item"
            first=0
          else
            joined="${joined}"$'\n'"${item}"
          fi
        done
      fi
      _ref_emit_field "$tmp" "$nm" "$joined"
    else
      _ref_emit_field "$tmp" "$nm" "${KM_CAP_PROPOSED_VALUES[idx]}"
    fi
  done < <(LC_ALL=C sort -t "$(printf '\t')" -k1,1 "$sortfile")
  local norm_body
  norm_body=$(km_normalize_capture_body "$KM_CAP_BODY")
  _ref_emit_field "$tmp" "body" "$norm_body"
  hash=$(km_sha256_file "$tmp")
  rm -f "$tmp" "$sortfile"
  printf '%s\n' "$hash"
}
REFEOF

HX="$TMP/hx"; mkdir -p "$HX"
hx_head() {  # <name> <source> <evidence-or-empty> <tags-block-or-empty> <body-printf-arg>
  {
    echo "---"; echo "source: $2"; echo "sensitivity: normal"
    [ -z "$3" ] || printf '%s\n' "$3"
    echo "proposed:"; echo '  schema_version: "1"'
    printf '%s\n' "  name: $1"; echo "  description: hash fixture $1"
    [ -z "$4" ] || printf '%s\n' "$4"
    echo "  metadata:"; echo "    type: project"; echo "---"
  }
}
{ hx_head "Hx Legacy" sess-x "" ""; echo "**Why:** body."; } > "$HX/legacy.md"
{ hx_head "Hx Evidence" auto_capture "evidence: src/app.sh:42" ""; echo "**Why:** body."; } > "$HX/evidence.md"
{ hx_head "Hx Tags" sess-x "" $'  tags:\n    - alpha\n    - "beta gamma"\n    - delta'; echo "**Why:** body."; } > "$HX/tags.md"
{ hx_head "Hx Body" sess-x "" ""; printf '\n\nline one   \r\nline two\n\n  indented\n\n\n\n'; } > "$HX/body.md"
{ hx_head "Hx Café ☃ 日本語" sess-x 'evidence: "user said: café ☃"' $'  tags:\n    - naïve\n    - 日本'; echo "**Why:** emoji 🎉."; } > "$HX/unicode.md"
{ hx_head "Hx 'Quoted'" sess-q "" ""; echo "body"; } > "$HX/quoted.md"
{ hx_head "Hx Empty Opt" sess-x "" $'  tags:'; } > "$HX/empty.md"

hx_new() { mw_call "km_parse_capture '$1' staged && km_capture_canonical_hash"; }
hx_ref() { mw_call "source '$REFLIB'; km_parse_capture '$1' staged && ref_capture_canonical_hash"; }
distinct_seen=""
for fx in legacy evidence tags body unicode quoted empty; do
  mw_call "km_parse_capture '$HX/$fx.md' staged" >/dev/null 2>&1; assert_rc "hash_fixture_${fx}_parses_control" 0 $?
  new_h=$(hx_new "$HX/$fx.md"); ref_h=$(hx_ref "$HX/$fx.md")
  [[ "$new_h" =~ ^[0-9a-f]{64}$ ]] && pass "hash_fixture_${fx}_is_sha256" || fail "hash_fixture_${fx}_is_sha256" "got [$new_h]"
  assert_eq "hash_equivalence_${fx}_matches_reference" "$ref_h" "$new_h"
  distinct_seen="$distinct_seen $new_h"
done
# negative control: the comparison can fail (different fixtures hash differently)
[ "$(hx_new "$HX/legacy.md")" != "$(hx_new "$HX/evidence.md")" ] && pass "hash_equivalence_detects_difference_control" || fail "hash_equivalence_detects_difference_control" "legacy == evidence"
assert_eq "hash_fixtures_all_distinct" "7" "$(printf '%s\n' $distinct_seen | sort -u | wc -l | tr -d ' ')"

# existing stored candidates still verify: capture each fixture, then re-hash the STORED file
hxs=$(bootstrap_store "$TMP/hx_store")
for fx in legacy evidence tags body unicode quoted empty; do
  out=$(bash "$REMEMBER" --store "$hxs" --staged "$HX/$fx.md" 2>&1); rc=$?
  assert_rc "stored_verify_${fx}_capture_ok" 0 "$rc"
  cid=$(printf '%s\n' "$out" | sed -n 's/^capture_id: //p')
  assert_eq "stored_verify_${fx}_id_is_reference_hash" "$(hx_ref "$HX/$fx.md")" "$cid"
  got=$(mw_call "km_parse_capture '$hxs/.inbox/$cid.md' stored && km_capture_canonical_hash")
  assert_eq "stored_verify_${fx}_rehash_equals_id" "$cid" "$got"
done

# pipefail must not leak out of km_capture_canonical_hash
leak=$(mw_call "set +o pipefail; km_parse_capture '$HX/legacy.md' staged && km_capture_canonical_hash >/dev/null; set -o | grep '^pipefail' | awk '{print \$2}'")
assert_eq "hash_does_not_leak_pipefail" "off" "$leak"

# --- sandbox that denies bare mktemp (macOS ignores TMPDIR for it) ---------
SHIM="$TMP/shim_mktemp"; mkdir -p "$SHIM"
REAL_MKTEMP=$(command -v mktemp)
cat > "$SHIM/mktemp" <<SHEOF
#!/bin/sh
[ \$# -eq 0 ] && { echo "mktemp: Operation not permitted" >&2; exit 1; }
exec "$REAL_MKTEMP" "\$@"
SHEOF
chmod +x "$SHIM/mktemp"
ms_ok=$(bootstrap_store "$TMP/mk_ok"); ms_shim=$(bootstrap_store "$TMP/mk_shim"); ms_head=$(bootstrap_store "$TMP/mk_head")
out_ok=$(bash "$REMEMBER" --store "$ms_ok" --staged "$HX/evidence.md" 2>&1); rc_ok=$?
out_shim=$(PATH="$SHIM:$PATH" bash "$REMEMBER" --store "$ms_shim" --staged "$HX/evidence.md" 2>&1); rc_shim=$?
assert_rc "bare_mktemp_denied_capture_succeeds_without_shim_control" 0 "$rc_ok"
assert_rc "bare_mktemp_denied_capture_succeeds" 0 "$rc_shim"
cid_ok=$(printf '%s\n' "$out_ok" | sed -n 's/^capture_id: //p'); cid_shim=$(printf '%s\n' "$out_shim" | sed -n 's/^capture_id: //p')
assert_eq "bare_mktemp_denied_same_id_as_unshimmed" "$cid_ok" "$cid_shim"
assert_file_present "bare_mktemp_denied_inbox_file_written" "$ms_shim/.inbox/$cid_shim.md"
# shim sanity: it really does deny the bare call but passes templated calls (control for the above)
PATH="$SHIM:$PATH" mktemp >/dev/null 2>&1; assert_rc "mktemp_shim_denies_bare_call_control" 1 $?
t=$(PATH="$SHIM:$PATH" mktemp "$TMP/shimctl.XXXXXX" 2>/dev/null); assert_rc "mktemp_shim_allows_templated_call_control" 0 $?; rm -f "$t"
# original-failure evidence: the frozen file-based reference fails under the shim
ref_shim=$(PATH="$SHIM:$PATH" mw_call "source '$REFLIB'; km_parse_capture '$HX/evidence.md' staged && ref_capture_canonical_hash" 2>/dev/null); rc=$?
[ "$rc" -ne 0 ] && pass "original_implementation_fails_under_bare_mktemp_denial" || fail "original_implementation_fails_under_bare_mktemp_denial" "reference unexpectedly succeeded: [$ref_shim]"
# end-to-end original-code failure (rc 2), when HEAD still carries the old writer
HEADW="$TMP/head_scripts"; rm -rf "$HEADW"
if git -C "$HERE" show HEAD:codex/plugins/knowledge/scripts/memory-write.sh > "$TMP/head_writer.sh" 2>/dev/null \
   && grep -q 'tmp=\$(mktemp) || return 1' "$TMP/head_writer.sh"; then
  cp -R "$HERE" "$HEADW"; cp "$TMP/head_writer.sh" "$HEADW/memory-write.sh"
  PATH="$SHIM:$PATH" bash "$HEADW/memory-remember.sh" --store "$ms_head" --staged "$HX/evidence.md" >/dev/null 2>&1
  assert_rc "head_writer_under_bare_mktemp_denial_exits_2" 2 $?
  bash "$HEADW/memory-remember.sh" --store "$ms_head" --staged "$HX/evidence.md" >/dev/null 2>&1
  assert_rc "head_writer_without_shim_succeeds_control" 0 $?
else
  echo "  NOTE  HEAD no longer carries the file-based hash; end-to-end HEAD failure case skipped (function-level reference above still applies)"
fi

# --- hash-tool failure fails closed -----------------------------------------
mk_sha_shim() {  # <dir> <mode: fail|empty|garbage>
  mkdir -p "$1"
  for t in shasum sha256sum; do
    case "$2" in
      fail)    printf '#!/bin/sh\ncat >/dev/null 2>&1\nexit 1\n' > "$1/$t" ;;
      empty)   printf '#!/bin/sh\ncat >/dev/null 2>&1\nexit 0\n' > "$1/$t" ;;
      garbage) printf '#!/bin/sh\ncat >/dev/null 2>&1\necho abc123 -\nexit 0\n' > "$1/$t" ;;
    esac
    chmod +x "$1/$t"
  done
}
for mode in fail empty garbage; do
  mk_sha_shim "$TMP/shim_sha_$mode" "$mode"
  hs=$(bootstrap_store "$TMP/hf_$mode")
  h=$(PATH="$TMP/shim_sha_$mode:$PATH" mw_call "km_parse_capture '$HX/evidence.md' staged && km_capture_canonical_hash" 2>/dev/null); rc=$?
  [ "$rc" -ne 0 ] && pass "hash_tool_${mode}_function_nonzero" || fail "hash_tool_${mode}_function_nonzero" "rc=0"
  assert_eq "hash_tool_${mode}_function_prints_no_hash" "" "$h"
  PATH="$TMP/shim_sha_$mode:$PATH" bash "$WRITER" capture --store "$hs" --staged "$HX/evidence.md" --idempotency-key "$(printf 'a%.0s' $(seq 1 64))" >/dev/null 2>&1
  [ "$?" -ne 0 ] && pass "hash_tool_${mode}_writer_nonzero" || fail "hash_tool_${mode}_writer_nonzero" "rc=0"
  PATH="$TMP/shim_sha_$mode:$PATH" bash "$REMEMBER" --store "$hs" --staged "$HX/evidence.md" >/dev/null 2>&1
  [ "$?" -ne 0 ] && pass "hash_tool_${mode}_remember_nonzero" || fail "hash_tool_${mode}_remember_nonzero" "rc=0"
  assert_eq "hash_tool_${mode}_no_inbox_file" "0" "$(pending_count "$hs")"
done
h=$(hx_new "$HX/evidence.md"); rc=$?
assert_rc "hash_tool_real_works_control" 0 "$rc"
[[ "$h" =~ ^[0-9a-f]{64}$ ]] && pass "hash_tool_real_prints_hash_control" || fail "hash_tool_real_prints_hash_control" "[$h]"

# --- per-stage fail-closed: wc / sort / awk (normalizer + sha post-filter) ---
# Each shim either exits 1 or exits 0 silently with no output; every stage
# failure must yield no hash, a non-zero writer rc and no inbox file.
for tool in wc sort awk; do
  for mode in fail silent; do
    sd="$TMP/shim_${tool}_$mode"; mkdir -p "$sd"
    if [ "$mode" = fail ]; then printf '#!/bin/sh\ncat >/dev/null 2>&1\nexit 1\n' > "$sd/$tool"
    else printf '#!/bin/sh\ncat >/dev/null 2>&1\nexit 0\n' > "$sd/$tool"; fi
    chmod +x "$sd/$tool"
    for fx in tags legacy; do
      h=$(PATH="$sd:$PATH" mw_call "km_parse_capture '$HX/$fx.md' staged && km_capture_canonical_hash" 2>/dev/null); rc=$?
      [ "$rc" -ne 0 ] && pass "stage_${tool}_${mode}_${fx}_function_nonzero" || fail "stage_${tool}_${mode}_${fx}_function_nonzero" "rc=0 hash=[$h]"
      assert_eq "stage_${tool}_${mode}_${fx}_function_prints_no_hash" "" "$h"
    done
    ss=$(bootstrap_store "$TMP/st_${tool}_$mode")
    PATH="$sd:$PATH" bash "$REMEMBER" --store "$ss" --staged "$HX/tags.md" >/dev/null 2>&1; rc=$?
    [ "$rc" -ne 0 ] && pass "stage_${tool}_${mode}_remember_nonzero" || fail "stage_${tool}_${mode}_remember_nonzero" "rc=0"
    assert_eq "stage_${tool}_${mode}_no_inbox_file" "0" "$(pending_count "$ss" 2>/dev/null)"
  done
done
# controls: no shim gives the correct hash (== frozen reference) and a real capture
for fx in tags legacy body; do
  assert_eq "stage_control_${fx}_equals_reference" "$(hx_ref "$HX/$fx.md")" "$(hx_new "$HX/$fx.md")"
done
ssc=$(bootstrap_store "$TMP/st_control")
bash "$REMEMBER" --store "$ssc" --staged "$HX/tags.md" >/dev/null 2>&1; assert_rc "stage_control_unshimmed_capture_ok" 0 $?
assert_eq "stage_control_unshimmed_inbox_file" "1" "$(pending_count "$ssc")"
# the writer's own hash-failure message is the classifier hook
msg=$(PATH="$TMP/shim_sha_fail:$PATH" bash "$REMEMBER" --store "$ssc" --staged "$HX/evidence.md" 2>&1 >/dev/null | tail -n 1)
assert_contains "hash_failure_writer_message" "$msg" "capture hash computation failed"

# --- wrapper: fixed-category writer diagnostics (stderr never echoed) -------
DSTUB="$TMP/diag_scripts"; rm -rf "$DSTUB"; cp -R "$HERE" "$DSTUB"
dstore=$(bootstrap_store "$TMP/diag_store")
mkdiag() {  # <stub-body>
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$DSTUB/memory-remember.sh"
}
diag_cand="$TMP/diag_cand.md"
cat > "$diag_cand" <<'DEOF'
---
source: auto_capture
sensitivity: normal
evidence: src/diag.sh:7
proposed:
  schema_version: "1"
  name: Diag Candidate Name
  description: Diag distinctive description text
  metadata:
    type: project
---
**Why:** Diag distinctive body sentence about turnips.
DEOF
run_diag() { CLAUDE_CODE_SESSION_ID=sessDiag bash "$DSTUB/memory-auto-capture.sh" --store "$dstore" --staged "$diag_cand" 2>&1; }
diag_case() {  # <label> <rc> <stderr-line> <expected-category>
  mkdiag "printf '%s\\n' '$3' >&2; exit $2"
  out=$(run_diag); local wrc=$?
  assert_rc "diag_${1}_wrapper_exit0" 0 "$wrc"
  assert_contains "diag_${1}_category" "$out" "reason: $4"
  assert_contains "diag_${1}_keeps_rc_line" "$out" "writer rejected candidate (rc=$2)"
  assert_contains "diag_${1}_counts_rejected" "$out" "1 rejected"
}
diag_case hash 2 'ERROR: capture hash computation failed' "hash computation failed"
diag_case hash_remember 4 'ERROR: cannot compute a valid capture idempotency key (sha256 tool unavailable?)' "hash computation failed"
diag_case locked5 5 'store locked: /x/.lock' "store locked"
diag_case locked4 4 'ERROR: cannot acquire store lock (unexpected failure): /x/.lock' "store locked"
diag_case resolution 3 'ERROR: no store' "store resolution failed"
diag_case integrity 4 'ERROR: .inbox exists but is not a safe directory: /x' "store integrity error"
diag_case grammar 2 'ERROR: malformed line under proposed.tags: something' "capture grammar rejected"
diag_case grammar_unknown 2 'ERROR: unknown top-level field: foo' "capture grammar rejected"
diag_case unknown_rc2 2 'ERROR: something never seen' "unknown writer error (rc=2)"
diag_case unknown_rc9 9 'weird' "unknown writer error (rc=9)"
diag_case silent 3 '' "store resolution failed"
# negative: the categories are mutually exclusive (a hash failure is not labelled locked/grammar)
mkdiag "printf '%s\\n' 'ERROR: capture hash computation failed' >&2; exit 2"
out=$(run_diag)
assert_not_contains "diag_hash_not_grammar_label" "$out" "capture grammar rejected"
assert_not_contains "diag_hash_not_locked_label" "$out" "store locked"
# raw stderr, candidate text and secret-like tokens are NEVER echoed
for leak in "Diag Candidate Name" "Diag distinctive description text" "Diag distinctive body sentence about turnips." "src/diag.sh:7" "sk-abcdefghijklmnopqrstuvwx" "AKIAABCDEFGHIJKLMNOP" "verbatim-stderr-marker"; do
  mkdiag "printf '%s\\n' 'ERROR: malformed line: $leak' >&2; exit 2"
  out=$(run_diag)
  assert_not_contains "diag_no_echo[${leak:0:24}]" "$out" "$leak"
  assert_not_contains "diag_no_raw_prefix[${leak:0:24}]" "$out" "malformed line"
  assert_contains "diag_labelled[${leak:0:24}]" "$out" "reason: capture grammar rejected"
done
mkdiag 'printf "ERROR: weird thing sk-abcdefghijklmnopqrstuvwx\033[31m\n" >&2; exit 2'
out=$(run_diag)
assert_not_contains "diag_no_echo_unclassified_secret" "$out" "sk-abcdefghijklmnop"
assert_contains "diag_unclassified_generic" "$out" "unknown writer error (rc=2)"
# rc 6 / rc 7 semantics unchanged
mkdiag 'echo "ERROR: reviewer" >&2; exit 6'
out=$(run_diag); rc=$?
assert_rc "diag_rc6_still_aborts_exit6" 6 "$rc"
assert_not_contains "diag_rc6_no_reason" "$out" "reason:"
mkdiag 'echo "ERROR: policy" >&2; exit 7'
out=$(run_diag); rc=$?
assert_rc "diag_rc7_wrapper_exit0" 0 "$rc"
assert_contains "diag_rc7_policy_message_unchanged" "$out" "writer refused candidate by capture policy (evidence missing, MAX_PENDING or SESSION_LIMIT reached; rc=7)"
assert_not_contains "diag_rc7_no_reason" "$out" "reason:"
# control: success path output unchanged
mkdiag 'echo "capture_id: '"$(printf 'c%.0s' $(seq 1 64))"'"; echo "noise on stderr" >&2; exit 0'
out=$(run_diag); rc=$?
assert_rc "diag_success_exit0_control" 0 "$rc"
assert_contains "diag_success_captured_line_control" "$out" "captured: $(printf 'c%.0s' $(seq 1 64))"
assert_not_contains "diag_success_no_reason_control" "$out" "reason:"
assert_not_contains "diag_success_no_rejection_control" "$out" "writer rejected"
assert_not_contains "diag_success_stderr_not_echoed_control" "$out" "noise on stderr"
out=$(CLAUDE_CODE_SESSION_ID=sessDiag bash "$AUTOCAP" --store "$(bootstrap_store "$TMP/diag_real")" --staged "$diag_cand" 2>&1)
assert_contains "diag_real_writer_success_control" "$out" "captured: "
# end-to-end with the real writer: sha tool failure is categorised, nothing leaks
rstore=$(bootstrap_store "$TMP/diag_e2e")
out=$(PATH="$TMP/shim_sha_fail:$PATH" CLAUDE_CODE_SESSION_ID=sessDiag bash "$AUTOCAP" --store "$rstore" --staged "$diag_cand" 2>&1); rc=$?
assert_rc "diag_e2e_hash_failure_wrapper_exit0" 0 "$rc"
assert_eq "diag_e2e_hash_failure_no_inbox_file" "0" "$(pending_count "$rstore" 2>/dev/null)"
assert_not_contains "diag_e2e_no_body_echo" "$out" "turnips"
assert_contains "diag_e2e_sha_failure_hash_label" "$out" "reason: hash computation failed"
assert_not_contains "diag_e2e_sha_failure_not_grammar_label" "$out" "capture grammar rejected"
for tool in wc sort awk; do
  rstore=$(bootstrap_store "$TMP/diag_e2e_$tool")
  out=$(PATH="$TMP/shim_${tool}_fail:$PATH" CLAUDE_CODE_SESSION_ID=sessDiag bash "$AUTOCAP" --store "$rstore" --staged "$diag_cand" 2>&1)
  assert_eq "diag_e2e_${tool}_failure_no_inbox_file" "0" "$(pending_count "$rstore" 2>/dev/null)"
  assert_not_contains "diag_e2e_${tool}_failure_no_candidate_echo" "$out" "turnips"
  assert_not_contains "diag_e2e_${tool}_failure_not_captured" "$out" "captured: "
  assert_not_contains "diag_e2e_${tool}_failure_not_grammar_label" "$out" "reason: capture grammar rejected"
done
# grammar-failure control still maps to the grammar label (stub writer message)
mkdiag "printf '%s\\n' 'ERROR: malformed frontmatter line (expected key:): x' >&2; exit 2"
out=$(run_diag)
assert_contains "diag_grammar_control_label" "$out" "reason: capture grammar rejected"
assert_not_contains "diag_grammar_control_not_hash_label" "$out" "hash computation failed"

# ===========================================================================
# summary
# ===========================================================================
echo ""
echo "=== capture tests: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  echo "Failures:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
exit 0
