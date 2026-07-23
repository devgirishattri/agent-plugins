#!/usr/bin/env bash
# test-promotion.sh — hermetic tests for Phase E (promotion + structured
# handoff lifecycle): the handoff frontmatter mechanics in save-context.sh /
# list-contexts.sh, the pass-through guarantee on load/share/diff/remove, and
# the DETERMINISTIC subset of skills/promote/SKILL.md's acceptance (it is a
# user-run, agent-judgment workflow -- like consolidate -- so this suite
# simulates its MECHANICAL steps exactly as SKILL.md prescribes them:
# identify source -> resolve store(s) -> propose destination -> approve ->
# write+revalidate (memory-write.sh apply) -> SEPARATE confirm -> delete
# source (remove-context.sh / memory-write.sh retire)) against the already-
# landed B1-D kernel scripts. All fixture content is synthetic
# (ProjectA/ProjectB-style), never real project names. Uses isolated git
# repos and context stores under a temp dir; cleans up on exit.
#
# This suite intentionally does not re-test memory-write.sh's own
# lock/journal/recovery/CAS internals (test-memory-kernel.sh already covers
# those exhaustively), memory-search.sh's scoring contract (test-retrieval.sh),
# or the context-store writer-lock/hardening internals (test-session-context.sh,
# which this suite never modifies or duplicates) -- it tests the Phase E
# SURFACE: handoff frontmatter mechanics, list/pass-through contracts, and the
# promote skill's mechanical write/delete sequencing, end to end.
#
# Doctor's own E-tier (expires-metadata context tier + handoff
# ticket-citation checks) is EXPLICITLY NOT this suite's to ship -- doctor.sh
# is out of this phase's boundary (a concurrent agent owns it). Section 6
# below validates the ticket-citation GRAMMAR with test-local logic that
# mirrors skills/promote/SKILL.md step 5, so Phase E's acceptance (a
# ticket-citation fixture) is proven without touching doctor.sh.
#
# Usage: bash test-promotion.sh [-v]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WRITER="$HERE/memory-write.sh"
LINT="$HERE/memory-lint.sh"
INDEXTOOL="$HERE/memory-index.sh"
BACKLINKS="$HERE/memory-backlinks.sh"
SEARCH="$HERE/memory-search.sh"
SAVE="$HERE/save-context.sh"
LISTCTX="$HERE/list-contexts.sh"
LOADCTX="$HERE/load-context.sh"
DIFFCTX="$HERE/diff-context.sh"
REMOVECTX="$HERE/remove-context.sh"
SHARECTX="$HERE/share-context.sh"
PROMOTE_SKILL_MD="$HERE/../skills/promote/SKILL.md"
PROMOTE_COMMAND_MD="$HERE/../commands/promote.md"
CONTEXT_GENERATE_MD="$HERE/../commands/context-generate.md"
CONTEXT_LIST_MD="$HERE/../commands/context-list.md"

PASS=0
FAIL=0
FAILURES=()
TMP="$(mktemp -d -t kmpromotion-test-XXXXXX)"
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

echo "=== promotion (Phase E) tests (tmp: $TMP) ==="

# ---------------------------------------------------------------------------
# helpers (conventions match test-consolidate.sh / test-capture.sh /
# test-memory-kernel.sh)
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

mw_call() {
  bash -c "source '$WRITER'; $1"
}

sha_of() {
  mw_call "km_sha256_file '$1' 2>/dev/null"
}

# write_canonical <path> <type> <name> <desc> [created] [updated] [extra-frontmatter-line]
write_canonical() {
  local path="$1" type="$2" name="$3" desc="$4" created="${5:-2026-01-01}" updated="${6:-2026-01-02}" extra="${7:-}"
  {
    echo "---"
    echo "schema_version: 1"
    echo "name: $name"
    echo "description: $desc"
    echo "metadata:"
    echo "  type: $type"
    echo "created: $created"
    echo "updated: $updated"
    [ -n "$extra" ] && echo "$extra"
    echo "---"
    echo "**Why:** synthetic fixture reason."
    echo ""
    echo "**How to apply:** synthetic fixture application."
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

# --- context-store helpers ---

# new_ctx_store <dir> -> a fresh, not-yet-created SESSION_CONTEXT_HOME path
# (the writer scripts bootstrap it on first use).
new_ctx_store() {
  local d="$1"
  rm -rf "$d"
  printf '%s\n' "$d"
}

# iso_to_epoch <UTC-ISO> -- independent (test-local) UTC-ISO -> epoch
# converter, GNU/BSD fallback (does not call save-context.sh's own copy).
iso_to_epoch() {
  local iso="$1"
  date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null || date -u -d "$iso" +%s 2>/dev/null
}

fm_get() {
  # test-local frontmatter getter, independent of save-context.sh's copy --
  # used only to make assertions about produced files, never to drive
  # behavior under test.
  local file="$1" key="$2" first_line line lineno=0 k v
  IFS= read -r first_line < "$file" 2>/dev/null || return 1
  [ "$first_line" = "---" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    [ "$lineno" -eq 1 ] && continue
    [ "$line" = "---" ] && return 1
    case "$line" in
      " "*|$'\t'*) continue ;;
      *:*)
        k="${line%%:*}"
        v="${line#*:}"
        while [ "${v:0:1}" = " " ]; do v="${v:1}"; done
        v="${v%\"}"
        v="${v#\"}"
        if [ "$k" = "$key" ]; then
          printf '%s\n' "$v"
          return 0
        fi
        ;;
    esac
  done < "$file"
  return 1
}

# classify_citation <repo-root> <citation> -> unverifiable-ext | verified |
# stale | malformed. Test-local re-implementation of the ticket-citation
# grammar documented in skills/promote/SKILL.md step 5 (and
# KNOWLEDGE_PLUGIN_SPEC.md's tracking-items boundary) -- doctor's own E-tier
# check is a separate, later addition, not this suite's to ship.
classify_citation() {
  local repo="$1" citation="$2"
  case "$citation" in
    ext:*)
      local id="${citation#ext:}"
      if [[ "$id" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]]; then
        echo "unverifiable-ext"
      else
        echo "malformed"
      fi
      ;;
    local:*)
      local rest path prefix bn full
      rest="${citation#local:}"
      path="${rest%%:*}"
      prefix="${rest#*:}"
      if [ "$path" = "$rest" ]; then echo "malformed"; return; fi
      if [ -z "$prefix" ]; then echo "malformed"; return; fi
      case "$prefix" in *$'\n'*) echo "malformed"; return ;; esac
      case "$path" in /*) echo "malformed"; return ;; esac
      case "$path" in *..*) echo "malformed"; return ;; esac
      bn=$(basename "$path")
      case "$bn" in TODO.md|ISSUES.md) : ;; *) echo "malformed"; return ;; esac
      case "$path" in
        TODO.md|ISSUES.md|docs/TODO.md|docs/ISSUES.md) : ;;
        *) echo "malformed"; return ;;
      esac
      full="$repo/$path"
      if [ -L "$full" ] || [ ! -f "$full" ]; then echo "stale"; return; fi
      if grep -F -q -- "$prefix" "$full"; then echo "verified"; else echo "stale"; fi
      ;;
    *)
      echo "malformed"
      ;;
  esac
}

# ===========================================================================
# 1. HANDOFF FRONTMATTER MECHANICS (save-context.sh)
# ===========================================================================
echo "--- 1. handoff frontmatter mechanics ---"

ctx1="$(new_ctx_store "$TMP/ctx1")"

# 1a. plain save is byte-identical to the pre-Phase-E call (no flags).
printf '# Session Context: demo\nplain body line\n' > "$TMP/plain_in.md"
out=$(SESSION_CONTEXT_HOME="$ctx1" bash "$SAVE" demo "$TMP/plain_in.md" 2>&1); rc=$?
assert_rc "plain_save_exit0" 0 "$rc"
diff -q "$TMP/plain_in.md" "$ctx1/demo.md" > /dev/null 2>&1
assert_rc "plain_save_byte_identical" 0 "$?"

# 1b. new handoff creation: correct fields, expires = created + 14d exactly.
printf 'fresh handoff body\n' > "$TMP/h1_in.md"
before_epoch=$(date -u +%s)
out=$(SESSION_CONTEXT_HOME="$ctx1" bash "$SAVE" h1 "$TMP/h1_in.md" --handoff 2>&1); rc=$?
after_epoch=$(date -u +%s)
assert_rc "new_handoff_exit0" 0 "$rc"
h1v=$(fm_get "$ctx1/h1.md" handoff_version); assert_eq "new_handoff_version_field" "1" "$h1v"
h1k=$(fm_get "$ctx1/h1.md" kind); assert_eq "new_handoff_kind_field" "handoff" "$h1k"
h1created=$(fm_get "$ctx1/h1.md" created)
h1updated=$(fm_get "$ctx1/h1.md" updated)
h1expires=$(fm_get "$ctx1/h1.md" expires)
assert_eq "new_handoff_created_eq_updated" "$h1created" "$h1updated"
created_epoch=$(iso_to_epoch "$h1created")
if [ -n "$created_epoch" ] && [ "$created_epoch" -ge "$before_epoch" ] && [ "$created_epoch" -le "$after_epoch" ]; then
  pass "new_handoff_created_is_now"
else
  fail "new_handoff_created_is_now" "created=$h1created ($created_epoch) not within [$before_epoch,$after_epoch]"
fi
expires_epoch=$(iso_to_epoch "$h1expires")
expected_expires_epoch=$((created_epoch + 14 * 86400))
assert_eq "new_handoff_expires_is_created_plus_14d" "$expected_expires_epoch" "$expires_epoch"
body_tail=$(tail -1 "$ctx1/h1.md")
assert_eq "new_handoff_body_preserved" "fresh handoff body" "$body_tail"

# 1c. same-name regeneration: keeps created, advances updated, keeps expires.
sleep 1
printf 'updated handoff body\n' > "$TMP/h1_in2.md"
out=$(SESSION_CONTEXT_HOME="$ctx1" bash "$SAVE" h1 "$TMP/h1_in2.md" --handoff 2>&1); rc=$?
assert_rc "regen_handoff_exit0" 0 "$rc"
h1created2=$(fm_get "$ctx1/h1.md" created)
h1updated2=$(fm_get "$ctx1/h1.md" updated)
h1expires2=$(fm_get "$ctx1/h1.md" expires)
assert_eq "regen_handoff_created_kept" "$h1created" "$h1created2"
assert_eq "regen_handoff_expires_kept" "$h1expires" "$h1expires2"
if [ "$h1updated2" != "$h1updated" ]; then pass "regen_handoff_updated_advanced"; else fail "regen_handoff_updated_advanced" "updated did not change: $h1updated2"; fi
assert_file_present "regen_handoff_history_created" "$ctx1/.history"

# 1d. --expires replace on a transition.
out=$(SESSION_CONTEXT_HOME="$ctx1" bash "$SAVE" h1 "$TMP/h1_in2.md" --handoff --expires 2030-06-15T12:00:00Z 2>&1); rc=$?
assert_rc "regen_handoff_expires_replace_exit0" 0 "$rc"
h1created3=$(fm_get "$ctx1/h1.md" created)
h1expires3=$(fm_get "$ctx1/h1.md" expires)
assert_eq "regen_handoff_expires_replace_created_kept" "$h1created" "$h1created3"
assert_eq "regen_handoff_expires_replace_value" "2030-06-15T12:00:00Z" "$h1expires3"

# 1e. no-flag regen on an existing handoff refuses -- exact stderr bytes,
# destination byte-unchanged, no spurious history entry.
before_hash=$(sha_of "$ctx1/h1.md")
before_hist_count=$(find "$ctx1/.history" -name 'h1.*.md' 2>/dev/null | wc -l | tr -d ' ')
out=$(SESSION_CONTEXT_HOME="$ctx1" bash "$SAVE" h1 "$TMP/h1_in2.md" 2>&1); rc=$?
assert_rc "plain_regen_on_handoff_exit2" 2 "$rc"
assert_eq "plain_regen_on_handoff_exact_stderr" "handoff exists: re-run with --handoff" "$out"
after_hash=$(sha_of "$ctx1/h1.md")
assert_eq "plain_regen_on_handoff_dest_unchanged" "$before_hash" "$after_hash"
after_hist_count=$(find "$ctx1/.history" -name 'h1.*.md' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "plain_regen_on_handoff_no_spurious_history" "$before_hist_count" "$after_hist_count"

# 1f. plain snapshot upgraded to handoff: created = now (not preserved from
# anywhere, since a plain snapshot has no created metadata).
printf 'plain body for upgrade\n' > "$TMP/up_in.md"
SESSION_CONTEXT_HOME="$ctx1" bash "$SAVE" upme "$TMP/up_in.md" > /dev/null 2>&1
before_epoch=$(date -u +%s)
out=$(SESSION_CONTEXT_HOME="$ctx1" bash "$SAVE" upme "$TMP/up_in.md" --handoff 2>&1); rc=$?
after_epoch=$(date -u +%s)
assert_rc "upgrade_plain_to_handoff_exit0" 0 "$rc"
upk=$(fm_get "$ctx1/upme.md" kind); assert_eq "upgrade_plain_to_handoff_kind" "handoff" "$upk"
upcreated=$(fm_get "$ctx1/upme.md" created)
upcreated_epoch=$(iso_to_epoch "$upcreated")
if [ -n "$upcreated_epoch" ] && [ "$upcreated_epoch" -ge "$before_epoch" ] && [ "$upcreated_epoch" -le "$after_epoch" ]; then
  pass "upgrade_plain_to_handoff_created_is_now"
else
  fail "upgrade_plain_to_handoff_created_is_now" "created=$upcreated not within [$before_epoch,$after_epoch]"
fi

# 1g. bad UTC timestamp format -> exit 2.
out=$(SESSION_CONTEXT_HOME="$ctx1" bash "$SAVE" h1 "$TMP/h1_in2.md" --handoff --expires "not-a-date" 2>&1); rc=$?
assert_rc "bad_expires_format_exit2" 2 "$rc"

# 1h. --expires without --handoff -> exit 2.
out=$(SESSION_CONTEXT_HOME="$ctx1" bash "$SAVE" h1 "$TMP/h1_in2.md" --expires "2030-01-01T00:00:00Z" 2>&1); rc=$?
assert_rc "expires_without_handoff_exit2" 2 "$rc"

# 1i. unknown flag -> exit 2.
out=$(SESSION_CONTEXT_HOME="$ctx1" bash "$SAVE" h1 "$TMP/h1_in2.md" --bogus 2>&1); rc=$?
assert_rc "unknown_flag_exit2" 2 "$rc"

# 1j. tickets fragment passthrough (ext: and local:).
mkdir -p "$TMP/tixrepo/docs"
(cd "$TMP/tixrepo" && git init -q .)
printf -- '- fix the alpha timeout bug\n' > "$TMP/tixrepo/TODO.md"
{
  echo "---"
  echo "tickets:"
  echo "  - ext:ABC-123"
  echo "  - local:TODO.md:fix the alpha timeout bug"
  echo "---"
  echo "body with tickets"
} > "$TMP/tix_in.md"
out=$(SESSION_CONTEXT_HOME="$ctx1" bash "$SAVE" tix "$TMP/tix_in.md" --handoff 2>&1); rc=$?
assert_rc "tickets_passthrough_exit0" 0 "$rc"
assert_contains "tickets_passthrough_ext" "$(cat "$ctx1/tix.md")" "  - ext:ABC-123"
assert_contains "tickets_passthrough_local" "$(cat "$ctx1/tix.md")" "  - local:TODO.md:fix the alpha timeout bug"
assert_contains "tickets_passthrough_body_kept" "$(cat "$ctx1/tix.md")" "body with tickets"

# 1k. malformed tickets fragments -> exit 2, no spurious history, dest
# byte-unchanged when regenerating an existing name.
before_hash=$(sha_of "$ctx1/tix.md")
{ echo "---"; echo "tickets:"; echo "  - ext:ABC-123"; } > "$TMP/tix_unclosed.md" # no closing fence
out=$(SESSION_CONTEXT_HOME="$ctx1" bash "$SAVE" tix "$TMP/tix_unclosed.md" --handoff 2>&1); rc=$?
assert_rc "malformed_tickets_unclosed_fence_exit2" 2 "$rc"
assert_eq "malformed_tickets_unclosed_fence_dest_unchanged" "$before_hash" "$(sha_of "$ctx1/tix.md")"

{ echo "---"; echo "bogus: field"; echo "---"; echo "body"; } > "$TMP/tix_wrongkey.md"
out=$(SESSION_CONTEXT_HOME="$ctx1" bash "$SAVE" tix "$TMP/tix_wrongkey.md" --handoff 2>&1); rc=$?
assert_rc "malformed_tickets_wrong_key_exit2" 2 "$rc"
assert_eq "malformed_tickets_wrong_key_dest_unchanged" "$before_hash" "$(sha_of "$ctx1/tix.md")"

{ echo "---"; echo "tickets:"; echo "not a list item"; echo "---"; echo "body"; } > "$TMP/tix_baditem.md"
out=$(SESSION_CONTEXT_HOME="$ctx1" bash "$SAVE" tix "$TMP/tix_baditem.md" --handoff 2>&1); rc=$?
assert_rc "malformed_tickets_bad_list_item_exit2" 2 "$rc"
assert_eq "malformed_tickets_bad_list_item_dest_unchanged" "$before_hash" "$(sha_of "$ctx1/tix.md")"

# ===========================================================================
# 2. LIST-CONTEXTS.SH COLUMN EXACTNESS
# ===========================================================================
echo "--- 2. list-contexts.sh column exactness ---"

ctx2="$(new_ctx_store "$TMP/ctx2")"
printf 'plain alpha\n' > "$TMP/l_plain.md"
SESSION_CONTEXT_HOME="$ctx2" bash "$SAVE" alpha "$TMP/l_plain.md" > /dev/null 2>&1
printf 'handoff beta\n' > "$TMP/l_h.md"
SESSION_CONTEXT_HOME="$ctx2" bash "$SAVE" beta "$TMP/l_h.md" --handoff > /dev/null 2>&1

list_out=$(SESSION_CONTEXT_HOME="$ctx2" bash "$LISTCTX" 2>&1); rc=$?
assert_rc "list_contexts_exit0" 0 "$rc"

alpha_row=$(printf '%s\n' "$list_out" | grep '^alpha'$'\t')
beta_row=$(printf '%s\n' "$list_out" | grep '^beta'$'\t')
alpha_fields=$(printf '%s' "$alpha_row" | awk -F'\t' '{print NF}')
beta_fields=$(printf '%s' "$beta_row" | awk -F'\t' '{print NF}')
assert_eq "list_plain_row_field_count_unchanged" "4" "$alpha_fields"
assert_eq "list_handoff_row_field_count_plus_two" "6" "$beta_fields"
assert_eq "list_handoff_row_5th_field" "handoff" "$(printf '%s' "$beta_row" | cut -f5)"
beta_expires_expected=$(fm_get "$ctx2/beta.md" expires)
assert_eq "list_handoff_row_6th_field_is_expires" "$beta_expires_expected" "$(printf '%s' "$beta_row" | cut -f6)"
# Plain row's first four fields are exactly name/lines/modified/versions --
# same shape as every pre-Phase-E fixture in test-session-context.sh.
assert_eq "list_plain_row_name_field" "alpha" "$(printf '%s' "$alpha_row" | cut -f1)"
assert_contains "list_plain_row_lines_field" "$(printf '%s' "$alpha_row" | cut -f2)" "lines"
assert_contains "list_plain_row_versions_field" "$(printf '%s' "$alpha_row" | cut -f4)" "versions"

# ===========================================================================
# 3. PASS-THROUGH PROOFS (load/share/diff/remove never special-case
# frontmatter -- they read or copy bytes, never parse them)
# ===========================================================================
echo "--- 3. pass-through proofs ---"

ctx3="$(new_ctx_store "$TMP/ctx3")"
printf 'pass-through body\n' > "$TMP/pt_in.md"
SESSION_CONTEXT_HOME="$ctx3" bash "$SAVE" pt "$TMP/pt_in.md" --handoff > /dev/null 2>&1

load_out=$(SESSION_CONTEXT_HOME="$ctx3" SESSION_CONTEXT_STALE_DAYS=99999 bash "$LOADCTX" pt 2>&1)
raw_bytes=$(cat "$ctx3/pt.md")
assert_eq "load_context_passthrough_byte_identical" "$raw_bytes" "$load_out"

sleep 1
printf 'pass-through body v2\n' > "$TMP/pt_in2.md"
SESSION_CONTEXT_HOME="$ctx3" bash "$SAVE" pt "$TMP/pt_in2.md" --handoff > /dev/null 2>&1
diff_versions=$(SESSION_CONTEXT_HOME="$ctx3" bash "$DIFFCTX" pt --versions 2>&1); rc=$?
assert_rc "diff_context_versions_exit0" 0 "$rc"
assert_contains "diff_context_versions_lists_one" "$diff_versions" "-"
diff_out=$(SESSION_CONTEXT_HOME="$ctx3" bash "$DIFFCTX" pt 2>&1); rc=$?
assert_rc "diff_context_exit0" 0 "$rc"
assert_contains "diff_context_shows_frontmatter_and_body_change" "$diff_out" "pass-through body v2"

# Static proof that share-context.sh / remove-context.sh never parse or
# special-case frontmatter content -- they operate on filenames/existence
# only, so a handoff's frontmatter is opaque to them by construction.
share_frontmatter_hits=$(grep -Eic 'kind: handoff|frontmatter|handoff_version' "$SHARECTX" 2>/dev/null || true)
assert_eq "share_context_never_parses_frontmatter" "0" "$share_frontmatter_hits"
remove_frontmatter_hits=$(grep -Eic 'kind: handoff|frontmatter|handoff_version' "$REMOVECTX" 2>/dev/null || true)
assert_eq "remove_context_never_parses_frontmatter" "0" "$remove_frontmatter_hits"

# remove-context.sh round trip on a handoff file -- deletion is unaffected by
# frontmatter content.
out=$(SESSION_CONTEXT_HOME="$ctx3" bash "$REMOVECTX" pt --confirmed 2>&1); rc=$?
assert_rc "remove_context_handoff_round_trip_exit0" 0 "$rc"
assert_file_absent "remove_context_handoff_snapshot_gone" "$ctx3/pt.md"
remaining_hist=$(find "$ctx3/.history" -name 'pt.*.md' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "remove_context_handoff_history_gone" "0" "$remaining_hist"

# ===========================================================================
# 4. PROMOTION ROUND TRIP A: context (handoff, with ticket citations) ->
# memory (apply path) -> SEPARATELY-CONFIRMED context-source deletion
# ===========================================================================
echo "--- 4. promotion round trip: context handoff -> memory -> context-remove ---"

promo_repo="$TMP/promo_repo_a"
mkdir -p "$promo_repo/docs"
(cd "$promo_repo" && git init -q .)
printf -- '- fix the alpha retry storm\n' > "$promo_repo/TODO.md"
promo_store=$(bootstrap_store "$promo_repo/mem")

ctx4="$(new_ctx_store "$TMP/ctx4")"
{
  echo "---"
  echo "tickets:"
  echo "  - ext:PROJ-42"
  echo "  - local:TODO.md:fix the alpha retry storm"
  echo "---"
  echo "# Session Context: alpha-fix"
  echo ""
  echo "## Where I Left Off"
  echo "Retry storm root-caused; fix ready to promote to memory."
} > "$TMP/handoff_a_in.md"
SESSION_CONTEXT_HOME="$ctx4" bash "$SAVE" alpha_fix "$TMP/handoff_a_in.md" --handoff > /dev/null 2>&1

# Step 1/3 (skill): identify + read the source in full.
handoff_content=$(cat "$ctx4/alpha_fix.md")
assert_contains "roundtripA_source_readable" "$handoff_content" "Retry storm root-caused"
h_tickets_ext=$(fm_get "$ctx4/alpha_fix.md" kind); assert_eq "roundtripA_source_is_handoff" "handoff" "$h_tickets_ext"

# Step 5 (skill): ticket citations, carried through honestly.
c1=$(classify_citation "$promo_repo" "ext:PROJ-42"); assert_eq "roundtripA_citation_ext_unverifiable" "unverifiable-ext" "$c1"
c2=$(classify_citation "$promo_repo" "local:TODO.md:fix the alpha retry storm"); assert_eq "roundtripA_citation_local_verified" "verified" "$c2"

# Step 4/6 (skill): propose + present the memory destination (a CREATE),
# folding the citations into the body as documented.
ei_a=$(sha_of "$promo_store/MEMORY.md")
write_canonical "$TMP/roundtripA_target.md" project "ProjectA Alpha Retry Storm Fix" "root-caused and fixed the alpha retry storm"
cat >> "$TMP/roundtripA_target.md" <<'EOF'

**Cited tracking items:**
- ext:PROJ-42 -- external ticket, unverifiable
- local:TODO.md:fix the alpha retry storm -- verified
EOF
cat > "$TMP/roundtripA_index.md" <<'EOF'
- [ProjectA Alpha Retry Storm Fix](project_alpha_retry_storm_fix.md) -- root-caused and fixed the alpha retry storm
EOF

# Step 7 (skill): write + revalidate.
out=$(bash "$WRITER" apply --store "$promo_store" --target project_alpha_retry_storm_fix.md \
  --staged-target "$TMP/roundtripA_target.md" --staged-index "$TMP/roundtripA_index.md" \
  --expect-target absent --expect-index "$ei_a" 2>&1); rc=$?
assert_rc "roundtripA_apply_exit0" 0 "$rc"
assert_file_present "roundtripA_target_installed" "$promo_store/project_alpha_retry_storm_fix.md"
assert_contains "roundtripA_target_has_citations" "$(cat "$promo_store/project_alpha_retry_storm_fix.md")" "ext:PROJ-42"

gate_lint=$(bash "$LINT" --store "$promo_store" 2>&1); assert_rc "roundtripA_exit_gate_lint_exit0" 0 "$?"
assert_not_contains "roundtripA_exit_gate_no_error" "$gate_lint" "ERROR"$'\t'
gate_bl=$(bash "$BACKLINKS" --store "$promo_store" report 2>&1); assert_rc "roundtripA_exit_gate_backlinks_exit0" 0 "$?"
assert_not_contains "roundtripA_exit_gate_no_dangling" "$gate_bl" "dangling:"

# Step 8/9 (skill): SEPARATE confirmation, then delete the context source.
out=$(SESSION_CONTEXT_HOME="$ctx4" bash "$REMOVECTX" alpha_fix --confirmed 2>&1); rc=$?
assert_rc "roundtripA_context_source_deleted_exit0" 0 "$rc"
assert_file_absent "roundtripA_context_source_gone" "$ctx4/alpha_fix.md"
assert_file_present "roundtripA_memory_destination_still_present" "$promo_store/project_alpha_retry_storm_fix.md"

# ===========================================================================
# 5. PROMOTION ROUND TRIP B: memory -> memory supersession (retire-based
# memory-source case)
# ===========================================================================
echo "--- 5. promotion round trip: memory supersession + retire ---"

super_store=$(bootstrap_store "$TMP/super_repo/mem")
write_canonical "$super_store/project_beta_old_notes.md" project "ProjectB Beta Old Notes" "old, soon-to-be-superseded notes"
chmod 600 "$super_store"/*.md
cat > "$super_store/MEMORY.md" <<'EOF'
- [ProjectB Beta Old Notes](project_beta_old_notes.md) -- old, soon-to-be-superseded notes
EOF
chmod 600 "$super_store/MEMORY.md"

# Step 4 (skill): propose the destination with supersedes:.
ei_b1=$(sha_of "$super_store/MEMORY.md")
write_canonical "$TMP/roundtripB_target.md" project "ProjectB Beta New Notes" "supersedes the old beta notes with corrected guidance" 2026-03-01 2026-03-01 "supersedes: project_beta_old_notes"
cat > "$TMP/roundtripB_index.md" <<'EOF'
- [ProjectB Beta Old Notes](project_beta_old_notes.md) -- old, soon-to-be-superseded notes
- [ProjectB Beta New Notes](project_beta_new_notes.md) -- supersedes the old beta notes with corrected guidance
EOF

# Step 7 (skill): apply the destination first (copy-before-source-stubbing).
out=$(bash "$WRITER" apply --store "$super_store" --target project_beta_new_notes.md \
  --staged-target "$TMP/roundtripB_target.md" --staged-index "$TMP/roundtripB_index.md" \
  --expect-target absent --expect-index "$ei_b1" 2>&1); rc=$?
assert_rc "roundtripB_apply_exit0" 0 "$rc"
assert_file_present "roundtripB_old_still_present_until_retire" "$super_store/project_beta_old_notes.md"
assert_contains "roundtripB_new_has_supersedes" "$(cat "$super_store/project_beta_new_notes.md")" "supersedes: project_beta_old_notes"

# Step 8/9 (skill): SEPARATE confirmation, then retire the memory source.
et_b=$(sha_of "$super_store/project_beta_old_notes.md")
ei_b2=$(sha_of "$super_store/MEMORY.md")
cat > "$TMP/roundtripB_index_after_retire.md" <<'EOF'
- [ProjectB Beta New Notes](project_beta_new_notes.md) -- supersedes the old beta notes with corrected guidance
EOF
out=$(bash "$WRITER" retire --store "$super_store" --slug project_beta_old_notes \
  --staged-index "$TMP/roundtripB_index_after_retire.md" \
  --expect-target "$et_b" --expect-index "$ei_b2" --confirm "$super_store" 2>&1); rc=$?
assert_rc "roundtripB_retire_exit0" 0 "$rc"
assert_file_absent "roundtripB_old_gone_after_retire" "$super_store/project_beta_old_notes.md"
assert_not_contains "roundtripB_index_no_old_row" "$(cat "$super_store/MEMORY.md")" "project_beta_old_notes.md"
assert_contains "roundtripB_index_has_new_row" "$(cat "$super_store/MEMORY.md")" "project_beta_new_notes.md"

gate_lint_b=$(bash "$LINT" --store "$super_store" 2>&1); assert_rc "roundtripB_exit_gate_lint_exit0" 0 "$?"
assert_not_contains "roundtripB_exit_gate_no_error" "$gate_lint_b" "ERROR"$'\t'
gate_idx_b=$(bash "$INDEXTOOL" --store "$super_store" 2>&1); assert_rc "roundtripB_exit_gate_index_exit0" 0 "$?"
assert_eq "roundtripB_exit_gate_index_no_drift" "" "$gate_idx_b"

# ===========================================================================
# 6. DOCS-DESTINATION PROPOSAL-ONLY PROOF (no docs write happens)
# ===========================================================================
echo "--- 6. docs-destination proposal-only proof ---"

docs_repo="$TMP/docs_repo"
mkdir -p "$docs_repo/docs/decisions"
(cd "$docs_repo" && git init -q . && git add -A && git commit -q -m init --allow-empty)
repo_hash_before=$(tree_hash "$docs_repo")

# Simulate skill step 4's docs leg: compose the complete proposed content as
# a plain string, never touching the filesystem.
proposed_dec_content=$(cat <<'EOF'
# DEC-2026-03-01-adopt-alpha-retry-policy

**Status**: Proposed (never written by /knowledge:promote)
EOF
)
assert_contains "docs_proposal_composed_in_memory" "$proposed_dec_content" "DEC-2026-03-01-adopt-alpha-retry-policy"

repo_hash_after=$(tree_hash "$docs_repo")
assert_eq "docs_proposal_no_write_happened" "$repo_hash_before" "$repo_hash_after"
assert_file_absent "docs_proposal_dec_file_not_created" "$docs_repo/docs/decisions/DEC-2026-03-01-adopt-alpha-retry-policy.md"

skill_content=$(cat "$PROMOTE_SKILL_MD")
assert_contains "promote_skill_states_docs_never_written" "$skill_content" "never written by this skill"
assert_not_contains "promote_skill_never_invokes_docs_write" "$skill_content" 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/docs-write.sh"'

# ===========================================================================
# 7. ABORTED-APPROVAL INVARIANT: both stores byte-identical if the user
# declines before any write/delete call is made.
# ===========================================================================
echo "--- 7. aborted-approval invariant (both stores) ---"

abort_store=$(bootstrap_store "$TMP/abort_repo/mem")
write_canonical "$abort_store/project_gamma_notes.md" project "ProjectA Gamma Notes" "fixture for aborted approval"
chmod 600 "$abort_store"/*.md
cat > "$abort_store/MEMORY.md" <<'EOF'
- [ProjectA Gamma Notes](project_gamma_notes.md) -- fixture for aborted approval
EOF
chmod 600 "$abort_store/MEMORY.md"

ctx7="$(new_ctx_store "$TMP/ctx7")"
printf 'gamma handoff body\n' > "$TMP/gamma_in.md"
SESSION_CONTEXT_HOME="$ctx7" bash "$SAVE" gamma "$TMP/gamma_in.md" --handoff > /dev/null 2>&1

mem_hash_before=$(tree_hash "$abort_store")
ctx_hash_before=$(tree_hash "$ctx7")

# Simulate skill steps 1-6 (identify, resolve, read, propose, build the
# staged files) -- every staged file lands in $TMP, never inside either
# store. The user declines at step 6; no apply/retire/remove-context call is
# ever made.
bash "$LINT" --store "$abort_store" > /dev/null 2>&1
bash "$INDEXTOOL" --store "$abort_store" > /dev/null 2>&1
bash "$BACKLINKS" --store "$abort_store" report > /dev/null 2>&1
bash "$SEARCH" --store "$abort_store" gamma > /dev/null 2>&1
cat "$abort_store/MEMORY.md" > /dev/null
SESSION_CONTEXT_HOME="$ctx7" bash "$LISTCTX" > /dev/null 2>&1
cat "$ctx7/gamma.md" > /dev/null
write_canonical "$TMP/abort_staged_target.md" project "ProjectA Gamma Notes" "would have been updated, but declined"
cat > "$TMP/abort_staged_index.md" <<'EOF'
- [ProjectA Gamma Notes](project_gamma_notes.md) -- would have been updated, but declined
EOF
# (User declines here -- no memory-write.sh / remove-context.sh call.)

mem_hash_after=$(tree_hash "$abort_store")
ctx_hash_after=$(tree_hash "$ctx7")
assert_eq "aborted_approval_memory_store_byte_identical" "$mem_hash_before" "$mem_hash_after"
assert_eq "aborted_approval_context_store_byte_identical" "$ctx_hash_before" "$ctx_hash_after"

# ===========================================================================
# 8. REVIEWER-ROLE / UNRESOLVED-IDENTITY REFUSAL -- EXECUTED on both apply
# and retire (the memory legs of promotion)
# ===========================================================================
echo "--- 8. reviewer role / unresolved identity refusal on apply and retire ---"

role_store=$(bootstrap_store "$TMP/role_repo/mem")
write_canonical "$role_store/project_delta_notes.md" project "ProjectA Delta Notes" "fixture for role refusal"
chmod 600 "$role_store"/*.md
cat > "$role_store/MEMORY.md" <<'EOF'
- [ProjectA Delta Notes](project_delta_notes.md) -- fixture for role refusal
EOF
chmod 600 "$role_store/MEMORY.md"
ei_role=$(sha_of "$role_store/MEMORY.md")

write_canonical "$TMP/role_new_target.md" project "ProjectA Delta New Item" "would-be new item"
cat > "$TMP/role_new_index.md" <<'EOF'
- [ProjectA Delta Notes](project_delta_notes.md) -- fixture for role refusal
- [ProjectA Delta New Item](project_delta_new_item.md) -- would-be new item
EOF

out=$(KNOWLEDGE_PANE_NAME=fleet-reviewer bash "$WRITER" apply --store "$role_store" --target project_delta_new_item.md \
  --staged-target "$TMP/role_new_target.md" --staged-index "$TMP/role_new_index.md" \
  --expect-target absent --expect-index "$ei_role" 2>&1); rc=$?
assert_rc "promote_apply_reviewer_refused_exit6" 6 "$rc"
assert_contains "promote_apply_reviewer_refused_message" "$out" "reviewer role: memory writes refused"
assert_file_absent "promote_apply_reviewer_refused_no_target" "$role_store/project_delta_new_item.md"

out=$(env -u KNOWLEDGE_PANE_NAME -u SESSION_CHAT_PANE_NAME TMUX=/fake/sock,1,1 bash "$WRITER" apply --store "$role_store" --target project_delta_new_item.md \
  --staged-target "$TMP/role_new_target.md" --staged-index "$TMP/role_new_index.md" \
  --expect-target absent --expect-index "$ei_role" 2>&1); rc=$?
assert_rc "promote_apply_unresolved_identity_exit6" 6 "$rc"
assert_contains "promote_apply_unresolved_identity_message" "$out" "unresolved pane identity"

et_role=$(sha_of "$role_store/project_delta_notes.md")
cat > "$TMP/role_retire_index.md" <<'EOF'
EOF
out=$(KNOWLEDGE_PANE_NAME=fleet-reviewer bash "$WRITER" retire --store "$role_store" --slug project_delta_notes \
  --staged-index "$TMP/role_retire_index.md" --expect-target "$et_role" --expect-index "$ei_role" \
  --confirm "$role_store" 2>&1); rc=$?
assert_rc "promote_retire_reviewer_refused_exit6" 6 "$rc"
assert_contains "promote_retire_reviewer_refused_message" "$out" "reviewer role: memory writes refused"
assert_file_present "promote_retire_reviewer_refused_source_kept" "$role_store/project_delta_notes.md"

out=$(env -u KNOWLEDGE_PANE_NAME -u SESSION_CHAT_PANE_NAME TMUX=/fake/sock,1,1 bash "$WRITER" retire --store "$role_store" --slug project_delta_notes \
  --staged-index "$TMP/role_retire_index.md" --expect-target "$et_role" --expect-index "$ei_role" \
  --confirm "$role_store" 2>&1); rc=$?
assert_rc "promote_retire_unresolved_identity_exit6" 6 "$rc"
assert_contains "promote_retire_unresolved_identity_message" "$out" "unresolved pane identity"
assert_file_present "promote_retire_unresolved_identity_source_kept" "$role_store/project_delta_notes.md"

# ===========================================================================
# 9. TICKET-CITATION FIXTURES (grammar validation, test-local per the
# hand-back note -- doctor's own E-tier check ships separately)
# ===========================================================================
echo "--- 9. ticket-citation fixtures ---"

tixrepo2="$TMP/tixrepo2"
mkdir -p "$tixrepo2/docs"
(cd "$tixrepo2" && git init -q .)
printf -- '- fix the timeout bug in the alpha worker\n' > "$tixrepo2/TODO.md"
printf -- '- known issue: beta race condition\n' > "$tixrepo2/docs/ISSUES.md"

assert_eq "citation_valid_ext" "unverifiable-ext" "$(classify_citation "$tixrepo2" "ext:ABC-123")"
assert_eq "citation_malformed_ext_lowercase" "malformed" "$(classify_citation "$tixrepo2" "ext:abc-123")"
assert_eq "citation_valid_local_verified_root" "verified" "$(classify_citation "$tixrepo2" "local:TODO.md:fix the timeout bug in the alpha worker")"
assert_eq "citation_valid_local_verified_docs" "verified" "$(classify_citation "$tixrepo2" "local:docs/ISSUES.md:known issue: beta race condition")"
assert_eq "citation_stale_local_prefix_absent" "stale" "$(classify_citation "$tixrepo2" "local:TODO.md:this text is nowhere in the file")"
assert_eq "citation_malformed_traversal" "malformed" "$(classify_citation "$tixrepo2" "local:../TODO.md:fix")"
assert_eq "citation_malformed_absolute_path" "malformed" "$(classify_citation "$tixrepo2" "local:/etc/TODO.md:fix")"
assert_eq "citation_malformed_unrecognized_tracker_file" "malformed" "$(classify_citation "$tixrepo2" "local:NOTES.md:fix")"
assert_eq "citation_malformed_empty_prefix" "malformed" "$(classify_citation "$tixrepo2" "local:TODO.md:")"
assert_eq "citation_malformed_no_second_colon" "malformed" "$(classify_citation "$tixrepo2" "local:TODO.md")"
assert_eq "citation_malformed_unknown_scheme" "malformed" "$(classify_citation "$tixrepo2" "bogus:whatever")"

# ===========================================================================
# 10. EXPIRED HANDOFF: SURFACED, NEVER AUTO-DELETED
# ===========================================================================
echo "--- 10. expired handoff surfaced but never auto-deleted ---"

ctx10="$(new_ctx_store "$TMP/ctx10")"
printf 'expired handoff body\n' > "$TMP/exp_in.md"
SESSION_CONTEXT_HOME="$ctx10" bash "$SAVE" expme "$TMP/exp_in.md" --handoff --expires 2020-01-01T00:00:00Z > /dev/null 2>&1

list_exp=$(SESSION_CONTEXT_HOME="$ctx10" bash "$LISTCTX" 2>&1)
assert_contains "expired_handoff_listed" "$list_exp" "expme"$'\t'
assert_contains "expired_handoff_expires_shown" "$list_exp" "2020-01-01T00:00:00Z"
assert_file_present "expired_handoff_present_before_reads" "$ctx10/expme.md"

SESSION_CONTEXT_HOME="$ctx10" SESSION_CONTEXT_STALE_DAYS=99999 bash "$LOADCTX" expme > /dev/null 2>&1
SESSION_CONTEXT_HOME="$ctx10" bash "$LISTCTX" > /dev/null 2>&1
assert_file_present "expired_handoff_never_auto_deleted_by_list_or_load" "$ctx10/expme.md"

if [ -f "$HERE/doctor.sh" ]; then
  hash_doctor_before=$(tree_hash "$ctx10")
  SESSION_CONTEXT_HOME="$ctx10" bash "$HERE/doctor.sh" > /dev/null 2>&1
  hash_doctor_after=$(tree_hash "$ctx10")
  assert_eq "expired_handoff_never_auto_deleted_by_doctor" "$hash_doctor_before" "$hash_doctor_after"
fi

# ===========================================================================
# 11. ZERO-NETWORK-EGRESS STATIC CHECK (Phase E surfaces)
# ===========================================================================
echo "--- 11. zero network egress (static) ---"

egress_hit=""
for f in "$SAVE" "$LISTCTX" "$PROMOTE_SKILL_MD" "$PROMOTE_COMMAND_MD" "$CONTEXT_GENERATE_MD" "$CONTEXT_LIST_MD"; do
  if grep -Eniq 'curl|wget|[^a-zA-Z]nc[[:space:]]|http\.client|urllib|requests\.|socket\.connect' "$f" 2>/dev/null; then
    egress_hit="$egress_hit $f"
  fi
done
if [ -z "$egress_hit" ]; then
  pass "no_network_client_invocations_in_promotion_surfaces"
else
  fail "no_network_client_invocations_in_promotion_surfaces" "matches in:$egress_hit"
fi

# ===========================================================================
# summary
# ===========================================================================
echo ""
echo "=== promotion tests: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  echo "Failures:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
