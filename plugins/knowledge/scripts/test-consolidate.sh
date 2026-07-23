#!/usr/bin/env bash
# test-consolidate.sh — hermetic tests for Phase D (consolidate skill): the
# DETERMINISTIC subset of KNOWLEDGE_PLUGIN_SPEC.md's Phase D acceptance,
# scripted. skills/consolidate/SKILL.md is a user-run, agent-judgment
# workflow (near-duplicate judgment, which section a new index row belongs
# under, what counts as a "session learning") that cannot be exercised by a
# shell script — this suite instead simulates the skill's MECHANICAL steps
# exactly as SKILL.md prescribes them (resolve → baseline health → read
# MEMORY.md → dedup pass → build staged target/index → apply one item at a
# time → exit gate) against the already-landed B1-B3 kernel scripts
# (memory-write.sh, memory-lint.sh, memory-index.sh, memory-backlinks.sh,
# memory-search.sh, memory-remember.sh), proving the rails the skill depends
# on actually behave the way the skill document says they do. All fixture
# content is synthetic (ProjectA/ProjectB-style), never real project names.
# Uses isolated git repos under a temp dir; cleans up on exit.
#
# This suite intentionally does not re-test memory-write.sh's own
# lock/journal/recovery/CAS internals (test-memory-kernel.sh already covers
# those exhaustively) or memory-search.sh's scoring/output-schema contract
# (test-retrieval.sh covers that) — it tests the Phase D SURFACE: the exact
# sequences skills/consolidate/SKILL.md documents, end to end.
#
# Usage: bash test-consolidate.sh [-v]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WRITER="$HERE/memory-write.sh"
REMEMBER="$HERE/memory-remember.sh"
LINT="$HERE/memory-lint.sh"
INDEXTOOL="$HERE/memory-index.sh"
BACKLINKS="$HERE/memory-backlinks.sh"
SEARCH="$HERE/memory-search.sh"
SKILL_MD="$HERE/../skills/consolidate/SKILL.md"
COMMAND_MD="$HERE/../commands/consolidate.md"

PASS=0
FAIL=0
FAILURES=()
TMP="$(mktemp -d -t kmconsolidate-test-XXXXXX)"
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

echo "=== consolidate (Phase D) tests (tmp: $TMP) ==="

# ---------------------------------------------------------------------------
# helpers (conventions match test-capture.sh / test-memory-kernel.sh)
# ---------------------------------------------------------------------------
new_repo() {
  local d="$1"
  rm -rf "$d"
  mkdir -p "$d"
  (cd "$d" && git init -q .)
}

# bootstrap_store <repo-dir> -> echoes the canonical (root) store path.
bootstrap_store() {
  local d="$1" store
  new_repo "$d"
  (cd "$d" && echo ".agents/memory/" >> .gitignore && git add .gitignore && git commit -q -m init)
  store="$d/.agents/memory"
  bash "$WRITER" bootstrap --store "$store" > /dev/null 2>&1
  (cd "$store" && pwd -P)
}

# bootstrap_nested_store <repo-dir> <child-name> -> echoes the nested
# (per-role/per-child) store path -- the OTHER real layout shape from the
# spec's "Multi-store layouts" section.
bootstrap_nested_store() {
  local d="$1" child="$2" store
  new_repo "$d"
  (cd "$d" && echo ".agents/memory/" >> .gitignore && git add .gitignore && git commit -q -m init)
  mkdir -p "$d/.agents/memory"
  store="$d/.agents/memory/$child"
  bash "$WRITER" bootstrap --store "$store" > /dev/null 2>&1
  (cd "$store" && pwd -P)
}

mw_call() {
  bash -c "source '$WRITER'; $1"
}

sha_of() {
  mw_call "km_sha256_file '$1' 2>/dev/null"
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

# stage_candidate <path> <source> <sensitivity> <name> <desc> <type>
stage_candidate() {
  local path="$1" src="$2" sens="$3" name="$4" desc="$5" type="$6"
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
    echo "**Why:** synthetic capture."
    echo
    echo "**How to apply:** n/a."
  } > "$path"
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

assert_file_present() {
  local label="$1" path="$2"
  if [ -e "$path" ]; then
    pass "$label"
  else
    fail "$label" "expected $path to be present"
  fi
}

assert_file_absent() {
  local label="$1" path="$2"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    pass "$label"
  else
    fail "$label" "expected $path to be absent"
  fi
}

# tree_hash <dir> -- stable aggregate hash of relpath+content for every
# regular file under dir (sorted); proves a sequence of steps left the store
# byte-identical.
tree_hash() {
  local dir="$1" f rel
  {
    find "$dir" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
      rel="${f#"$dir"/}"
      printf '%s\n' "$rel"
      shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
    done
  } | shasum -a 256 | awk '{print $1}'
}

# seed_alpha_beta_files <store> -- two authoritative files + a flat index,
# used by the dedup-determinism fixtures on both layout shapes.
seed_alpha_beta_files() {
  local store="$1"
  write_canonical "$store/project_alpha_timeout_fix.md" project "ProjectA Alpha Timeout Fix" "extends retry timeout for alpha background jobs"
  write_canonical "$store/reference_beta_config_notes.md" reference "ProjectB Beta Config Notes" "environment variable reference for the beta service"
  chmod 600 "$store"/*.md
  cat > "$store/MEMORY.md" <<'EOF'
- [ProjectA Alpha Timeout Fix](project_alpha_timeout_fix.md) -- extends retry timeout for alpha background jobs
- [ProjectB Beta Config Notes](reference_beta_config_notes.md) -- environment variable reference for the beta service
EOF
  chmod 600 "$store/MEMORY.md"
}

# ===========================================================================
# 1. DEDUP CANDIDATE-SET DETERMINISM (both real layout shapes: root store,
# and a nested per-role/per-child store) -- same query -> same ranked slugs
# feeding the near-duplicate judgment (SKILL.md step 5).
# ===========================================================================
echo "--- 1. dedup candidate-set determinism ---"

dedup_case() {
  local label="$1" store="$2" out1 out2 rc1 top_slug g1 g2

  out1=$(bash "$SEARCH" --store "$store" alpha timeout 2>&1); rc1=$?
  out2=$(bash "$SEARCH" --store "$store" alpha timeout 2>&1)
  assert_rc "${label}_search_exit0" 0 "$rc1"
  assert_eq "${label}_search_deterministic_repeat" "$out1" "$out2"
  top_slug=$(printf '%s\n' "$out1" | head -1 | cut -f2)
  assert_eq "${label}_search_top_hit_is_expected_duplicate" "project_alpha_timeout_fix" "$top_slug"

  g1=$(grep -n -i -E -- "name:.*alpha|description:.*alpha" "$store"/*.md 2>/dev/null)
  g2=$(grep -n -i -E -- "name:.*alpha|description:.*alpha" "$store"/*.md 2>/dev/null)
  assert_eq "${label}_grep_backstop_deterministic_repeat" "$g1" "$g2"
  assert_contains "${label}_grep_backstop_finds_duplicate" "$g1" "project_alpha_timeout_fix.md"
}

storeA=$(bootstrap_store "$TMP/dedup_root")
seed_alpha_beta_files "$storeA"
dedup_case "dedup_root_layout" "$storeA"

storeB=$(bootstrap_nested_store "$TMP/dedup_nested" "roleA")
seed_alpha_beta_files "$storeB"
dedup_case "dedup_nested_layout" "$storeB"

# ===========================================================================
# 2. UPDATE-PATH APPLY THROUGH THE WRITER, PRESERVING EACH INDEX STYLE
# ===========================================================================

echo "--- 2a. UPDATE apply -- flat index style (sequential, one item at a time) ---"

fstore=$(bootstrap_store "$TMP/idx_flat")
write_canonical "$fstore/project_alpha_timeout_fix.md" project "ProjectA Alpha Timeout Fix" "extends retry timeout for alpha background jobs"
write_canonical "$fstore/reference_beta_config_notes.md" reference "ProjectB Beta Config Notes" "environment variable reference for the beta service"
chmod 600 "$fstore"/*.md
cat > "$fstore/MEMORY.md" <<'EOF'
- [ProjectA Alpha Timeout Fix](project_alpha_timeout_fix.md) -- extends retry timeout for alpha background jobs
- [ProjectB Beta Config Notes](reference_beta_config_notes.md) -- environment variable reference for the beta service
EOF
chmod 600 "$fstore/MEMORY.md"

# Item 1 (CREATE): a brand-new feedback learning gets its own new flat row.
ei=$(sha_of "$fstore/MEMORY.md")
cat > "$TMP/flat_create_target.md" <<'EOF'
---
schema_version: 1
name: ProjectA Commit Habits
description: structure commits around one logical change
metadata:
  type: feedback
created: 2026-01-01
updated: 2026-01-01
---
**Why:** synthetic fixture reason.

**How to apply:** synthetic fixture application.
EOF
cat > "$TMP/flat_index_after_create.md" <<'EOF'
- [ProjectA Alpha Timeout Fix](project_alpha_timeout_fix.md) -- extends retry timeout for alpha background jobs
- [ProjectB Beta Config Notes](reference_beta_config_notes.md) -- environment variable reference for the beta service
- [ProjectA Commit Habits](feedback_projecta_commit_habits.md) -- structure commits around one logical change
EOF
out=$(bash "$WRITER" apply --store "$fstore" --target feedback_projecta_commit_habits.md \
  --staged-target "$TMP/flat_create_target.md" --staged-index "$TMP/flat_index_after_create.md" \
  --expect-target absent --expect-index "$ei" 2>&1); rc=$?
assert_rc "flat_create_apply_exit0" 0 "$rc"
assert_file_present "flat_create_target_present" "$fstore/feedback_projecta_commit_habits.md"

# Item 2 (UPDATE): re-read MEMORY.md fresh (SKILL.md step 8.1) before staging
# the next item -- the alpha-timeout learning duplicates an existing file;
# extend its body, leave its index row exactly as-is.
et=$(sha_of "$fstore/project_alpha_timeout_fix.md")
ei=$(sha_of "$fstore/MEMORY.md")
cat > "$TMP/flat_update_target.md" <<'EOF'
---
schema_version: 1
name: ProjectA Alpha Timeout Fix
description: extends retry timeout for alpha background jobs
metadata:
  type: project
created: 2026-01-01
updated: 2026-02-01
---
**Why:** synthetic fixture reason.

**How to apply:** synthetic fixture application. Extended further after a second alpha-job timeout was observed: the retry window now doubles on the third attempt.
EOF
cat > "$TMP/flat_index_after_update.md" <<'EOF'
- [ProjectA Alpha Timeout Fix](project_alpha_timeout_fix.md) -- extends retry timeout for alpha background jobs
- [ProjectB Beta Config Notes](reference_beta_config_notes.md) -- environment variable reference for the beta service
- [ProjectA Commit Habits](feedback_projecta_commit_habits.md) -- structure commits around one logical change
EOF
out=$(bash "$WRITER" apply --store "$fstore" --target project_alpha_timeout_fix.md \
  --staged-target "$TMP/flat_update_target.md" --staged-index "$TMP/flat_index_after_update.md" \
  --expect-target "$et" --expect-index "$ei" 2>&1); rc=$?
assert_rc "flat_update_apply_exit0" 0 "$rc"
assert_contains "flat_update_body_extended" "$(cat "$fstore/project_alpha_timeout_fix.md")" "doubles on the third attempt"

idx_out=$(bash "$INDEXTOOL" --store "$fstore" 2>&1); idx_rc=$?
assert_rc "flat_update_index_clean_exit0" 0 "$idx_rc"
assert_eq "flat_update_index_no_drift_output" "" "$idx_out"

echo "--- 2b. UPDATE apply -- sectioned index style ---"

sstore=$(bootstrap_store "$TMP/idx_sectioned")
write_canonical "$sstore/project_alpha_timeout_fix.md" project "ProjectA Alpha Timeout Fix" "extends retry timeout for alpha background jobs"
write_canonical "$sstore/feedback_team_commit_habits.md" feedback "ProjectA Commit Habits" "structure commits around one logical change"
chmod 600 "$sstore"/*.md
cat > "$sstore/MEMORY.md" <<'EOF'
## Project
- [ProjectA Alpha Timeout Fix](project_alpha_timeout_fix.md) -- extends retry timeout for alpha background jobs
## Feedback
- [ProjectA Commit Habits](feedback_team_commit_habits.md) -- structure commits around one logical change
EOF
chmod 600 "$sstore/MEMORY.md"

ei=$(sha_of "$sstore/MEMORY.md")
cat > "$TMP/sectioned_new_target.md" <<'EOF'
---
schema_version: 1
name: ProjectB Cache Warm Notes
description: cache warm-up sequence for the ProjectB service
metadata:
  type: project
created: 2026-01-01
updated: 2026-01-01
---
**Why:** synthetic fixture reason.

**How to apply:** synthetic fixture application.
EOF
cat > "$TMP/sectioned_index_after_create.md" <<'EOF'
## Project
- [ProjectA Alpha Timeout Fix](project_alpha_timeout_fix.md) -- extends retry timeout for alpha background jobs
- [ProjectB Cache Warm Notes](project_cache_warm_notes.md) -- cache warm-up sequence for the ProjectB service
## Feedback
- [ProjectA Commit Habits](feedback_team_commit_habits.md) -- structure commits around one logical change
EOF
out=$(bash "$WRITER" apply --store "$sstore" --target project_cache_warm_notes.md \
  --staged-target "$TMP/sectioned_new_target.md" --staged-index "$TMP/sectioned_index_after_create.md" \
  --expect-target absent --expect-index "$ei" 2>&1); rc=$?
assert_rc "sectioned_create_apply_exit0" 0 "$rc"

idx_out=$(bash "$INDEXTOOL" --store "$sstore" 2>&1); idx_rc=$?
assert_rc "sectioned_create_index_clean_exit0" 0 "$idx_rc"
assert_eq "sectioned_create_index_no_drift_output" "" "$idx_out"

final_index=$(cat "$sstore/MEMORY.md")
assert_contains "sectioned_feedback_section_preserved" "$final_index" "- [ProjectA Commit Habits](feedback_team_commit_habits.md) -- structure commits around one logical change"
assert_contains "sectioned_headings_preserved" "$final_index" "## Feedback"

echo "--- 2c. UPDATE apply -- multi-link index rows ---"

mstore=$(bootstrap_store "$TMP/idx_multilink")
write_canonical "$mstore/redis_tls_incident.md" project "Redis TLS Incident" "TLS handshake fix for Redis 7"
write_canonical "$mstore/redis_setup_guide.md" reference "Redis Setup Guide" "how the shared Redis instance is provisioned"
chmod 600 "$mstore"/*.md
cat > "$mstore/MEMORY.md" <<'EOF'
- [Redis TLS Incident](redis_tls_incident.md) -- TLS handshake fix for Redis 7 (see also [Redis Setup Guide](redis_setup_guide.md))
- [Redis Setup Guide](redis_setup_guide.md) -- how the shared Redis instance is provisioned
EOF
chmod 600 "$mstore/MEMORY.md"

et=$(sha_of "$mstore/redis_tls_incident.md")
ei=$(sha_of "$mstore/MEMORY.md")
cat > "$TMP/multilink_target_update.md" <<'EOF'
---
schema_version: 1
name: Redis TLS Incident
description: TLS handshake fix for Redis 7
metadata:
  type: project
created: 2026-01-01
updated: 2026-02-01
---
**Why:** synthetic fixture reason.

**How to apply:** synthetic fixture application. A second incident confirmed
the fix also applies to the read-replica connections.
EOF
# Only the FIRST row's hook text changes; its same-row cross-reference link
# to [Redis Setup Guide](redis_setup_guide.md) must be preserved untouched.
cat > "$TMP/multilink_index_after_update.md" <<'EOF'
- [Redis TLS Incident](redis_tls_incident.md) -- TLS handshake fix, now covering read replicas too (see also [Redis Setup Guide](redis_setup_guide.md))
- [Redis Setup Guide](redis_setup_guide.md) -- how the shared Redis instance is provisioned
EOF
out=$(bash "$WRITER" apply --store "$mstore" --target redis_tls_incident.md \
  --staged-target "$TMP/multilink_target_update.md" --staged-index "$TMP/multilink_index_after_update.md" \
  --expect-target "$et" --expect-index "$ei" 2>&1); rc=$?
assert_rc "multilink_update_apply_exit0" 0 "$rc"

idx_out=$(bash "$INDEXTOOL" --store "$mstore" 2>&1); idx_rc=$?
assert_rc "multilink_update_index_clean_exit0" 0 "$idx_rc"
assert_eq "multilink_update_index_no_drift_output" "" "$idx_out"

final_index=$(cat "$mstore/MEMORY.md")
assert_contains "multilink_cross_reference_preserved" "$final_index" "(see also [Redis Setup Guide](redis_setup_guide.md))"

# ===========================================================================
# 3. INBOX-CANDIDATE PROMOTION END TO END + TASK-CLOSE ROUND TRIP
# (capture -> list -> apply --candidate -> candidate gone only after
# verified install; a fixture tracked item closes -> remember captures the
# learning -> consolidate-mechanics promote it -> tracker file untouched)
# ===========================================================================
echo "--- 3. inbox-candidate promotion + task-close round trip ---"

proot="$TMP/promote_flow"
pstore=$(bootstrap_store "$proot")

# The tracker fixture lives OUTSIDE the memory store, exactly like a real
# repo's docs/TODO.md -- this suite never touches it via any knowledge-plugin
# surface; it only asserts the memory-side flow never reaches it.
cat > "$proot/TODO.md" <<'EOF'
# TODO

- [ ] ProjectA: investigate deploy timeout flakiness
- [ ] ProjectB: rotate staging credentials
EOF
# Simulate the tracked item closing (a human docs-authoring action -- never
# performed by this plugin).
sed -i.bak 's/\[ \] ProjectA: investigate deploy timeout flakiness/[x] ProjectA: investigate deploy timeout flakiness/' "$proot/TODO.md"
rm -f "$proot/TODO.md.bak"
todo_hash_after_close=$(shasum -a 256 "$proot/TODO.md" | awk '{print $1}')

f_learn="$TMP/task_close_staged.md"
stage_candidate "$f_learn" "task-close-projecta-deploy" "normal" "ProjectA Deploy Timeout Root Cause" "root cause: handshake retries exhausted before backoff kicked in" feedback

out=$(bash "$REMEMBER" --store "$pstore" --staged "$f_learn" 2>&1); rc=$?
assert_rc "task_close_capture_exit0" 0 "$rc"
tkey=$(printf '%s\n' "$out" | grep '^capture_id: ' | sed 's/^capture_id: //')

out_list=$(bash "$REMEMBER" --store "$pstore" --list 2>&1); rc=$?
assert_rc "task_close_list_exit0" 0 "$rc"
assert_contains "task_close_list_shows_candidate" "$out_list" "$tkey"

ei=$(sha_of "$pstore/MEMORY.md")
ec=$(sha_of "$pstore/.inbox/${tkey}.md")
cat > "$TMP/task_close_target.md" <<'EOF'
---
schema_version: 1
name: ProjectA Deploy Timeout Root Cause
description: root cause: handshake retries exhausted before backoff kicked in
metadata:
  type: feedback
created: 2026-01-01
updated: 2026-01-01
---
**Why:** synthetic fixture reason.

**How to apply:** synthetic fixture application.
EOF
cat > "$TMP/task_close_index.md" <<'EOF'
- [ProjectA Deploy Timeout Root Cause](feedback_projecta_deploy_timeout_root_cause.md) -- root cause: handshake retries exhausted before backoff kicked in
EOF
out=$(bash "$WRITER" apply --store "$pstore" --target feedback_projecta_deploy_timeout_root_cause.md \
  --staged-target "$TMP/task_close_target.md" --staged-index "$TMP/task_close_index.md" \
  --expect-target absent --expect-index "$ei" \
  --candidate "$tkey" --expect-candidate "$ec" 2>&1); rc=$?
assert_rc "task_close_apply_exit0" 0 "$rc"
assert_file_present "task_close_target_created" "$pstore/feedback_projecta_deploy_timeout_root_cause.md"
assert_file_absent "task_close_candidate_consumed_only_after_apply" "$pstore/.inbox/${tkey}.md"

todo_hash_final=$(shasum -a 256 "$proot/TODO.md" | awk '{print $1}')
assert_eq "task_close_tracker_untouched_by_memory_flow" "$todo_hash_after_close" "$todo_hash_final"

idx_out=$(bash "$INDEXTOOL" --store "$pstore" 2>&1); idx_rc=$?
assert_rc "task_close_index_clean_exit0" 0 "$idx_rc"
assert_eq "task_close_index_no_drift_output" "" "$idx_out"

# ===========================================================================
# 4. DANGLING-[[LINK]] FLAG SURFACING
# ===========================================================================
echo "--- 4. dangling link flag surfacing ---"

dstore=$(bootstrap_store "$TMP/dangling_flag")
ei=$(sha_of "$dstore/MEMORY.md")
cat > "$TMP/dangling_target.md" <<'EOF'
---
schema_version: 1
name: ProjectA Rollback Runbook
description: steps to roll back a bad ProjectA deploy
metadata:
  type: project
created: 2026-01-01
updated: 2026-01-01
---
**Why:** synthetic fixture reason.

**How to apply:** see [[projecta_rollback_prereqs]] before running this --
that memory file does not exist yet, and forward-pointing links are legal.
EOF
cat > "$TMP/dangling_index.md" <<'EOF'
- [ProjectA Rollback Runbook](project_rollback_runbook.md) -- steps to roll back a bad ProjectA deploy
EOF
out=$(bash "$WRITER" apply --store "$dstore" --target project_rollback_runbook.md \
  --staged-target "$TMP/dangling_target.md" --staged-index "$TMP/dangling_index.md" \
  --expect-target absent --expect-index "$ei" 2>&1); rc=$?
assert_rc "dangling_fixture_apply_exit0" 0 "$rc"

bl_out=$(bash "$BACKLINKS" --store "$dstore" report 2>&1); rc=$?
assert_rc "dangling_report_exit0" 0 "$rc"
assert_contains "dangling_report_flags_link" "$bl_out" "dangling: [[projecta_rollback_prereqs]]"

# ===========================================================================
# 5. REVIEWER-ROLE / UNRESOLVED-IDENTITY REFUSAL PROPAGATION ON APPLY
# ===========================================================================
echo "--- 5. reviewer role / unresolved identity refusal on apply ---"

rstore=$(bootstrap_store "$TMP/role_refusal")
ei=$(sha_of "$rstore/MEMORY.md")
cat > "$TMP/role_target.md" <<'EOF'
---
schema_version: 1
name: ProjectA Role Test Item
description: fixture for role refusal
metadata:
  type: project
created: 2026-01-01
updated: 2026-01-01
---
**Why:** synthetic fixture reason.

**How to apply:** synthetic fixture application.
EOF
cat > "$TMP/role_index.md" <<'EOF'
- [ProjectA Role Test Item](project_role_test_item.md) -- fixture for role refusal
EOF

out=$(KNOWLEDGE_PANE_NAME=fleet-reviewer bash "$WRITER" apply --store "$rstore" --target project_role_test_item.md \
  --staged-target "$TMP/role_target.md" --staged-index "$TMP/role_index.md" \
  --expect-target absent --expect-index "$ei" 2>&1); rc=$?
assert_rc "apply_reviewer_refused_exit6" 6 "$rc"
assert_contains "apply_reviewer_refused_message" "$out" "reviewer role: memory writes refused"
assert_file_absent "apply_reviewer_refused_no_target" "$rstore/project_role_test_item.md"
assert_eq "apply_reviewer_refused_index_unchanged" "$ei" "$(sha_of "$rstore/MEMORY.md")"

out=$(env -u KNOWLEDGE_PANE_NAME -u SESSION_CHAT_PANE_NAME TMUX=/fake/sock,1,1 bash "$WRITER" apply --store "$rstore" --target project_role_test_item.md \
  --staged-target "$TMP/role_target.md" --staged-index "$TMP/role_index.md" \
  --expect-target absent --expect-index "$ei" 2>&1); rc=$?
assert_rc "apply_unresolved_identity_exit6" 6 "$rc"
assert_contains "apply_unresolved_identity_message" "$out" "unresolved pane identity"
assert_file_absent "apply_unresolved_identity_no_target" "$rstore/project_role_test_item.md"
assert_eq "apply_unresolved_identity_index_unchanged" "$ei" "$(sha_of "$rstore/MEMORY.md")"

# ===========================================================================
# 6. ABORTED-APPROVAL INVARIANT: everything up to (never including) the
# apply call is non-mutating -- if the user declines, the store is
# byte-identical to before the run started.
# ===========================================================================
echo "--- 6. aborted-approval invariant ---"

astore=$(bootstrap_store "$TMP/aborted_approval")
write_canonical "$astore/project_alpha_timeout_fix.md" project "ProjectA Alpha Timeout Fix" "extends retry timeout for alpha background jobs"
chmod 600 "$astore"/*.md
cat > "$astore/MEMORY.md" <<'EOF'
- [ProjectA Alpha Timeout Fix](project_alpha_timeout_fix.md) -- extends retry timeout for alpha background jobs
EOF
chmod 600 "$astore/MEMORY.md"

hash_before=$(tree_hash "$astore")

# Simulate SKILL.md steps 2-6 (baseline health, read MEMORY.md, dedup pass,
# build the full staged target+index) -- every staged file lands in $TMP,
# never inside the store.
bash "$LINT" --store "$astore" > /dev/null 2>&1
bash "$INDEXTOOL" --store "$astore" > /dev/null 2>&1
bash "$BACKLINKS" --store "$astore" report > /dev/null 2>&1
bash "$SEARCH" --store "$astore" alpha timeout > /dev/null 2>&1
grep -n -i -E -- "name:.*alpha" "$astore"/*.md > /dev/null 2>&1
cat "$astore/MEMORY.md" > /dev/null
cat > "$TMP/aborted_staged_target.md" <<'EOF'
---
schema_version: 1
name: ProjectA Alpha Timeout Fix
description: extends retry timeout for alpha background jobs
metadata:
  type: project
created: 2026-01-01
updated: 2026-02-01
---
**Why:** synthetic fixture reason.

**How to apply:** would have been extended, but the user declined approval.
EOF
cat > "$TMP/aborted_staged_index.md" <<'EOF'
- [ProjectA Alpha Timeout Fix](project_alpha_timeout_fix.md) -- extends retry timeout for alpha background jobs
- [ProjectA New Item](project_new_item.md) -- would have been proposed
EOF
# The user declines at SKILL.md step 7. No memory-write.sh apply call is made.

hash_after=$(tree_hash "$astore")
assert_eq "aborted_approval_store_byte_identical" "$hash_before" "$hash_after"

# ===========================================================================
# 7. LEGACY UPGRADE STAMPING ON AN UPDATE (upgrade only-on-UPDATE rule)
# ===========================================================================
echo "--- 7. legacy upgrade stamping on an update ---"

legstore=$(bootstrap_store "$TMP/legacy_upgrade")
cat > "$legstore/2025-03-04-deploy-notes.md" <<'EOF'
---
type: project
name: Deploy Notes
---
old legacy body content.
EOF
cat > "$legstore/credential_rotation_notes.md" <<'EOF'
---
type: feedback
name: Credential Rotation Notes
---
old legacy body content, no date anywhere in the name.
EOF
chmod 600 "$legstore"/*.md
cat > "$legstore/MEMORY.md" <<'EOF'
- [Deploy Notes](2025-03-04-deploy-notes.md) -- legacy deploy notes
- [Credential Rotation Notes](credential_rotation_notes.md) -- legacy credential rotation notes
EOF
chmod 600 "$legstore/MEMORY.md"

lint_pre_rc_check=$(bash "$LINT" --store "$legstore" > /dev/null 2>&1; echo $?)
assert_rc "legacy_pre_upgrade_lint_advisory_only_exit0" 0 "$lint_pre_rc_check"

# Case A: created derivable from the filename.
et=$(sha_of "$legstore/2025-03-04-deploy-notes.md")
ei=$(sha_of "$legstore/MEMORY.md")
cat > "$TMP/legacy_a_target.md" <<'EOF'
---
schema_version: 1
name: Deploy Notes
description: legacy deploy notes migrated to canonical schema
metadata:
  type: project
created: 2025-03-04
updated: 2026-01-02
---
**Why:** synthetic fixture reason.

**How to apply:** synthetic fixture application.
EOF
cat > "$TMP/legacy_a_index.md" <<'EOF'
- [Deploy Notes](2025-03-04-deploy-notes.md) -- legacy deploy notes
- [Credential Rotation Notes](credential_rotation_notes.md) -- legacy credential rotation notes
EOF
out=$(bash "$WRITER" apply --store "$legstore" --target "2025-03-04-deploy-notes.md" \
  --staged-target "$TMP/legacy_a_target.md" --staged-index "$TMP/legacy_a_index.md" \
  --expect-target "$et" --expect-index "$ei" 2>&1); rc=$?
assert_rc "legacy_upgrade_date_from_filename_apply_exit0" 0 "$rc"

lint_after_a=$(bash "$LINT" --store "$legstore" 2>&1)
assert_not_contains "legacy_upgrade_date_from_filename_no_error" "$lint_after_a" $'ERROR\t2025-03-04-deploy-notes.md'

# Case B: no derivable date -> created: unknown + migrated: <today>.
ei=$(sha_of "$legstore/MEMORY.md")
et2=$(sha_of "$legstore/credential_rotation_notes.md")
cat > "$TMP/legacy_b_target.md" <<'EOF'
---
schema_version: 1
name: Credential Rotation Notes
description: legacy credential rotation notes migrated to canonical schema
metadata:
  type: feedback
created: unknown
migrated: 2026-01-02
updated: 2026-01-02
---
**Why:** synthetic fixture reason.

**How to apply:** synthetic fixture application.
EOF
cat > "$TMP/legacy_b_index.md" <<'EOF'
- [Deploy Notes](2025-03-04-deploy-notes.md) -- legacy deploy notes
- [Credential Rotation Notes](credential_rotation_notes.md) -- legacy credential rotation notes
EOF
out=$(bash "$WRITER" apply --store "$legstore" --target "credential_rotation_notes.md" \
  --staged-target "$TMP/legacy_b_target.md" --staged-index "$TMP/legacy_b_index.md" \
  --expect-target "$et2" --expect-index "$ei" 2>&1); rc=$?
assert_rc "legacy_upgrade_created_unknown_migrated_apply_exit0" 0 "$rc"

lint_after_b=$(bash "$LINT" --store "$legstore" 2>&1)
assert_not_contains "legacy_upgrade_created_unknown_no_error" "$lint_after_b" $'ERROR\tcredential_rotation_notes.md'

# Negative control, isolated store: created: unknown WITHOUT migrated: must
# still be a lint ERROR -- proves case B's migrated: stamp was load-bearing.
negstore=$(bootstrap_store "$TMP/legacy_upgrade_negative")
cat > "$negstore/bad_unknown.md" <<'EOF'
---
schema_version: 1
name: Bad Unknown
description: fixture
metadata:
  type: project
created: unknown
updated: 2026-01-02
---
**Why:** synthetic fixture reason.

**How to apply:** synthetic fixture application.
EOF
chmod 600 "$negstore"/*.md
echo "- [Bad Unknown](bad_unknown.md) -- fixture" > "$negstore/MEMORY.md"
chmod 600 "$negstore/MEMORY.md"
lint_neg=$(bash "$LINT" --store "$negstore" 2>&1); lint_neg_rc=$?
assert_rc "legacy_upgrade_negative_control_exit4" 4 "$lint_neg_rc"
assert_contains "legacy_upgrade_negative_control_error_message" "$lint_neg" "created: unknown requires a migrated"

# ===========================================================================
# 8. EXIT-GATE RE-RUN ASSERTIONS
# ===========================================================================
echo "--- 8. exit gate re-run ---"

gate_lint=$(bash "$LINT" --store "$fstore" 2>&1); gate_lint_rc=$?
assert_rc "exit_gate_lint_clean_exit0" 0 "$gate_lint_rc"
assert_not_contains "exit_gate_lint_no_error_rows" "$gate_lint" "ERROR"$'\t'
gate_index=$(bash "$INDEXTOOL" --store "$fstore" 2>&1); gate_index_rc=$?
assert_rc "exit_gate_index_clean_exit0" 0 "$gate_index_rc"
assert_eq "exit_gate_index_no_drift_output" "" "$gate_index"
gate_bl=$(bash "$BACKLINKS" --store "$fstore" report 2>&1); gate_bl_rc=$?
assert_rc "exit_gate_backlinks_clean_exit0" 0 "$gate_bl_rc"
assert_eq "exit_gate_backlinks_no_findings" "" "$gate_bl"

# ===========================================================================
# 9. ZERO-NETWORK-EGRESS STATIC CHECK (this phase's own surfaces)
# ===========================================================================
echo "--- 9. zero network egress (static) ---"

egress_hit=""
# (This test script itself is deliberately excluded -- its own grep pattern
# below contains the literal substrings "curl"/"wget"/etc. and would always
# self-match; test-memory-kernel.sh / test-retrieval.sh follow the same
# convention of only scanning the scripts under test.)
for f in "$SKILL_MD" "$COMMAND_MD" "$WRITER" "$REMEMBER" "$SEARCH" "$BACKLINKS" "$LINT" "$INDEXTOOL"; do
  if grep -Eniq 'curl|wget|[^a-zA-Z]nc[[:space:]]|http\.client|urllib|requests\.|socket\.connect' "$f" 2>/dev/null; then
    egress_hit="$egress_hit $f"
  fi
done
if [ -z "$egress_hit" ]; then
  pass "no_network_client_invocations_in_consolidate_surfaces"
else
  fail "no_network_client_invocations_in_consolidate_surfaces" "matches in:$egress_hit"
fi

# ===========================================================================
# 10. CROSS-PROVIDER CONSOLIDATION OF A CANDIDATE CAPTURED UNDER THE OTHER
# PROVIDER (exercised only once the codex mirror's memory-remember.sh lands)
# ===========================================================================
echo "--- 10. cross-provider candidate visibility for consolidation ---"

CODEX_REMEMBER="$HERE/../../../codex/plugins/knowledge/scripts/memory-remember.sh"
cpstore=$(bootstrap_store "$TMP/cross_provider_consolidate")
f_cp="$TMP/cross_provider_consolidate_staged.md"
stage_candidate "$f_cp" "sess-cp-claude" "normal" "Cross Provider Consolidation Item" "captured under one provider, consolidated after being listed from the other" project

if [ -f "$CODEX_REMEMBER" ]; then
  echo "  (codex mirror's memory-remember.sh exists -- running the real cross-provider fixture)"
  out=$(bash "$REMEMBER" --store "$cpstore" --staged "$f_cp" 2>&1)
  cpkey=$(printf '%s\n' "$out" | grep '^capture_id: ' | sed 's/^capture_id: //')
  out_codex_list=$(bash "$CODEX_REMEMBER" --store "$cpstore" --list 2>&1); rc=$?
  assert_rc "cross_provider_consolidate_codex_list_exit0" 0 "$rc"
  assert_contains "cross_provider_consolidate_codex_sees_claude_capture" "$out_codex_list" "$cpkey"
else
  echo "  SKIP  cross_provider_consolidate -- codex/plugins/knowledge/scripts/memory-remember.sh not present yet; this fixture will be exercised at the E/F gates once the codex mirror lands."
fi

# ===========================================================================
# summary
# ===========================================================================
echo ""
echo "=== consolidate tests: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  echo "Failures:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
exit 0
