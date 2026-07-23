#!/usr/bin/env bash
# test-capture.sh — hermetic tests for Phase B3 (candidate capture):
# memory-remember.sh's planner/normalizer contract (--staged and --list
# modes), the `.inbox/` lifecycle (KNOWLEDGE_PLUGIN_SPEC.md "remember"
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

# capture_id then created as the FIRST TWO frontmatter keys, followed by
# the envelope keys as staged (source, sensitivity, proposed:, ...).
mapfile_lines=()
while IFS= read -r line; do mapfile_lines+=("$line"); done < "$store/.inbox/${key1}.md"
assert_eq "basic_capture_line1_fence" "---" "${mapfile_lines[0]}"
assert_eq "basic_capture_line2_capture_id" "capture_id: ${key1}" "${mapfile_lines[1]}"
case "${mapfile_lines[2]}" in
  "created: "*) pass "basic_capture_line3_created" ;;
  *) fail "basic_capture_line3_created" "got: ${mapfile_lines[2]}" ;;
esac
assert_eq "basic_capture_line4_source" "source: sess-basic-1" "${mapfile_lines[3]}"
assert_eq "basic_capture_line5_sensitivity" "sensitivity: normal" "${mapfile_lines[4]}"
assert_eq "basic_capture_line6_proposed" "proposed:" "${mapfile_lines[5]}"

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
# 16. CROSS-PROVIDER LIST VISIBILITY
# ===========================================================================
echo "--- cross-provider visibility ---"

CODEX_REMEMBER="$HERE/../../../codex/plugins/knowledge/scripts/memory-remember.sh"
cpstore=$(bootstrap_store "$TMP/cross_provider")
f_cp="$TMP/cross_provider_staged.md"
stage_candidate "$f_cp" "sess-cp-claude" "normal" "Cross Provider Item" "captured under provider A" project

if [ -f "$CODEX_REMEMBER" ]; then
  echo "  (codex mirror's memory-remember.sh exists — running the real cross-provider fixture)"
  out=$(bash "$REMEMBER" --store "$cpstore" --staged "$f_cp" 2>&1)
  cpkey=$(printf '%s\n' "$out" | grep '^capture_id: ' | sed 's/^capture_id: //')
  out_codex_list=$(bash "$CODEX_REMEMBER" --store "$cpstore" --list 2>&1); rc=$?
  assert_rc "cross_provider_codex_list_exit0" 0 "$rc"
  assert_contains "cross_provider_codex_sees_claude_capture" "$out_codex_list" "$cpkey"
else
  # The codex mirror's memory-remember.sh has not landed yet (confirmed via
  # this same check, run at test time so it self-upgrades once it does).
  # Simulate cross-invocation visibility: capture and list are two entirely
  # separate process invocations against the SAME provider-neutral,
  # gitignored store — the inbox mechanics never assume same-process state.
  # True cross-PROVIDER coverage (Claude capture visible to a genuinely
  # separate Codex script) completes once the codex mirror lands.
  echo "  NOTE  codex/plugins/knowledge/scripts/memory-remember.sh not present yet -- asserting same-store cross-invocation visibility only; full cross-provider fixture pending the codex mirror"
  out=$(bash "$REMEMBER" --store "$cpstore" --staged "$f_cp" 2>&1)
  cpkey=$(printf '%s\n' "$out" | grep '^capture_id: ' | sed 's/^capture_id: //')
  out_second_invocation=$(bash "$REMEMBER" --store "$cpstore" --list 2>&1); rc=$?
  assert_rc "cross_invocation_list_exit0" 0 "$rc"
  assert_contains "cross_invocation_sees_prior_capture" "$out_second_invocation" "$cpkey"
fi

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
