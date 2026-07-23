#!/usr/bin/env bash
# test-memory-kernel.sh — hermetic tests for the Phase B1 memory-store kernel
# (lib.sh resolver/hardening/slug/role primitives, memory-lint.sh,
# memory-index.sh, memory-write.sh's single-writer transaction contract,
# init.sh). All fixture content is synthetic (ProjectA/ProjectB-style),
# never real project names. Uses isolated git repos under a temp dir;
# cleans up on exit.
#
# Usage: bash test-memory-kernel.sh [-v]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/lib.sh"
WRITER="$HERE/memory-write.sh"
LINT="$HERE/memory-lint.sh"
INDEXTOOL="$HERE/memory-index.sh"
INIT="$HERE/init.sh"

PASS=0
FAIL=0
FAILURES=()
TMP="$(mktemp -d -t kmkernel-test-XXXXXX)"
TMP="$(cd "$TMP" && pwd -P)"
XFS_MOUNT=""

cleanup() {
  if [ -n "$XFS_MOUNT" ]; then
    hdiutil detach "$XFS_MOUNT" -force >/dev/null 2>&1 || true
  fi
  chmod -R u+rwx "$TMP" 2>/dev/null || true
  rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1: $2"); echo "  FAIL  $1 -- $2"; }

# Default identity for every test unless a test explicitly overrides it: a
# non-reviewer executor name, so writes proceed by default. Role-refusal
# tests override/unset this per invocation.
export KNOWLEDGE_PANE_NAME=test-executor
unset SESSION_CHAT_PANE_NAME 2>/dev/null || true

echo "=== memory-kernel tests (tmp: $TMP) ==="

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

sha_of() {
  mw_call "km_sha256_file '$1' 2>/dev/null"
}

# write_memfile <path> <schema_version|legacy> <type> <name> <desc> [extra-frontmatter-lines...]
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

# capture_synthetic <store> <source> <name> <desc> <type> -> echoes capture id
capture_synthetic() {
  local store="$1" src="$2" name="$3" desc="$4" type="$5" f key
  f=$(mktemp "$TMP/staged.XXXXXX")
  {
    echo "---"
    echo "source: $src"
    echo "sensitivity: normal"
    echo "proposed:"
    echo "  schema_version: \"1\""
    echo "  name: $name"
    echo "  description: $desc"
    echo "  metadata:"
    echo "    type: $type"
    echo "---"
    echo "**Why:** synthetic capture."
    echo
    echo "**How to apply:** n/a."
  } > "$f"
  key=$(mw_call "km_parse_capture '$f' staged >/dev/null 2>&1 && km_capture_canonical_hash")
  bash "$WRITER" capture --store "$store" --staged "$f" --idempotency-key "$key" > /dev/null 2>&1
  printf '%s\n' "$key"
}

assert_rc() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    pass "$label"
  else
    fail "$label" "expected rc=$expected got rc=$actual"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label" "expected output to contain [$needle], got: $haystack" ;;
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

assert_clean_store() {
  local label="$1" store="$2" leftover
  leftover=$(find "$store" -mindepth 1 -maxdepth 1 \( -name '.journal*' -o -name '.staged.*' -o -name '.lock*' \) 2>/dev/null)
  if [ -z "$leftover" ]; then
    pass "$label"
  else
    fail "$label" "leftover artifacts: $leftover"
  fi
}

# tree_hash <dir> [name-pattern] -- stable aggregate hash of relpath+content
# for every regular file under dir (sorted), used to prove a read-only tool
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

# ===========================================================================
# 1. DISCOVERY FIXTURES (canonical MEMORY-store discovery algorithm)
# ===========================================================================
echo "--- discovery ---"

d="$TMP/disc_zero"
new_repo "$d"
out=$(cd "$d" && mw_call "km_resolve_store" 2>&1); rc=$?
assert_rc "discovery_zero_exit3" 3 "$rc"
assert_contains "discovery_zero_message" "$out" "no memory store found"

d="$TMP/disc_root"
new_repo "$d"
mkdir -p "$d/.agents/memory"
touch "$d/.agents/memory/MEMORY.md"
out=$(cd "$d" && mw_call "km_resolve_store" 2>&1); rc=$?
assert_rc "discovery_root_exit0" 0 "$rc"
assert_contains "discovery_root_path" "$out" "/.agents/memory"

d="$TMP/disc_single"
new_repo "$d"
mkdir -p "$d/.agents/memory/childA"
touch "$d/.agents/memory/childA/MEMORY.md"
out=$(cd "$d" && mw_call "km_resolve_store" 2>&1); rc=$?
assert_rc "discovery_single_nested_exit0" 0 "$rc"
assert_contains "discovery_single_nested_path" "$out" "childA"

d="$TMP/disc_multi"
new_repo "$d"
mkdir -p "$d/.agents/memory/childA" "$d/.agents/memory/childB"
touch "$d/.agents/memory/childA/MEMORY.md" "$d/.agents/memory/childB/MEMORY.md"
out=$(cd "$d" && mw_call "km_resolve_store" 2>&1); rc=$?
assert_rc "discovery_multi_nested_ambiguous_exit3" 3 "$rc"
assert_contains "discovery_multi_nested_lists_both" "$out" "childA"
assert_contains "discovery_multi_nested_lists_both2" "$out" "childB"

d="$TMP/disc_env_invalid"
new_repo "$d"
mkdir -p "$d/elsewhere"
out=$(cd "$d" && KNOWLEDGE_MEMORY_HOME="$d/elsewhere" mw_call "km_resolve_store" 2>&1); rc=$?
assert_rc "discovery_env_invalid_exit3" 3 "$rc"
assert_contains "discovery_env_invalid_message" "$out" "no MEMORY.md"

d="$TMP/disc_env_valid"
new_repo "$d"
mkdir -p "$d/elsewhere"
touch "$d/elsewhere/MEMORY.md"
out=$(cd "$d" && KNOWLEDGE_MEMORY_HOME="$d/elsewhere" mw_call "km_resolve_store" 2>&1); rc=$?
assert_rc "discovery_env_valid_exit0" 0 "$rc"

# ===========================================================================
# 2. STORE HARDENING
# ===========================================================================
echo "--- store hardening ---"

d="$TMP/hard_symlink_store"
new_repo "$d"
mkdir -p "$d/real_target"
touch "$d/real_target/MEMORY.md"
ln -s "$d/real_target" "$d/.agents_link"
out=$(cd "$d" && mw_call "km_resolve_store '$d/.agents_link'" 2>&1); rc=$?
assert_rc "hardening_symlink_store_rejected" 4 "$rc"

d="$TMP/hard_symlink_memfile"
new_repo "$d"
mkdir -p "$d/store"
touch "$d/real.md"
ln -s "$d/real.md" "$d/store/MEMORY.md"
out=$(cd "$d" && mw_call "km_resolve_store '$d/store'" 2>&1); rc=$?
assert_rc "hardening_symlink_memory_md_rejected" 4 "$rc"

d="$TMP/hard_out_of_repo"
mkdir -p "$d"
touch "$d/MEMORY.md"
out=$(mw_call "km_resolve_store '$d'" 2>&1); rc=$?
assert_rc "hardening_out_of_repo_exit3" 3 "$rc"
assert_contains "hardening_out_of_repo_message" "$out" "not inside a git repository"

# ===========================================================================
# 3. memory-lint.sh -- canonical + legacy tiers, collisions, degenerate styles
# ===========================================================================
echo "--- memory-lint.sh ---"

store=$(bootstrap_store "$TMP/lintstore")

write_canonical "$store/good.md" project "Good Item" "a fine item"
write_canonical "$store/bad_enum.md" bogus "Bad Enum" "bad type"
cat > "$store/missing_why.md" <<'EOF'
---
schema_version: 1
name: Missing Why
description: feedback missing sections
metadata:
  type: feedback
created: 2026-01-01
updated: 2026-01-02
---
no why or how here
EOF
cat > "$store/unknown_no_migrated.md" <<'EOF'
---
schema_version: 1
name: Unknown No Migrated
description: d
metadata:
  type: reference
created: unknown
updated: 2026-01-02
---
body
EOF
cat > "$store/unknown_with_migrated.md" <<'EOF'
---
schema_version: 1
name: Unknown With Migrated
description: d
metadata:
  type: reference
created: unknown
updated: 2026-01-02
migrated: 2026-01-05
---
body
EOF
cat > "$store/legacy_typed.md" <<'EOF'
---
type: project
name: Legacy Typed Item
---
legacy content
EOF
cat > "$store/legacy_ambiguous.md" <<'EOF'
---
type: not_a_real_type
name: Legacy Ambiguous
---
legacy content
EOF
cat > "$store/feedback_2026-03-01_dated.md" <<'EOF'
---
name: Dated legacy
---
**Why:** w

**How to apply:** h
EOF
printf 'not frontmatter\n' > "$store/unparseable.md"
cat > "$store/MEMORY.md" <<'EOF'
- [Good](good.md) — g
- [Bad](bad_enum.md) — b
- [MissingWhy](missing_why.md) — m
- [U1](unknown_no_migrated.md) — u1
- [U2](unknown_with_migrated.md) — u2
- [Legacy](legacy_typed.md) — l
- [LegacyAmbig](legacy_ambiguous.md) — la
- [Dated](feedback_2026-03-01_dated.md) — d
- [Bad2](unparseable.md) — up
EOF
chmod 600 "$store"/*.md
chmod 700 "$store"

before_hash=$(tree_hash "$store" "*.md")
out=$(bash "$LINT" --store "$store"); rc=$?
after_hash=$(tree_hash "$store" "*.md")
assert_rc "lint_exit4_on_errors" 4 "$rc"
[ "$before_hash" = "$after_hash" ] && pass "lint_read_only_byte_identical" || fail "lint_read_only_byte_identical" "tree changed"
assert_contains "lint_bad_enum_error" "$out" $'ERROR\tbad_enum.md\tinvalid metadata.type'
assert_contains "lint_missing_why_error" "$out" $'ERROR\tmissing_why.md\tmissing required body section: **Why:**'
assert_contains "lint_missing_how_error" "$out" $'ERROR\tmissing_why.md\tmissing required body section: **How to apply:**'
assert_contains "lint_unknown_no_migrated_error" "$out" $'ERROR\tunknown_no_migrated.md\tcreated: unknown requires'
case "$out" in
  *"unknown_with_migrated.md"*) fail "lint_unknown_with_migrated_clean" "unexpected finding for a valid unknown+migrated file" ;;
  *) pass "lint_unknown_with_migrated_clean" ;;
esac
assert_contains "lint_legacy_typed_advisory" "$out" $'ADVISORY\tlegacy_typed.md\tmigration: metadata.type: project'
assert_contains "lint_legacy_ambiguous_error" "$out" $'ERROR\tlegacy_ambiguous.md\tambiguous legacy type value'
assert_contains "lint_legacy_dated_created_advisory" "$out" "migration: created: 2026-03-01 (derived from filename)"
assert_contains "lint_unparseable_error" "$out" $'ERROR\tunparseable.md\tunparseable frontmatter'
case "$out" in
  *$'\tgood.md\t'*) fail "lint_good_file_clean" "unexpected finding for a fully valid canonical file" ;;
  *) pass "lint_good_file_clean" ;;
esac

# missing required fields (each individually)
mstore=$(bootstrap_store "$TMP/lint_missing_fields")
cat > "$mstore/no_desc.md" <<'EOF'
---
schema_version: 1
name: No Description
metadata:
  type: project
created: 2026-01-01
updated: 2026-01-02
---
**Why:** w

**How to apply:** h
EOF
echo "- [x](no_desc.md) — x" > "$mstore/MEMORY.md"
out=$(bash "$LINT" --store "$mstore")
assert_contains "lint_missing_description_error" "$out" "missing required field: description"

# collision short-circuit
cstore=$(bootstrap_store "$TMP/lint_collision")
write_canonical "$cstore/dup_a.md" project "A" "a"
cp "$cstore/dup_a.md" "$cstore/dup-a.md"
chmod 600 "$cstore"/*.md
echo "- [A](dup_a.md) — a" > "$cstore/MEMORY.md"
echo "- [A2](dup-a.md) — a2" >> "$cstore/MEMORY.md"
out=$(bash "$LINT" --store "$cstore"); rc=$?
assert_rc "lint_collision_exit4" 4 "$rc"
assert_contains "lint_collision_reported" "$out" "slug collision with"

# degenerate index styles
pstore=$(bootstrap_store "$TMP/lint_prose")
cat > "$pstore/MEMORY.md" <<'EOF'
This store is just some free-form notes with no index rows at all.
EOF
out=$(bash "$LINT" --store "$pstore"); rc=$?
assert_rc "lint_prose_degenerate_exit0" 0 "$rc"
assert_contains "lint_prose_degenerate_advisory" "$out" "free prose with no index rows"

istore=$(bootstrap_store "$TMP/lint_inline")
touch "$istore/x.md"
cat > "$istore/MEMORY.md" <<'EOF'
- [X](x.md) — x
Also remember the deploy key rotates every 90 days in the vault under
secrets/deploy, which really belongs in its own memory file.
EOF
out=$(bash "$LINT" --store "$istore")
assert_contains "lint_inline_prose_advisory" "$out" "carries inline knowledge content"

# ===========================================================================
# 4. memory-index.sh -- style detection, membership reconciliation
# ===========================================================================
echo "--- memory-index.sh ---"

fstore=$(bootstrap_store "$TMP/idx_flat")
touch "$fstore/a.md" "$fstore/b.md"
printf -- '- [A](a.md) -- a\n- [B](b.md) -- b\n' > "$fstore/MEMORY.md"
before=$(tree_hash "$fstore")
out=$(bash "$INDEXTOOL" --store "$fstore"); rc=$?
after=$(tree_hash "$fstore")
assert_rc "index_flat_clean_exit0" 0 "$rc"
[ -z "$out" ] && pass "index_flat_clean_no_findings" || fail "index_flat_clean_no_findings" "$out"
[ "$before" = "$after" ] && pass "index_read_only_byte_identical" || fail "index_read_only_byte_identical" "tree changed"

sstore=$(bootstrap_store "$TMP/idx_sectioned")
touch "$sstore/a.md" "$sstore/b.md" "$sstore/c.md"
cat > "$sstore/MEMORY.md" <<'EOF'
# Section One
- [A](a.md) -- a
- [B](b.md) -- b, see also [C](c.md)

## Subsection
- [C](c.md) -- c
EOF
out=$(bash "$INDEXTOOL" --store "$sstore"); rc=$?
assert_rc "index_sectioned_multilink_clean_exit0" 0 "$rc"
[ -z "$out" ] && pass "index_sectioned_multilink_no_findings" || fail "index_sectioned_multilink_no_findings" "$out"

dstore=$(bootstrap_store "$TMP/idx_defects")
touch "$dstore/a.md" "$dstore/b.md" "$dstore/orphan.md"
cat > "$dstore/MEMORY.md" <<'EOF'
- [A](a.md) -- a
- [A again](a.md) -- dup
- [Ghost](ghost.md) -- missing file
- [Bad](../escape.md) -- traversal
EOF
out=$(bash "$INDEXTOOL" --store "$dstore"); rc=$?
assert_rc "index_defects_exit0" 0 "$rc"
assert_contains "index_duplicate_membership" "$out" $'DRIFT\tduplicate-membership\ta.md'
assert_contains "index_missing_entry_b" "$out" $'DRIFT\tmissing-entry\tb.md'
assert_contains "index_missing_entry_orphan" "$out" $'DRIFT\tmissing-entry\torphan.md'
assert_contains "index_missing_file_ghost" "$out" $'DRIFT\tmissing-file\tghost.md'
assert_contains "index_bad_target_traversal" "$out" $'DRIFT\tbad-target\t../escape.md'

astore=$(bootstrap_store "$TMP/idx_ambiguous")
touch "$astore/a.md" "$astore/b.md"
cat > "$astore/MEMORY.md" <<'EOF'
- [A](a.md) -- a
# Section
- [B](b.md) -- b
EOF
out=$(bash "$INDEXTOOL" --store "$astore"); rc=$?
assert_rc "index_ambiguous_style_exit4" 4 "$rc"
assert_contains "index_ambiguous_style_message" "$out" "ambiguous style"

symstore=$(bootstrap_store "$TMP/idx_symlink")
touch "$symstore/a.md"
ln -s /etc/hosts "$symstore/evil.md"
printf -- '- [A](a.md) -- a\n' > "$symstore/MEMORY.md"
out=$(bash "$INDEXTOOL" --store "$symstore"); rc=$?
assert_rc "index_symlink_excluded_exit0" 0 "$rc"
assert_contains "index_symlink_excluded_reported" "$out" "evil.md (symlinked .md excluded"

# ===========================================================================
# 5. memory-write.sh capture
# ===========================================================================
echo "--- memory-write.sh capture ---"

cstore2=$(bootstrap_store "$TMP/cap_basic")
key1=$(capture_synthetic "$cstore2" "sess-1" "ProjectA Deploy" "deploy notes" project)
assert_file_present "capture_basic_file_created" "$cstore2/.inbox/${key1}.md"
mode=$(mw_call "km_path_mode '$cstore2/.inbox'")
[ "$mode" = "700" ] && pass "capture_inbox_mode_700" || fail "capture_inbox_mode_700" "got $mode"
mode=$(mw_call "km_path_mode '$cstore2/.inbox/${key1}.md'")
[ "$mode" = "600" ] && pass "capture_file_mode_600" || fail "capture_file_mode_600" "got $mode"

# idempotent re-capture (identical content -> no-op, same id)
f2=$(mktemp "$TMP/staged.XXXXXX")
{
  echo "---"
  echo "source: sess-1"
  echo "sensitivity: normal"
  echo "proposed:"
  echo "  schema_version: \"1\""
  echo "  name: ProjectA Deploy"
  echo "  description: deploy notes"
  echo "  metadata:"
  echo "    type: project"
  echo "---"
  echo "**Why:** synthetic capture."
  echo
  echo "**How to apply:** n/a."
} > "$f2"
out=$(bash "$WRITER" capture --store "$cstore2" --staged "$f2" --idempotency-key "$key1" 2>&1); rc=$?
assert_rc "capture_idempotent_noop_exit0" 0 "$rc"
assert_contains "capture_idempotent_noop_message" "$out" "no-op"
count=$(find "$cstore2/.inbox" -name '*.md' | wc -l | tr -d ' ')
[ "$count" = "1" ] && pass "capture_idempotent_single_file" || fail "capture_idempotent_single_file" "count=$count"

# tamper: the STORED candidate is edited directly (bypassing the writer) so
# its re-derived canonical hash no longer equals its own capture_id/filename
# -- re-capturing the ORIGINAL staged content (whose hash still equals key1)
# must detect the stored candidate diverged and refuse as a store-integrity
# error rather than silently keeping or replacing it.
sed -i.bak 's/ProjectA Deploy/ProjectA Deploy TAMPERED/' "$cstore2/.inbox/${key1}.md"
rm -f "$cstore2/.inbox/${key1}.md.bak"
out=$(bash "$WRITER" capture --store "$cstore2" --staged "$f2" --idempotency-key "$key1" 2>&1); rc=$?
assert_rc "capture_semantic_tamper_rejected_exit4" 4 "$rc"
# restore for subsequent tests
{
  echo "---"
  echo "capture_id: $key1"
  echo "created: 2026-01-01T00:00:00Z"
  echo "source: sess-1"
  echo "sensitivity: normal"
  echo "proposed:"
  echo "  schema_version: \"1\""
  echo "  name: ProjectA Deploy"
  echo "  description: deploy notes"
  echo "  metadata:"
  echo "    type: project"
  echo "---"
  echo "**Why:** synthetic capture."
  echo
  echo "**How to apply:** n/a."
} > "$cstore2/.inbox/${key1}.md"
chmod 600 "$cstore2/.inbox/${key1}.md"

# tamper: raw bytes of the STORED candidate change without changing its
# semantic content (a trailing blank line the canonical body-normalization
# rule strips) -- re-capturing the ORIGINAL staged content must re-derive an
# EQUAL canonical hash and collapse to a no-op (distinct from the class
# above: this is the "harmless raw diff" case, not tampering).
printf '\n' >> "$cstore2/.inbox/${key1}.md"
out=$(bash "$WRITER" capture --store "$cstore2" --staged "$f2" --idempotency-key "$key1" 2>&1); rc=$?
assert_rc "capture_raw_tamper_still_detected" 0 "$rc"
assert_contains "capture_raw_tamper_reencodes_equal" "$out" "no-op"

# reserved fields in staged input -> exit 2
f4=$(mktemp "$TMP/staged.XXXXXX")
{
  echo "---"
  echo "source: sess-1"
  echo "sensitivity: normal"
  echo "capture_id: forged"
  echo "proposed:"
  echo "  schema_version: \"1\""
  echo "  name: X"
  echo "  description: d"
  echo "  metadata:"
  echo "    type: project"
  echo "---"
  echo "body"
} > "$f4"
out=$(bash "$WRITER" capture --store "$cstore2" --staged "$f4" --idempotency-key "0000000000000000000000000000000000000000000000000000000000000000" 2>&1); rc=$?
assert_rc "capture_reserved_capture_id_rejected" 2 "$rc"

# unknown top-level field -> exit 2
f5=$(mktemp "$TMP/staged.XXXXXX")
{
  echo "---"
  echo "source: sess-1"
  echo "sensitivity: normal"
  echo "bogus_field: x"
  echo "proposed:"
  echo "  schema_version: \"1\""
  echo "  name: X"
  echo "  description: d"
  echo "  metadata:"
  echo "    type: project"
  echo "---"
  echo "body"
} > "$f5"
out=$(bash "$WRITER" capture --store "$cstore2" --staged "$f5" --idempotency-key "0000000000000000000000000000000000000000000000000000000000000000" 2>&1); rc=$?
assert_rc "capture_unknown_field_rejected" 2 "$rc"

# invalid sensitivity enum -> exit 2
f6=$(mktemp "$TMP/staged.XXXXXX")
{
  echo "---"
  echo "source: sess-1"
  echo "sensitivity: extreme"
  echo "proposed:"
  echo "  schema_version: \"1\""
  echo "  name: X"
  echo "  description: d"
  echo "  metadata:"
  echo "    type: project"
  echo "---"
  echo "body"
} > "$f6"
out=$(bash "$WRITER" capture --store "$cstore2" --staged "$f6" --idempotency-key "0000000000000000000000000000000000000000000000000000000000000000" 2>&1); rc=$?
assert_rc "capture_invalid_sensitivity_rejected" 2 "$rc"

# YAML lexical-subset violations -> exit 2 (anchors, flow lists, blank lines)
f7=$(mktemp "$TMP/staged.XXXXXX")
{
  echo "---"
  echo "source: sess-1"
  echo "sensitivity: normal"
  echo "proposed:"
  echo "  schema_version: \"1\""
  echo "  name: X"
  echo "  description: d"
  echo "  metadata:"
  echo "    type: project"
  echo "  tags: [a, b]"
  echo "---"
  echo "body"
} > "$f7"
out=$(bash "$WRITER" capture --store "$cstore2" --staged "$f7" --idempotency-key "0000000000000000000000000000000000000000000000000000000000000000" 2>&1); rc=$?
assert_rc "capture_flow_list_rejected" 2 "$rc"

f8=$(mktemp "$TMP/staged.XXXXXX")
printf -- '---\nsource: sess-1\nsensitivity: normal\n\nproposed:\n  schema_version: "1"\n  name: X\n  description: d\n  metadata:\n    type: project\n---\nbody\n' > "$f8"
out=$(bash "$WRITER" capture --store "$cstore2" --staged "$f8" --idempotency-key "0000000000000000000000000000000000000000000000000000000000000000" 2>&1); rc=$?
assert_rc "capture_blank_line_in_frontmatter_rejected" 2 "$rc"

# idempotency-key mismatch (planner passed wrong key) -> exit 2
out=$(bash "$WRITER" capture --store "$cstore2" --staged "$f2" --idempotency-key "1111111111111111111111111111111111111111111111111111111111111111" 2>&1); rc=$?
assert_rc "capture_key_mismatch_rejected" 2 "$rc"

# not-gitignored refusal
ngstore="$TMP/cap_not_ignored/.agents/memory"
new_repo "$TMP/cap_not_ignored"
mkdir -p "$ngstore"
touch "$ngstore/MEMORY.md"
chmod 700 "$ngstore"; chmod 600 "$ngstore/MEMORY.md"
(cd "$TMP/cap_not_ignored" && git add -A >/dev/null 2>&1; git commit -q -m x --allow-empty >/dev/null 2>&1)
out=$(bash "$WRITER" capture --store "$ngstore" --staged "$f2" --idempotency-key "$(mw_call "km_parse_capture '$f2' staged >/dev/null 2>&1 && km_capture_canonical_hash")" 2>&1); rc=$?
assert_rc "capture_not_gitignored_refused_exit4" 4 "$rc"

# ===========================================================================
# 6. memory-write.sh bootstrap
# ===========================================================================
echo "--- memory-write.sh bootstrap ---"

d="$TMP/boot_canonical"
new_repo "$d"
(cd "$d" && echo ".agents/memory/" >> .gitignore && git add .gitignore && git commit -q -m init)
out=$(bash "$WRITER" bootstrap --store "$d/.agents/memory" 2>&1); rc=$?
assert_rc "bootstrap_canonical_ancestor_creation_exit0" 0 "$rc"
assert_file_present "bootstrap_canonical_agents_dir_created" "$d/.agents"
assert_file_present "bootstrap_canonical_memory_md_created" "$d/.agents/memory/MEMORY.md"
out=$(bash "$WRITER" bootstrap --store "$d/.agents/memory" 2>&1); rc=$?
assert_rc "bootstrap_idempotent_reentry_exit0" 0 "$rc"
assert_contains "bootstrap_idempotent_message" "$out" "already initialized"

d="$TMP/boot_env_target"
new_repo "$d"
mkdir -p "$d/custom_parent"
(cd "$d" && echo "custom_parent/mystore/" >> .gitignore && git add .gitignore && git commit -q -m init)
out=$(KNOWLEDGE_MEMORY_HOME="$d/custom_parent/mystore" bash "$WRITER" bootstrap --store "$d/custom_parent/mystore" 2>&1); rc=$?
assert_rc "bootstrap_explicit_noncanonical_target_exit0" 0 "$rc"
assert_file_present "bootstrap_noncanonical_created" "$d/custom_parent/mystore/MEMORY.md"

d="$TMP/boot_unsafe_parent"
new_repo "$d"
(cd "$d" && echo "sub/target/" >> .gitignore && git add .gitignore && git commit -q -m init)
# parent "sub" does not exist and target is NOT the canonical default -> must fail closed
out=$(bash "$WRITER" bootstrap --store "$d/sub/target" 2>&1); rc=$?
assert_rc "bootstrap_missing_noncanonical_parent_exit4" 4 "$rc"

d="$TMP/boot_unsafe_existing"
new_repo "$d"
(cd "$d" && echo ".agents/memory/" >> .gitignore && git add .gitignore && git commit -q -m init)
mkdir -p "$d/.agents"
ln -s /etc "$d/.agents/memory"
out=$(bash "$WRITER" bootstrap --store "$d/.agents/memory" 2>&1); rc=$?
assert_rc "bootstrap_unsafe_preexisting_symlink_exit4" 4 "$rc"

d="$TMP/boot_reviewer"
new_repo "$d"
(cd "$d" && echo ".agents/memory/" >> .gitignore && git add .gitignore && git commit -q -m init)
out=$(KNOWLEDGE_PANE_NAME=fleet-reviewer bash "$WRITER" bootstrap --store "$d/.agents/memory" 2>&1); rc=$?
assert_rc "bootstrap_reviewer_refused_exit6" 6 "$rc"
assert_contains "bootstrap_reviewer_message" "$out" "reviewer role: memory writes refused"

d="$TMP/boot_unresolved_identity"
new_repo "$d"
(cd "$d" && echo ".agents/memory/" >> .gitignore && git add .gitignore && git commit -q -m init)
out=$(env -u KNOWLEDGE_PANE_NAME -u SESSION_CHAT_PANE_NAME TMUX=/fake/sock,1,1 bash "$WRITER" bootstrap --store "$d/.agents/memory" 2>&1); rc=$?
assert_rc "bootstrap_unresolved_fleet_identity_exit6" 6 "$rc"
assert_contains "bootstrap_unresolved_identity_message" "$out" "unresolved pane identity"

out=$(env -u KNOWLEDGE_PANE_NAME -u SESSION_CHAT_PANE_NAME -u TMUX bash "$WRITER" bootstrap --store "$d/.agents/memory" 2>&1); rc=$?
assert_rc "bootstrap_true_solo_no_tmux_proceeds" 0 "$rc"

d="$TMP/boot_not_ignored"
new_repo "$d"
out=$(bash "$WRITER" bootstrap --store "$d/.agents/memory" 2>&1); rc=$?
assert_rc "bootstrap_not_gitignored_refused_exit3" 3 "$rc"

# ===========================================================================
# 7. memory-write.sh apply / retire / index (end to end + CAS)
# ===========================================================================
echo "--- memory-write.sh apply/retire/index ---"

store=$(bootstrap_store "$TMP/txn_basic")
key=$(capture_synthetic "$store" "sess-x" "Redis TLS Incident" "TLS handshake fix" project)
write_canonical "$TMP/txn_target1.md" project "Redis TLS Incident" "TLS handshake fix"
printf -- '- [Redis TLS Incident](redis_tls.md) -- TLS handshake fix\n' > "$TMP/txn_index1.md"
expect_index=$(sha_of "$store/MEMORY.md")
expect_cand=$(sha_of "$store/.inbox/${key}.md")
out=$(bash "$WRITER" apply --store "$store" --target redis_tls.md \
  --staged-target "$TMP/txn_target1.md" --staged-index "$TMP/txn_index1.md" \
  --expect-target absent --expect-index "$expect_index" \
  --candidate "$key" --expect-candidate "$expect_cand" 2>&1); rc=$?
assert_rc "apply_basic_exit0" 0 "$rc"
assert_file_present "apply_created_target" "$store/redis_tls.md"
assert_file_absent "apply_consumed_candidate" "$store/.inbox/${key}.md"
assert_clean_store "apply_basic_no_leftovers" "$store"

# apply's candidate CAS is the RAW hash of the whole stored candidate file
# (not the semantic capture key), specifically so it catches BOTH tamper
# classes: (a) a semantic change (also changes the capture key) and (b) a
# change limited to a writer-generated field (same semantic key, different
# raw bytes) -- the semantic key alone would miss class (b).
tstore=$(bootstrap_store "$TMP/txn_candidate_tamper")
tkey=$(capture_synthetic "$tstore" "sess-t" "Tamper Target" "fixture" project)
write_canonical "$TMP/txn_tamper_target.md" project "Tamper Target" "fixture"
printf -- '- [Tamper Target](tamper_target.md) -- fixture\n' > "$TMP/txn_tamper_index.md"
ei=$(sha_of "$tstore/MEMORY.md")
ec_original=$(sha_of "$tstore/.inbox/${tkey}.md")
# class (a): semantic tamper -- edit the proposed name in the stored candidate
sed -i.bak 's/Tamper Target/Tamper Target CHANGED/' "$tstore/.inbox/${tkey}.md"
rm -f "$tstore/.inbox/${tkey}.md.bak"
out=$(bash "$WRITER" apply --store "$tstore" --target tamper_target.md \
  --staged-target "$TMP/txn_tamper_target.md" --staged-index "$TMP/txn_tamper_index.md" \
  --expect-target absent --expect-index "$ei" --candidate "$tkey" --expect-candidate "$ec_original" 2>&1); rc=$?
assert_rc "apply_candidate_semantic_tamper_rejected_exit4" 4 "$rc"
assert_file_absent "apply_candidate_semantic_tamper_no_partial_write" "$tstore/tamper_target.md"
assert_file_present "apply_candidate_semantic_tamper_candidate_retained" "$tstore/.inbox/${tkey}.md"
assert_clean_store "apply_candidate_semantic_tamper_no_leftovers" "$tstore"

# class (b): writer-field-only tamper -- edit ONLY the writer-stamped
# `created:` timestamp, which the semantic capture key by design excludes.
# --expect-candidate is the RAW hash, so this must still be caught even
# though the semantic key would not have changed.
tstore2=$(bootstrap_store "$TMP/txn_candidate_tamper2")
tkey2=$(capture_synthetic "$tstore2" "sess-t2" "Tamper Target 2" "fixture" project)
ei2=$(sha_of "$tstore2/MEMORY.md")
ec2_original=$(sha_of "$tstore2/.inbox/${tkey2}.md")
sed -i.bak 's/^created: .*/created: 2020-01-01T00:00:00Z/' "$tstore2/.inbox/${tkey2}.md"
rm -f "$tstore2/.inbox/${tkey2}.md.bak"
out=$(bash "$WRITER" apply --store "$tstore2" --target tamper_target2.md \
  --staged-target "$TMP/txn_tamper_target.md" --staged-index "$TMP/txn_tamper_index.md" \
  --expect-target absent --expect-index "$ei2" --candidate "$tkey2" --expect-candidate "$ec2_original" 2>&1); rc=$?
assert_rc "apply_candidate_writer_field_tamper_rejected_exit4" 4 "$rc"
assert_file_present "apply_candidate_writer_field_tamper_retained" "$tstore2/.inbox/${tkey2}.md"

# stale expect-index (CAS) -> exit4, nothing changed
write_canonical "$TMP/txn_target2.md" project "Second" "second"
printf -- '- [Second](second.md) -- second\n' > "$TMP/txn_index2.md"
out=$(bash "$WRITER" apply --store "$store" --target second.md \
  --staged-target "$TMP/txn_target2.md" --staged-index "$TMP/txn_index2.md" \
  --expect-target absent --expect-index "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" 2>&1); rc=$?
assert_rc "apply_stale_index_hash_rejected_exit4" 4 "$rc"
assert_file_absent "apply_stale_index_no_partial_write" "$store/second.md"
assert_clean_store "apply_stale_index_no_leftovers" "$store"

# stale expect-target (legacy update path) -> exit4
expect_index=$(sha_of "$store/MEMORY.md")
out=$(bash "$WRITER" apply --store "$store" --target redis_tls.md \
  --staged-target "$TMP/txn_target2.md" --staged-index "$TMP/txn_index2.md" \
  --expect-target "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" --expect-index "$expect_index" 2>&1); rc=$?
assert_rc "apply_stale_target_hash_rejected_exit4" 4 "$rc"

# reserved / invalid target names
out=$(bash "$WRITER" apply --store "$store" --target MEMORY.md --staged-target "$TMP/txn_target2.md" --staged-index "$TMP/txn_index2.md" --expect-target absent --expect-index x 2>&1); rc=$?
assert_rc "apply_reserved_memory_md_rejected_exit2" 2 "$rc"
out=$(bash "$WRITER" apply --store "$store" --target ".hidden.md" --staged-target "$TMP/txn_target2.md" --staged-index "$TMP/txn_index2.md" --expect-target absent --expect-index x 2>&1); rc=$?
assert_rc "apply_dotfile_target_rejected_exit2" 2 "$rc"
out=$(bash "$WRITER" apply --store "$store" --target "../escape.md" --staged-target "$TMP/txn_target2.md" --staged-index "$TMP/txn_index2.md" --expect-target absent --expect-index x 2>&1); rc=$?
assert_rc "apply_traversal_target_rejected_exit2" 2 "$rc"
out=$(bash "$WRITER" apply --store "$store" --target "Not A Slug.md" --staged-target "$TMP/txn_target2.md" --staged-index "$TMP/txn_index2.md" --expect-target absent --expect-index x 2>&1); rc=$?
assert_rc "apply_invalid_slug_new_file_rejected_exit2" 2 "$rc"

# legacy update: exact-stem match to an existing non-canonical-slug file is allowed
legacystore=$(bootstrap_store "$TMP/txn_legacy_update")
cat > "$legacystore/Legacy-Name.md" <<'EOF'
---
type: project
name: Legacy
---
old content
EOF
echo "- [Legacy](Legacy-Name.md) -- legacy" > "$legacystore/MEMORY.md"
chmod 600 "$legacystore"/*.md
et=$(sha_of "$legacystore/Legacy-Name.md")
ei=$(sha_of "$legacystore/MEMORY.md")
cat > "$TMP/legacy_updated.md" <<'EOF'
---
type: project
name: Legacy
---
updated content
EOF
out=$(bash "$WRITER" apply --store "$legacystore" --target "Legacy-Name.md" --staged-target "$TMP/legacy_updated.md" --staged-index "$legacystore/MEMORY.md" --expect-target "$et" --expect-index "$ei" 2>&1); rc=$?
assert_rc "apply_legacy_exact_stem_update_exit0" 0 "$rc"

# slug collision gating on apply
colstore=$(bootstrap_store "$TMP/txn_collision")
write_canonical "$colstore/foo_bar.md" project "A" "a"
cp "$colstore/foo_bar.md" "$colstore/foo-bar.md"
chmod 600 "$colstore"/*.md
echo "- [A](foo_bar.md) -- a" > "$colstore/MEMORY.md"
echo "- [A2](foo-bar.md) -- a2" >> "$colstore/MEMORY.md"
out=$(bash "$WRITER" apply --store "$colstore" --target new_item.md --staged-target "$TMP/txn_target2.md" --staged-index "$colstore/MEMORY.md" --expect-target absent --expect-index x 2>&1); rc=$?
assert_rc "apply_slug_collision_gated_exit4" 4 "$rc"

# retire: real file, then exact-stem-only resolution (no normalized fallback)
store2=$(bootstrap_store "$TMP/txn_retire")
key2=$(capture_synthetic "$store2" "sess-y" "Retire Me" "will be retired" project)
write_canonical "$TMP/txn_target3.md" project "Retire Me" "will be retired"
printf -- '- [Retire Me](retire_me.md) -- x\n' > "$TMP/txn_index3.md"
ei=$(sha_of "$store2/MEMORY.md")
ec=$(sha_of "$store2/.inbox/${key2}.md")
bash "$WRITER" apply --store "$store2" --target retire_me.md --staged-target "$TMP/txn_target3.md" --staged-index "$TMP/txn_index3.md" --expect-target absent --expect-index "$ei" --candidate "$key2" --expect-candidate "$ec" > /dev/null
et=$(sha_of "$store2/retire_me.md")
ei=$(sha_of "$store2/MEMORY.md")
printf '' > "$TMP/txn_empty_index.md"
out=$(bash "$WRITER" retire --store "$store2" --slug retire_me --staged-index "$TMP/txn_empty_index.md" --expect-target "$et" --expect-index "$ei" --confirm "$store2" 2>&1); rc=$?
assert_rc "retire_basic_exit0" 0 "$rc"
assert_file_absent "retire_removed_file" "$store2/retire_me.md"
assert_clean_store "retire_no_leftovers" "$store2"

out=$(bash "$WRITER" retire --store "$store2" --slug retire_me --staged-index "$TMP/txn_empty_index.md" --expect-target "$et" --expect-index "$ei" --confirm "$store2/" 2>&1); rc=$?
assert_rc "retire_confirm_mismatch_rejected_exit2" 2 "$rc"

# retire missing --confirm value entirely
out=$(bash "$WRITER" retire --store "$store2" --slug retire_me --staged-index "$TMP/txn_empty_index.md" --expect-target "$et" --expect-index "$ei" 2>&1); rc=$?
assert_rc "retire_missing_confirm_rejected_exit2" 2 "$rc"

# standalone index repair (no target leg touched)
istore2=$(bootstrap_store "$TMP/txn_index_repair")
ei=$(sha_of "$istore2/MEMORY.md")
printf -- '- [Nothing](nothing.md) -- placeholder note only\n' > "$TMP/txn_new_index.md"
out=$(bash "$WRITER" index --store "$istore2" --staged-index "$TMP/txn_new_index.md" --expect-index "$ei" 2>&1); rc=$?
assert_rc "index_repair_exit0" 0 "$rc"
grep -q "Nothing" "$istore2/MEMORY.md" && pass "index_repair_content_installed" || fail "index_repair_content_installed" "not installed"
assert_clean_store "index_repair_no_leftovers" "$istore2"

# ===========================================================================
# 8. Kill-point recovery (die at each numbered step; recovery sub-steps)
# ===========================================================================
echo "--- kill-point recovery ---"

# helper: set up a fresh store with a candidate ready to apply; returns store path via stdout
setup_kill_scenario() {
  local d="$1" store key
  store=$(bootstrap_store "$d")
  key=$(capture_synthetic "$store" "sess-k" "Kill Point Item" "kill point fixture" project)
  printf '%s\n' "$store"
  printf '%s\n' "$key" >&2
}

trigger_recovery_noop() {
  # runs a self-consistent index no-op call to force sweep+recovery, without
  # otherwise mutating the store; propagates its exit code
  local store="$1" cur
  cur=$(sha_of "$store/MEMORY.md")
  bash "$WRITER" index --store "$store" --staged-index "$store/MEMORY.md" --expect-index "$cur"
}

for step in 2 3 4 5 6 7 8 9 10; do
  d="$TMP/kill_step_$step"
  store=$(bootstrap_store "$d")
  key=$(capture_synthetic "$store" "sess-k$step" "Kill Item $step" "fixture" project)
  write_canonical "$TMP/kill_target_$step.md" project "Kill Item $step" "fixture"
  printf -- '- [Kill Item %s](kill_item_%s.md) -- fixture\n' "$step" "$step" > "$TMP/kill_index_$step.md"
  ei=$(sha_of "$store/MEMORY.md")
  ec=$(sha_of "$store/.inbox/${key}.md")
  KNOWLEDGE_TEST_DIE_AT_STEP="$step" bash "$WRITER" apply --store "$store" --target "kill_item_${step}.md" \
    --staged-target "$TMP/kill_target_$step.md" --staged-index "$TMP/kill_index_$step.md" \
    --expect-target absent --expect-index "$ei" --candidate "$key" --expect-candidate "$ec" > /dev/null 2>&1
  rc=$?
  assert_rc "kill_step_${step}_dies_137" 137 "$rc"

  bash "$WRITER" unlock --store "$store" --confirm "$store" > /dev/null 2>&1
  trigger_recovery_noop "$store" > /dev/null 2>&1
  rc=$?
  assert_rc "kill_step_${step}_recovery_exit0" 0 "$rc"
  assert_clean_store "kill_step_${step}_clean_after_recovery" "$store"

  # Steps 2-5: neither leg mutated yet -> rollback is a no-op restore, both
  # legs absent/original. Step 6: target renamed but MEMORY.md is not yet
  # (that is step 7) -> the index leg still fails the AFTER-match check, so
  # recovery rolls BACK (undoing the target rename too). From step 7 on,
  # BOTH legs already match AFTER by the time the die-hook fires, so
  # recovery's "committed" check is satisfied and it rolls FORWARD instead
  # (spec: "die in 6-8 -> rolls back ... unless both files already match
  # AFTER, in which case it rolls forward").
  if [ "$step" -le 6 ]; then
    assert_file_absent "kill_step_${step}_target_rolled_back" "$store/kill_item_${step}.md"
    assert_file_present "kill_step_${step}_candidate_retained" "$store/.inbox/${key}.md"
  else
    assert_file_present "kill_step_${step}_target_committed" "$store/kill_item_${step}.md"
    assert_file_absent "kill_step_${step}_candidate_consumed" "$store/.inbox/${key}.md"
  fi
done

# recovery sub-step kills: rollback branch (reach via die-at-6) and forward
# branch (reach via die-at-8), then interrupt recovery itself.
for point in rollback:pre-target rollback:pre-index rollback:pre-verify rollback:pre-cleanup; do
  label=$(printf '%s' "$point" | tr ':-' '__')
  d="$TMP/kill_recovery_$label"
  store=$(bootstrap_store "$d")
  key=$(capture_synthetic "$store" "sess-r-$label" "Recovery Item $label" "fixture" project)
  write_canonical "$TMP/rec_target_$label.md" project "Recovery Item $label" "fixture"
  printf -- '- [Recovery Item %s](rec_item_%s.md) -- fixture\n' "$label" "$label" > "$TMP/rec_index_$label.md"
  ei=$(sha_of "$store/MEMORY.md")
  ec=$(sha_of "$store/.inbox/${key}.md")
  KNOWLEDGE_TEST_DIE_AT_STEP=6 bash "$WRITER" apply --store "$store" --target "rec_item_${label}.md" \
    --staged-target "$TMP/rec_target_$label.md" --staged-index "$TMP/rec_index_$label.md" \
    --expect-target absent --expect-index "$ei" --candidate "$key" --expect-candidate "$ec" > /dev/null 2>&1
  bash "$WRITER" unlock --store "$store" --confirm "$store" > /dev/null 2>&1

  KNOWLEDGE_TEST_DIE_AT_RECOVERY_POINT="$point" bash -c "
    source '$WRITER'
    _km_lock_acquire '$store' || exit 9
    _km_run_recovery '$store'
  " > /dev/null 2>&1
  rc=$?
  assert_rc "kill_recovery_${label}_dies_137" 137 "$rc"
  assert_file_present "kill_recovery_${label}_journal_still_present" "$store/.journal"

  # release the lock the interrupted attempt left behind, then let recovery
  # actually finish (idempotent across the earlier partial attempt).
  rm -f "$store/.lock" "$store"/.lock.claim.* 2>/dev/null
  trigger_recovery_noop "$store" > /dev/null 2>&1
  rc=$?
  assert_rc "kill_recovery_${label}_completes_exit0" 0 "$rc"
  assert_clean_store "kill_recovery_${label}_clean" "$store"
  assert_file_absent "kill_recovery_${label}_target_rolled_back" "$store/rec_item_${label}.md"
  assert_file_present "kill_recovery_${label}_candidate_retained" "$store/.inbox/${key}.md"
done

for point in forward:pre-candidate forward:pre-cleanup; do
  label=$(printf '%s' "$point" | tr ':-' '__')
  d="$TMP/kill_recovery_$label"
  store=$(bootstrap_store "$d")
  key=$(capture_synthetic "$store" "sess-f-$label" "Forward Item $label" "fixture" project)
  write_canonical "$TMP/fwd_target_$label.md" project "Forward Item $label" "fixture"
  printf -- '- [Forward Item %s](fwd_item_%s.md) -- fixture\n' "$label" "$label" > "$TMP/fwd_index_$label.md"
  ei=$(sha_of "$store/MEMORY.md")
  ec=$(sha_of "$store/.inbox/${key}.md")
  KNOWLEDGE_TEST_DIE_AT_STEP=8 bash "$WRITER" apply --store "$store" --target "fwd_item_${label}.md" \
    --staged-target "$TMP/fwd_target_$label.md" --staged-index "$TMP/fwd_index_$label.md" \
    --expect-target absent --expect-index "$ei" --candidate "$key" --expect-candidate "$ec" > /dev/null 2>&1
  bash "$WRITER" unlock --store "$store" --confirm "$store" > /dev/null 2>&1

  KNOWLEDGE_TEST_DIE_AT_RECOVERY_POINT="$point" bash -c "
    source '$WRITER'
    _km_lock_acquire '$store' || exit 9
    _km_run_recovery '$store'
  " > /dev/null 2>&1
  rc=$?
  assert_rc "kill_recovery_${label}_dies_137" 137 "$rc"
  assert_file_present "kill_recovery_${label}_journal_still_present" "$store/.journal"

  rm -f "$store/.lock" "$store"/.lock.claim.* 2>/dev/null
  trigger_recovery_noop "$store" > /dev/null 2>&1
  rc=$?
  assert_rc "kill_recovery_${label}_completes_exit0" 0 "$rc"
  assert_clean_store "kill_recovery_${label}_clean" "$store"
  assert_file_present "kill_recovery_${label}_target_committed" "$store/fwd_item_${label}.md"
  assert_file_absent "kill_recovery_${label}_candidate_consumed" "$store/.inbox/${key}.md"
done

# ===========================================================================
# 9. Locking: contention, paused-owner interleavings, unlock
# ===========================================================================
echo "--- locking ---"

store=$(bootstrap_store "$TMP/lock_contend")
(
  bash -c "
    source '$WRITER'
    _km_lock_acquire '$store' || exit 9
    sleep 2
  "
) &
holder_pid=$!
sleep 0.3
cur_index_hash=$(sha_of "$store/MEMORY.md")
out=$(KNOWLEDGE_TEST_LOCK_RETRY_MAX=5 KNOWLEDGE_TEST_LOCK_RETRY_DELAY=0.1 \
  bash "$WRITER" index --store "$store" --staged-index "$store/MEMORY.md" --expect-index "$cur_index_hash" 2>&1); rc=$?
assert_rc "lock_contention_exit5" 5 "$rc"
assert_contains "lock_contention_message" "$out" "store locked:"
assert_contains "lock_contention_prints_unlock_cmd" "$out" "memory-write.sh unlock --store"
wait "$holder_pid" 2>/dev/null || true
bash "$WRITER" unlock --store "$store" --confirm "$store" > /dev/null 2>&1

# concurrent writers serialize without corruption: launch N apply calls for
# DISTINCT new files against the SAME store concurrently; all must land and
# MEMORY.md must end up listing every one exactly once.
cstore3=$(bootstrap_store "$TMP/lock_concurrent")
n=5
pids=()
for i in $(seq 1 "$n"); do
  (
    write_canonical "$TMP/conc_target_$i.md" project "Concurrent $i" "fixture $i"
    tries=0
    while :; do
      ei=$(sha_of "$cstore3/MEMORY.md")
      # Build the new index content by appending our row to the CURRENT file
      # at apply time, retried on CAS mismatch (this IS the expected
      # multi-writer usage pattern -- planners re-read and retry).
      cp "$cstore3/MEMORY.md" "$TMP/conc_index_$i.md"
      printf -- '- [Concurrent %s](concurrent_%s.md) -- fixture %s\n' "$i" "$i" "$i" >> "$TMP/conc_index_$i.md"
      if bash "$WRITER" apply --store "$cstore3" --target "concurrent_${i}.md" \
        --staged-target "$TMP/conc_target_$i.md" --staged-index "$TMP/conc_index_$i.md" \
        --expect-target absent --expect-index "$ei" > /dev/null 2>&1; then
        break
      fi
      tries=$((tries + 1))
      [ "$tries" -ge 50 ] && break
      sleep 0.05
    done
  ) &
  pids+=("$!")
done
for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done
allok=1
for i in $(seq 1 "$n"); do
  [ -f "$cstore3/concurrent_${i}.md" ] || allok=0
  cnt=$(grep -c "concurrent_${i}.md" "$cstore3/MEMORY.md")
  [ "$cnt" = "1" ] || allok=0
done
[ "$allok" = "1" ] && pass "lock_concurrent_writers_all_land_no_corruption" || fail "lock_concurrent_writers_all_land_no_corruption" "$(cat "$cstore3/MEMORY.md")"
assert_clean_store "lock_concurrent_no_leftovers" "$cstore3"

# unlock: alive-holder refusal, dead-holder success, post-unlock acquisition
store=$(bootstrap_store "$TMP/unlock_alive")
(
  bash -c "
    source '$WRITER'
    _km_lock_acquire '$store' || exit 9
    sleep 2
  "
) &
holder_pid=$!
sleep 0.3
out=$(bash "$WRITER" unlock --store "$store" --confirm "$store" 2>&1); rc=$?
assert_rc "unlock_alive_holder_refused_exit5" 5 "$rc"
assert_contains "unlock_alive_holder_message" "$out" "lock holder is alive"
wait "$holder_pid" 2>/dev/null || true
out=$(bash "$WRITER" unlock --store "$store" --confirm "$store" 2>&1); rc=$?
assert_rc "unlock_after_holder_exit_removes_lock" 0 "$rc"

store=$(bootstrap_store "$TMP/unlock_dead")
key=$(capture_synthetic "$store" "sess-d" "Dead Lock Item" "fixture" project)
write_canonical "$TMP/dead_target.md" project "Dead Lock Item" "fixture"
printf -- '- [Dead Lock Item](dead_item.md) -- fixture\n' > "$TMP/dead_index.md"
ei=$(sha_of "$store/MEMORY.md")
ec=$(sha_of "$store/.inbox/${key}.md")
KNOWLEDGE_TEST_DIE_AT_STEP=6 bash "$WRITER" apply --store "$store" --target dead_item.md \
  --staged-target "$TMP/dead_target.md" --staged-index "$TMP/dead_index.md" \
  --expect-target absent --expect-index "$ei" --candidate "$key" --expect-candidate "$ec" > /dev/null 2>&1
out=$(bash "$WRITER" unlock --store "$store" --confirm "$store" 2>&1); rc=$?
assert_rc "unlock_dead_holder_succeeds_exit0" 0 "$rc"
assert_contains "unlock_dead_holder_message" "$out" "dead lock holder"
assert_file_absent "unlock_dead_holder_lock_removed" "$store/.lock"
trigger_recovery_noop "$store" > /dev/null 2>&1
# post-unlock acquisition: a fresh writer can now proceed normally
ei=$(sha_of "$store/MEMORY.md")
printf -- '- [Extra](extra.md) -- e\n' > "$TMP/extra_index.md"
cat "$store/MEMORY.md" >> "$TMP/extra_index.md" 2>/dev/null || true
write_canonical "$TMP/extra_target.md" project "Extra" "e"
out=$(bash "$WRITER" apply --store "$store" --target extra.md --staged-target "$TMP/extra_target.md" --staged-index "$TMP/extra_index.md" --expect-target absent --expect-index "$ei" 2>&1); rc=$?
assert_rc "unlock_post_unlock_acquisition_succeeds" 0 "$rc"

# unlock with no lock present -- idempotent, reports orphaned claims if any
store=$(bootstrap_store "$TMP/unlock_none")
out=$(bash "$WRITER" unlock --store "$store" --confirm "$store" 2>&1); rc=$?
assert_rc "unlock_no_lock_present_exit0" 0 "$rc"
assert_contains "unlock_no_lock_present_message" "$out" "no lock present"

# ===========================================================================
# 10. purge: plan/apply, manifest CAS, re-plan, reviewer refusal
# ===========================================================================
echo "--- purge ---"

store=$(bootstrap_store "$TMP/purge_basic")
k1=$(capture_synthetic "$store" "sess-p1" "Purge A" "a" project)
k2=$(capture_synthetic "$store" "sess-p2" "Purge B" "b" project)

out=$(KNOWLEDGE_INBOX_RETENTION_DAYS=30 bash "$WRITER" purge --store "$store" --expired 2>&1); rc=$?
assert_rc "purge_plan_nothing_expired_exit0" 0 "$rc"
[ -z "$out" ] && pass "purge_plan_nothing_expired_empty" || fail "purge_plan_nothing_expired_empty" "$out"

KNOWLEDGE_INBOX_RETENTION_DAYS=0 bash "$WRITER" purge --store "$store" --expired > "$TMP/purge_plan1.txt"
lines=$(wc -l < "$TMP/purge_plan1.txt" | tr -d ' ')
[ "$lines" = "2" ] && pass "purge_plan_expired_lists_both" || fail "purge_plan_expired_lists_both" "lines=$lines"

out=$(KNOWLEDGE_INBOX_RETENTION_DAYS=0 bash "$WRITER" purge --store "$store" --expired --manifest "$TMP/purge_plan1.txt" --confirm "$store" 2>&1); rc=$?
assert_rc "purge_apply_expired_exit0" 0 "$rc"
assert_file_absent "purge_apply_removed_k1" "$store/.inbox/${k1}.md"
assert_file_absent "purge_apply_removed_k2" "$store/.inbox/${k2}.md"

# --ids selector plan+apply
k3=$(capture_synthetic "$store" "sess-p3" "Purge C" "c" project)
bash "$WRITER" purge --store "$store" --ids "$k3" > "$TMP/purge_plan2.txt"
out=$(bash "$WRITER" purge --store "$store" --ids "$k3" --manifest "$TMP/purge_plan2.txt" --confirm "$store" 2>&1); rc=$?
assert_rc "purge_ids_apply_exit0" 0 "$rc"
assert_file_absent "purge_ids_removed" "$store/.inbox/${k3}.md"

# manifest validation errors
k4=$(capture_synthetic "$store" "sess-p4" "Purge D" "d" project)
raw4=$(sha_of "$store/.inbox/${k4}.md")
printf '%s %s 2026-01-01T00:00:00Z active\n%s %s 2026-01-01T00:00:00Z active\n' "$k4" "$raw4" "$k4" "$raw4" > "$TMP/purge_dup.txt"
out=$(bash "$WRITER" purge --store "$store" --ids "$k4" --manifest "$TMP/purge_dup.txt" --confirm "$store" 2>&1); rc=$?
assert_rc "purge_manifest_duplicate_id_rejected_exit2" 2 "$rc"

printf '%s %s 2026-01-01T00:00:00Z active\n\n' "$k4" "$raw4" > "$TMP/purge_blank.txt"
out=$(bash "$WRITER" purge --store "$store" --ids "$k4" --manifest "$TMP/purge_blank.txt" --confirm "$store" 2>&1); rc=$?
assert_rc "purge_manifest_blank_line_rejected_exit2" 2 "$rc"

printf '%s %s 2026-01-01T00:00:00Z bogus\n' "$k4" "$raw4" > "$TMP/purge_badverdict.txt"
out=$(bash "$WRITER" purge --store "$store" --ids "$k4" --manifest "$TMP/purge_badverdict.txt" --confirm "$store" 2>&1); rc=$?
assert_rc "purge_manifest_bad_verdict_rejected_exit2" 2 "$rc"

# both/neither selector -> exit 2; missing --confirm on apply -> exit 2
out=$(bash "$WRITER" purge --store "$store" --ids "$k4" --expired 2>&1); rc=$?
assert_rc "purge_both_selectors_rejected_exit2" 2 "$rc"
out=$(bash "$WRITER" purge --store "$store" 2>&1); rc=$?
assert_rc "purge_no_selector_rejected_exit2" 2 "$rc"
out=$(bash "$WRITER" purge --store "$store" --ids "$k4" --manifest "$TMP/purge_plan2.txt" 2>&1); rc=$?
assert_rc "purge_apply_missing_confirm_rejected_exit2" 2 "$rc"

# still-expired recheck: plan under retention=0 (expired), apply under a much
# larger retention (recomputes as active) -> fails closed, re-plan required
k5=$(capture_synthetic "$store" "sess-p5" "Purge E" "e" project)
KNOWLEDGE_INBOX_RETENTION_DAYS=0 bash "$WRITER" purge --store "$store" --expired > "$TMP/purge_plan5.txt"
out=$(KNOWLEDGE_INBOX_RETENTION_DAYS=99999 bash "$WRITER" purge --store "$store" --expired --manifest "$TMP/purge_plan5.txt" --confirm "$store" 2>&1); rc=$?
assert_rc "purge_still_expired_recheck_fails_closed_exit4" 4 "$rc"
assert_file_present "purge_still_expired_recheck_retained" "$store/.inbox/${k5}.md"

# prefix-interruption re-plan: two candidates validate cleanly, but the
# process is KILLED (KNOWLEDGE_TEST_DIE_AFTER_PURGE_ID) right after the
# first unlink completes -- an interruption, not a validation failure. The
# prefix already unlinked stays purged; re-running PLAN reflects exactly
# what remains (the second candidate only), recoverable by applying a
# fresh manifest for it.
k6=$(capture_synthetic "$store" "sess-p6" "Purge F1" "f1" project)
k7=$(capture_synthetic "$store" "sess-p7" "Purge F2" "f2" project)
KNOWLEDGE_INBOX_RETENTION_DAYS=0 bash "$WRITER" purge --store "$store" --ids "$k6,$k7" > "$TMP/purge_plan_prefix.txt"
sort -o "$TMP/purge_plan_prefix.txt" "$TMP/purge_plan_prefix.txt"
first_id=$(head -1 "$TMP/purge_plan_prefix.txt" | awk '{print $1}')
second_id=$(tail -1 "$TMP/purge_plan_prefix.txt" | awk '{print $1}')
KNOWLEDGE_INBOX_RETENTION_DAYS=0 KNOWLEDGE_TEST_DIE_AFTER_PURGE_ID="$first_id" \
  bash "$WRITER" purge --store "$store" --ids "$k6,$k7" --manifest "$TMP/purge_plan_prefix.txt" --confirm "$store" > /dev/null 2>&1
rc=$?
assert_rc "purge_prefix_interruption_dies_137" 137 "$rc"
assert_file_absent "purge_prefix_first_purged" "$store/.inbox/${first_id}.md"
assert_file_present "purge_prefix_second_retained" "$store/.inbox/${second_id}.md"
# an interrupted purge leaves the same dead-holder lock a killed transaction
# would; clear it via the confirmed unlock subcommand before re-planning.
bash "$WRITER" unlock --store "$store" --confirm "$store" > /dev/null 2>&1
# re-plan sees only the still-present (un-purged) second candidate
out=$(bash "$WRITER" purge --store "$store" --ids "$second_id" 2>&1)
assert_contains "purge_prefix_replan_reflects_state" "$out" "$second_id"
bash "$WRITER" purge --store "$store" --ids "$second_id" > "$TMP/purge_plan_prefix2.txt"
out=$(bash "$WRITER" purge --store "$store" --ids "$second_id" --manifest "$TMP/purge_plan_prefix2.txt" --confirm "$store" 2>&1); rc=$?
assert_rc "purge_prefix_replan_apply_completes_exit0" 0 "$rc"
assert_file_absent "purge_prefix_replan_apply_purged" "$store/.inbox/${second_id}.md"

# reviewer refusal on purge
out=$(KNOWLEDGE_PANE_NAME=fleet-reviewer bash "$WRITER" purge --store "$store" --expired 2>&1); rc=$?
assert_rc "purge_reviewer_refused_exit6" 6 "$rc"

# ===========================================================================
# 11. Security audit: argv containment (retire --slug traversal, purge
#     --ids format) and duplicate-flag rejection ahead of role/store guards.
#     Regression coverage for a release-gating peer-review finding: retire
#     --slug was passed unvalidated into the transaction, and
#     `$store/../victim.md` deleted a file OUTSIDE the store.
# ===========================================================================
echo "--- security: argv containment + duplicate-flag rejection ---"

secstore=$(bootstrap_store "$TMP/sec_retire")
secrepo="$TMP/sec_retire"
echo "victim one level up" > "$secrepo/.agents/victim_one_up.md"
echo "victim two levels up" > "$secrepo/victim_two_up.md"
write_canonical "$secstore/real_item.md" project "Real Item" "the only legitimate retire target"
printf -- '- [Real Item](real_item.md) -- x\n' > "$secstore/MEMORY.md"
chmod 600 "$secstore"/*.md
ln -s /etc/hosts "$secstore/evil_link.md"

sec_before_hash=$(tree_hash "$secrepo")
et_dummy=$(sha_of "$secstore/real_item.md")
ei_dummy=$(sha_of "$secstore/MEMORY.md")

# Each of these slugs must be rejected WITHOUT deleting anything, regardless
# of whether the caller can produce a matching --expect-target hash for the
# escape target (a real attacker who can read the victim file can compute
# its hash too, so the fix must not rely on the CAS check as the backstop).
run_retire_attack() {
  local label="$1" slug="$2" expect_target="$3" expect_index="$4"
  out=$(bash "$WRITER" retire --store "$secstore" --slug "$slug" --staged-index "$TMP/emptyidx_sec.md" \
    --expect-target "$expect_target" --expect-index "$expect_index" --confirm "$secstore" 2>&1)
  rc=$?
  printf '%s\n' "$rc"
}
printf '' > "$TMP/emptyidx_sec.md"

et_one_up=$(sha_of "$secrepo/.agents/victim_one_up.md")
rc=$(run_retire_attack "one_up" "../victim_one_up" "$et_one_up" "$ei_dummy")
assert_rc "retire_traversal_one_up_rejected_exit2" 2 "$rc"
assert_file_present "retire_traversal_one_up_victim_survives" "$secrepo/.agents/victim_one_up.md"

et_two_up=$(sha_of "$secrepo/victim_two_up.md")
rc=$(run_retire_attack "two_up" "../../victim_two_up" "$et_two_up" "$ei_dummy")
assert_rc "retire_traversal_two_up_rejected_exit2" 2 "$rc"
assert_file_present "retire_traversal_two_up_victim_survives" "$secrepo/victim_two_up.md"

rc=$(run_retire_attack "embedded_slash" "a/b" "$et_dummy" "$ei_dummy")
assert_rc "retire_traversal_embedded_slash_rejected_exit2" 2 "$rc"

rc=$(run_retire_attack "absolute" "/etc/passwd" "$et_dummy" "$ei_dummy")
assert_rc "retire_traversal_absolute_rejected_exit2" 2 "$rc"

rc=$(run_retire_attack "dot" "." "$et_dummy" "$ei_dummy")
assert_rc "retire_traversal_dot_rejected_exit2" 2 "$rc"

rc=$(run_retire_attack "dotdot" ".." "$et_dummy" "$ei_dummy")
assert_rc "retire_traversal_dotdot_rejected_exit2" 2 "$rc"

rc=$(run_retire_attack "dot_prefixed" ".hidden" "$et_dummy" "$ei_dummy")
assert_rc "retire_dot_prefixed_reserved_rejected_exit2" 2 "$rc"

rc=$(run_retire_attack "memory_stem" "MEMORY" "$et_dummy" "$ei_dummy")
assert_rc "retire_memory_stem_reserved_rejected_exit2" 2 "$rc"

rc=$(run_retire_attack "nonexistent" "does_not_exist" "$et_dummy" "$ei_dummy")
assert_rc "retire_nonexistent_stem_rejected_exit2" 2 "$rc"

et_evil=$(sha_of "$secstore/evil_link.md" 2>/dev/null || echo "x")
rc=$(run_retire_attack "symlink_target" "evil_link" "$et_evil" "$ei_dummy")
assert_rc "retire_symlink_target_rejected_exit4" 4 "$rc"

sec_after_hash=$(tree_hash "$secrepo")
[ "$sec_before_hash" = "$sec_after_hash" ] && pass "retire_traversal_repo_byte_identical" || fail "retire_traversal_repo_byte_identical" "repo tree changed"
assert_file_present "retire_traversal_real_item_untouched" "$secstore/real_item.md"
rm -f "$secstore/evil_link.md"

# legit retire still works (proves the fix isn't over-broad)
et_real=$(sha_of "$secstore/real_item.md")
ei_real=$(sha_of "$secstore/MEMORY.md")
out=$(bash "$WRITER" retire --store "$secstore" --slug real_item --staged-index "$TMP/emptyidx_sec.md" --expect-target "$et_real" --expect-index "$ei_real" --confirm "$secstore" 2>&1); rc=$?
assert_rc "retire_legit_after_fix_still_works" 0 "$rc"

# purge --ids: content-address format enforced, traversal-shaped/malformed
# ids rejected before any candidate is touched (plan mode -- no mutation to
# even risk, but the parse-time gate must still fire).
idstore=$(bootstrap_store "$TMP/sec_purge_ids")
for badid in "../../etc/passwd" "abc123" "$(printf 'g%.0s' $(seq 1 64))" "a,,b" ",abc" "abc," ""; do
  out=$(bash "$WRITER" purge --store "$idstore" --ids "$badid" 2>&1); rc=$?
  assert_rc "purge_ids_format_rejected_exit2:[$badid]" 2 "$rc"
done
UPPERID=$(printf 'A%.0s' $(seq 1 64))
out=$(bash "$WRITER" purge --store "$idstore" --ids "$UPPERID" 2>&1); rc=$?
assert_rc "purge_ids_uppercase_rejected_exit2" 2 "$rc"
# same gate fires in apply (--manifest) mode too, before touching the inbox
out=$(bash "$WRITER" purge --store "$idstore" --ids "../../etc/passwd" --manifest "$TMP/purge_plan_prefix.txt" --confirm "$idstore" 2>&1); rc=$?
assert_rc "purge_ids_format_rejected_in_apply_mode_exit2" 2 "$rc"

# ===========================================================================
# 11b. Duplicate-flag rejection: every subcommand's argv contract is exact
# (no repeated flags), and that check must fire BEFORE role detection --
# regression for the retire finding (duplicate --slug reached the role
# guard, exit 6, instead of the usage error, exit 2).
# ===========================================================================
dupstore=$(bootstrap_store "$TMP/sec_dup_flags")
DUP_REVIEWER=fleet-reviewer

assert_dup_rejected_pre_role() {
  local label="$1"
  shift
  local out rc
  out=$(KNOWLEDGE_PANE_NAME="$DUP_REVIEWER" bash "$WRITER" "$@" 2>&1)
  rc=$?
  assert_rc "dupflag_${label}_exit2_not_6" 2 "$rc"
  assert_contains "dupflag_${label}_message" "$out" "may not be repeated"
}

assert_dup_rejected_pre_role capture \
  capture --store "$dupstore" --store "$dupstore" --staged "$TMP/emptyidx_sec.md" \
  --idempotency-key "0000000000000000000000000000000000000000000000000000000000000000"

assert_dup_rejected_pre_role apply_store \
  apply --store "$dupstore" --store "$dupstore" --target x.md \
  --staged-target "$TMP/emptyidx_sec.md" --staged-index "$TMP/emptyidx_sec.md" \
  --expect-target absent --expect-index x

assert_dup_rejected_pre_role apply_target \
  apply --store "$dupstore" --target x.md --target y.md \
  --staged-target "$TMP/emptyidx_sec.md" --staged-index "$TMP/emptyidx_sec.md" \
  --expect-target absent --expect-index x

assert_dup_rejected_pre_role apply_candidate \
  apply --store "$dupstore" --target x.md --candidate a --candidate b \
  --staged-target "$TMP/emptyidx_sec.md" --staged-index "$TMP/emptyidx_sec.md" \
  --expect-target absent --expect-index x --expect-candidate y

assert_dup_rejected_pre_role index \
  index --store "$dupstore" --store "$dupstore" \
  --staged-index "$TMP/emptyidx_sec.md" --expect-index x

assert_dup_rejected_pre_role retire_slug \
  retire --store "$dupstore" --slug a --slug b \
  --staged-index "$TMP/emptyidx_sec.md" --expect-target x --expect-index x --confirm "$dupstore"

assert_dup_rejected_pre_role purge_ids \
  purge --store "$dupstore" --ids "$UPPERID" --ids "$UPPERID"

assert_dup_rejected_pre_role purge_expired \
  purge --store "$dupstore" --expired --expired

assert_dup_rejected_pre_role bootstrap \
  bootstrap --store "$dupstore" --store "$dupstore"

assert_dup_rejected_pre_role unlock \
  unlock --store "$dupstore" --store "$dupstore" --confirm "$dupstore"

# ===========================================================================
# 12. init.sh two-call protocol
# ===========================================================================
echo "--- init.sh ---"

d="$TMP/init_basic"
new_repo "$d"
(cd "$d" && touch README.md && git add README.md && git commit -q -m init)
out=$(cd "$d" && bash "$INIT" 2>&1); rc=$?
assert_rc "init_plan_exit0" 0 "$rc"
assert_contains "init_plan_prints_target" "$out" "target: $d/.agents/memory"
assert_contains "init_plan_prints_diff" "$out" "+.agents/memory/"

out=$(cd "$d" && bash "$INIT" --apply 2>&1); rc=$?
assert_rc "init_apply_before_gitignore_exit3" 3 "$rc"

(cd "$d" && echo ".agents/memory/" >> .gitignore)
out=$(cd "$d" && bash "$INIT" --apply 2>&1); rc=$?
assert_rc "init_apply_after_gitignore_exit0" 0 "$rc"
assert_file_present "init_apply_created_store" "$d/.agents/memory/MEMORY.md"

out=$(cd "$d" && bash "$INIT" 2>&1); rc=$?
assert_contains "init_plan_after_apply_already_covered" "$out" "already covered"

out=$(cd "$d" && bash "$INIT" --apply 2>&1); rc=$?
assert_rc "init_apply_idempotent_reentry_exit0" 0 "$rc"
assert_contains "init_apply_idempotent_message" "$out" "already initialized"

# ===========================================================================
# 12. cross-filesystem staged input
# ===========================================================================
echo "--- cross-filesystem staged input ---"

if command -v hdiutil > /dev/null 2>&1; then
  dmg="$TMP/xfs.dmg"
  if hdiutil create -quiet -size 20m -fs "APFS" -volname kmxfstest "$dmg" > /dev/null 2>&1; then
    attach_out=$(hdiutil attach "$dmg" 2>&1)
    XFS_MOUNT=$(printf '%s\n' "$attach_out" | awk '/\/Volumes\//{print $NF; exit}')
    if [ -n "$XFS_MOUNT" ] && [ -d "$XFS_MOUNT" ]; then
      store=$(bootstrap_store "$TMP/xfs_store")
      write_canonical "$XFS_MOUNT/xfs_target.md" project "XFS Item" "cross-filesystem fixture"
      printf -- '- [XFS Item](xfs_item.md) -- x\n' > "$XFS_MOUNT/xfs_index.md"
      ei=$(sha_of "$store/MEMORY.md")
      out=$(bash "$WRITER" apply --store "$store" --target xfs_item.md \
        --staged-target "$XFS_MOUNT/xfs_target.md" --staged-index "$XFS_MOUNT/xfs_index.md" \
        --expect-target absent --expect-index "$ei" 2>&1); rc=$?
      assert_rc "xfs_staged_input_sealed_exit0" 0 "$rc"
      assert_file_present "xfs_staged_input_landed" "$store/xfs_item.md"
      hdiutil detach "$XFS_MOUNT" -force > /dev/null 2>&1 || true
      XFS_MOUNT=""
    else
      echo "  SKIP  xfs_staged_input -- could not attach test disk image"
    fi
  else
    echo "  SKIP  xfs_staged_input -- could not create test disk image (no hdiutil permission)"
  fi
else
  echo "  SKIP  xfs_staged_input -- hdiutil not available on this platform"
fi

# ===========================================================================
# 13. zero-network-egress static assertion
# ===========================================================================
echo "--- zero network egress ---"

egress_hit=""
for f in "$LIB" "$WRITER" "$LINT" "$INDEXTOOL" "$INIT"; do
  if grep -Eniq 'curl|wget|[^a-zA-Z]nc[[:space:]]|http\.client|urllib|requests\.' "$f" 2>/dev/null; then
    egress_hit="$egress_hit $f"
  fi
done
if [ -z "$egress_hit" ]; then
  pass "no_network_client_invocations_in_kernel_scripts"
else
  fail "no_network_client_invocations_in_kernel_scripts" "matches in:$egress_hit"
fi

# ===========================================================================
# summary
# ===========================================================================
echo ""
echo "=== $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  echo "Failures:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
exit 0
