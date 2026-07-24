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
# inject-recall — per-mode gate (0.2.1). One env var selects WHICH injections
# run, so a provider that already supplies the index itself (Claude with
# autoMemoryDirectory pointed at the store) can keep per-prompt recall without
# paying for a duplicate SessionStart index.
# ---------------------------------------------------------------------------
gate_probe() { # $1=gate value  $2=mode flag -> prints output
  if [ "$2" = "--prompt" ]; then
    mkprompt "how do I run the zephyr calibration on the widget" \
      | KNOWLEDGE_MEMORY_HOME="$store" KNOWLEDGE_AUTO_RECALL="$1" bash "$INJECT" --prompt
  else
    KNOWLEDGE_MEMORY_HOME="$store" KNOWLEDGE_AUTO_RECALL="$1" bash "$INJECT" --session-start
  fi
}

# session-only tokens: index fires, prompt recall stays silent
for g in session session-start index SESSION Session-Start; do
  assert_nonempty "inject_gate_${g}_session_fires"  "$(gate_probe "$g" --session-start)"
  assert_empty    "inject_gate_${g}_prompt_silent"  "$(gate_probe "$g" --prompt)"
done

# prompt-only tokens: recall fires, index stays silent
for g in prompt recall user-prompt PROMPT Recall; do
  assert_nonempty "inject_gate_${g}_prompt_fires"   "$(gate_probe "$g" --prompt)"
  assert_empty    "inject_gate_${g}_session_silent" "$(gate_probe "$g" --session-start)"
done

# both-tokens and OFF-tokens keep their pre-0.2.1 meaning
for g in 1 yes on true all both; do
  assert_nonempty "inject_gate_${g}_session_fires" "$(gate_probe "$g" --session-start)"
  assert_nonempty "inject_gate_${g}_prompt_fires"  "$(gate_probe "$g" --prompt)"
done
for g in 0 no off false FALSE Off; do
  assert_empty "inject_gate_${g}_session_silent" "$(gate_probe "$g" --session-start)"
  assert_empty "inject_gate_${g}_prompt_silent"  "$(gate_probe "$g" --prompt)"
done

# BACKWARD COMPATIBILITY: an unrecognized non-empty value must still mean BOTH,
# so a pre-0.2.1 setting like KNOWLEDGE_AUTO_RECALL=enabled never silently
# disables recall on upgrade.
assert_nonempty inject_gate_unknown_session_fires "$(gate_probe enabled --session-start)"
assert_nonempty inject_gate_unknown_prompt_fires  "$(gate_probe enabled --prompt)"

# WHITESPACE TRIM (0.2.1): a stray leading/trailing space must not flip an OFF
# value into the unrecognized-means-both branch — a space must never ENABLE
# recall. Recognized tokens with surrounding whitespace resolve to their mode.
for g in "off " " off" "0 " " false"; do
  assert_empty "inject_gate_ws_off_session_silent[$g]" "$(gate_probe "$g" --session-start)"
  assert_empty "inject_gate_ws_off_prompt_silent[$g]"  "$(gate_probe "$g" --prompt)"
done
assert_nonempty inject_gate_ws_session_fires  "$(gate_probe "session " --session-start)"
assert_empty    inject_gate_ws_session_prompt "$(gate_probe " session" --prompt)"
assert_nonempty inject_gate_ws_prompt_fires   "$(gate_probe " prompt " --prompt)"
assert_empty    inject_gate_ws_prompt_session "$(gate_probe "prompt " --session-start)"
# Internal-space value stays unrecognized => both (never strips down to a token).
assert_nonempty inject_gate_ws_internal_session "$(gate_probe "yes please" --session-start)"
assert_nonempty inject_gate_ws_internal_prompt  "$(gate_probe "yes please" --prompt)"

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

# ===========================================================================
# 0.3 autonomous capture — memory-auto-capture.sh wrapper (A4–A19) + the 0.3.2
# opt-in prompt-hook snippet & default-hooks.json assertions (A1/A2/A3/A15/A20/
# A21). See the spec's "0.3 acceptance matrix".
# ===========================================================================
AUTOCAP="$HERE/memory-auto-capture.sh"
ASSET="$HERE/../assets/capture-stop-hook.md"   # 0.3.2 Claude opt-in prompt-hook snippet
export KNOWLEDGE_PANE_NAME=test-executor   # non-reviewer identity so writes proceed

# a fresh capture store + a batch dir of staged candidates
capstore="$(bootstrap_store "$TMP/cap")"
inbox_count() { bash "$REMEMBER" --store "$capstore" --list 2>/dev/null | grep -c . || true; }
mk_batch() { local d="$1"; rm -rf "$d"; mkdir -p "$d"; }

# ---- A4: zero candidates (empty batch dir) → silent success, nothing written
b="$TMP/b_empty"; mk_batch "$b"
out="$(bash "$AUTOCAP" --store "$capstore" --batch-dir "$b" 2>/dev/null)"; rc=$?
assert_rc    ac_A4_zero_rc 0 "$rc"
assert_empty ac_A4_zero_stdout "$out"
assert_eq    ac_A4_zero_inbox 0 "$(inbox_count)"

# ---- A5: N ≤ LIMIT valid candidates → all queued to .inbox, none elsewhere
b="$TMP/b_ok"; mk_batch "$b"
stage_candidate "$b/1.md" auto_capture "Cap One"   "first durable project invariant here" project
stage_candidate "$b/2.md" auto_capture "Cap Two"   "second durable project invariant here" project
before_files="$(find "$capstore" -type f | LC_ALL=C sort | grep -v '/\.inbox/' | wc -l | tr -d ' ')"
out="$(KNOWLEDGE_AUTO_CAPTURE_LIMIT=3 bash "$AUTOCAP" --store "$capstore" --batch-dir "$b" 2>/dev/null)"; rc=$?
assert_rc ac_A5_rc 0 "$rc"
assert_eq ac_A5_two_captured 2 "$(printf '%s\n' "$out" | grep -c '^captured: ')"
assert_eq ac_A5_inbox_two 2 "$(inbox_count)"
after_noninbox="$(find "$capstore" -type f | LC_ALL=C sort | grep -v '/\.inbox/' | wc -l | tr -d ' ')"
assert_eq ac_A5_nothing_outside_inbox "$before_files" "$after_noninbox"

# ---- A18: captured file carries the stable source: auto_capture
one_inbox="$(find "$capstore/.inbox" -name '*.md' | head -1)"
assert_contains ac_A18_stable_source "$(cat "$one_inbox" 2>/dev/null)" "source: auto_capture"

# ---- A9: duplicate content-hash → idempotent no-op (re-run same batch)
out="$(bash "$AUTOCAP" --store "$capstore" --batch-dir "$b" 2>/dev/null)"
assert_eq ac_A9_idempotent_inbox 2 "$(inbox_count)"

# ---- A10: name/description already pending/indexed → skip/warn
b2="$TMP/b_dup"; mk_batch "$b2"
stage_candidate "$b2/x.md" auto_capture "Cap One" "a different body but same name as pending" project
err="$(bash "$AUTOCAP" --store "$capstore" --batch-dir "$b2" 2>&1 >/dev/null)"
assert_contains ac_A10_dup_warn "$err" "duplicate"
assert_eq       ac_A10_no_new_write 2 "$(inbox_count)"

# ---- A6: > LIMIT candidates → exactly LIMIT queued, visible overflow count
capstore2="$(bootstrap_store "$TMP/cap2")"
b="$TMP/b_over"; mk_batch "$b"
for i in 1 2 3 4 5; do stage_candidate "$b/$i.md" auto_capture "Over $i" "overflow durable invariant number $i" project; done
err="$(KNOWLEDGE_AUTO_CAPTURE_LIMIT=3 bash "$AUTOCAP" --store "$capstore2" --batch-dir "$b" 2>&1 >/dev/null)"
n2="$(bash "$REMEMBER" --store "$capstore2" --list 2>/dev/null | grep -c . || true)"
assert_eq       ac_A6_exactly_limit 3 "$n2"
assert_contains ac_A6_visible_overflow "$err" "received 5 candidate"

# ---- A7: pending inbox ≥ MAX_PENDING → skip whole pass, nothing deleted
b="$TMP/b_full"; mk_batch "$b"
stage_candidate "$b/n.md" auto_capture "Would Be New" "should not be captured while inbox full" project
err="$(KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING=3 bash "$AUTOCAP" --store "$capstore2" --batch-dir "$b" 2>&1 >/dev/null)"; rc=$?
assert_rc       ac_A7_rc 0 "$rc"
assert_contains ac_A7_skip_msg "$err" "MAX_PENDING"
assert_eq       ac_A7_nothing_added 3 "$(bash "$REMEMBER" --store "$capstore2" --list 2>/dev/null | grep -c . || true)"

# ---- A8: candidate exceeds MAX_BYTES → rejected, fail closed
capstore3="$(bootstrap_store "$TMP/cap3")"
b="$TMP/b_big"; mk_batch "$b"
big="$(head -c 5000 < /dev/zero | tr '\0' x)"
stage_candidate "$b/big.md" auto_capture "Big Cap" "$big" project
err="$(KNOWLEDGE_AUTO_CAPTURE_MAX_BYTES=4096 bash "$AUTOCAP" --store "$capstore3" --batch-dir "$b" 2>&1 >/dev/null)"
assert_contains ac_A8_reject_msg "$err" "oversized"
assert_eq       ac_A8_no_write 0 "$(bash "$REMEMBER" --store "$capstore3" --list 2>/dev/null | grep -c . || true)"

# ---- A11: named secret fixtures → rejected by the deterministic scanner
for pat in "ghp_abcdefghijklmnopqrstuvwxyz012345" "sk-abcdefghijklmnop01234567" "AKIAABCDEFGHIJKLMNOP"; do
  b="$TMP/b_sec"; mk_batch "$b"
  stage_candidate "$b/s.md" auto_capture "Secret Cap" "leaks a secret $pat inline" project
  err="$(bash "$AUTOCAP" --store "$capstore3" --batch-dir "$b" 2>&1 >/dev/null)"
  assert_contains "ac_A11_secret_[$pat]" "$err" "secret pattern"
done
# PEM block
b="$TMP/b_pem"; mk_batch "$b"
{ echo "---"; echo "source: auto_capture"; echo "sensitivity: normal"; echo "proposed:"; echo "  schema_version: \"1\""; echo "  name: Pem Cap"; echo "  description: has a private key"; echo "  metadata:"; echo "    type: project"; echo "---"; echo "-----BEGIN RSA PRIVATE KEY-----"; echo "MIIfake"; echo "-----END RSA PRIVATE KEY-----"; } > "$b/pem.md"
err="$(bash "$AUTOCAP" --store "$capstore3" --batch-dir "$b" 2>&1 >/dev/null)"
assert_contains ac_A11_pem "$err" "secret pattern"
assert_eq       ac_A11_no_write 0 "$(bash "$REMEMBER" --store "$capstore3" --list 2>/dev/null | grep -c . || true)"

# ---- A19: malformed candidate → rejected with NO write
b="$TMP/b_bad"; mk_batch "$b"
printf -- '---\nsource: auto_capture\nnot a real envelope\n' > "$b/bad.md"
err="$(bash "$AUTOCAP" --store "$capstore3" --batch-dir "$b" 2>&1 >/dev/null)"
assert_contains ac_A19_malformed "$err" "malformed"
assert_eq       ac_A19_no_write 0 "$(bash "$REMEMBER" --store "$capstore3" --list 2>/dev/null | grep -c . || true)"

# ---- A12: reviewer role → fail closed (exit 6), no write
capstore4="$(bootstrap_store "$TMP/cap4")"
b="$TMP/b_rev"; mk_batch "$b"
stage_candidate "$b/r.md" auto_capture "Rev Cap" "should be refused under reviewer role" project
out="$(KNOWLEDGE_PANE_NAME=fleet-reviewer bash "$AUTOCAP" --store "$capstore4" --batch-dir "$b" 2>/dev/null)"; rc=$?
assert_rc ac_A12_exit6 6 "$rc"
assert_eq ac_A12_no_write 0 "$(bash "$REMEMBER" --store "$capstore4" --list 2>/dev/null | grep -c . || true)"

# ---- A13: unsafe/absent store → fail SAFE (exit 0, no write)
out="$(bash "$AUTOCAP" --store "$TMP/does-not-exist" --staged "$b/r.md" 2>/dev/null)"; rc=$?
assert_rc    ac_A13_safe_rc 0 "$rc"
assert_empty ac_A13_safe_stdout "$out"

# ---- A14: only .inbox/<sha256>.md may change (before/after path+hash snapshot)
capstore5="$(bootstrap_store "$TMP/cap5")"
snap() { find "$1" -type f ! -path '*/.inbox/*' -exec shasum -a 256 {} \; 2>/dev/null | LC_ALL=C sort; }
snap_before="$(snap "$capstore5")"
b="$TMP/b_a14"; mk_batch "$b"
stage_candidate "$b/c.md" auto_capture "A14 Cap" "verifies only inbox changes on capture" project
bash "$AUTOCAP" --store "$capstore5" --batch-dir "$b" >/dev/null 2>&1
snap_after="$(snap "$capstore5")"
assert_eq ac_A14_noninbox_unchanged "$snap_before" "$snap_after"
assert_eq ac_A14_inbox_got_one 1 "$(bash "$REMEMBER" --store "$capstore5" --list 2>/dev/null | grep -c . || true)"

# ===========================================================================
# 0.3.2 Stop-hook red-error fix: the autonomous-capture command hook + its
# decision:block shape are RETIRED. Default hooks.json ships no capture hook;
# autonomous capture is a Claude-only opt-in `type:"prompt"` snippet asset.
# ===========================================================================

# ---- A1/A20: default hooks.json Stop ships NO autonomous-capture hook --------
hooks_json="$HERE/../hooks/hooks.json"
stop_cmds="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for grp in d["hooks"].get("Stop",[]):
    for h in grp.get("hooks",[]):
        print(h.get("type","")+"|"+h.get("command",""))
' "$hooks_json" 2>/dev/null)"
assert_not_contains ac_A1_no_capture_in_default "$stop_cmds" "request-capture"
assert_not_contains ac_A15_no_decision_default  "$stop_cmds" "capture-stop-hook"
assert_contains     ac_A20_nudge_is_default     "$stop_cmds" "nudge-consolidate.sh"
assert_eq           ac_A20_single_stop_hook 1   "$(printf '%s\n' "$stop_cmds" | grep -c .)"
assert_eq           ac_A20_reqcap_deleted   0   "$([ -e "$HERE/request-capture.sh" ] && echo 1 || echo 0)"

# ---- A2/A3/A15/A21: Claude opt-in type:"prompt" capture-stop-hook snippet -----
assert_eq ac_A2_asset_exists 1 "$([ -f "$ASSET" ] && echo 1 || echo 0)"
hook_shape="$(python3 - "$ASSET" <<'PY'
import json,re,sys
text=open(sys.argv[1]).read()
m=re.search(r"```json\n(.*?)\n```", text, re.S)
if not m:
    print("NO_JSON_BLOCK"); sys.exit(0)
try:
    d=json.loads(m.group(1))
    h=d["hooks"]["Stop"][0]["hooks"][0]
except Exception as e:
    print("BAD:%s"%e); sys.exit(0)
p=h.get("prompt","")
f=["type="+h.get("type","")]
f.append("has_ok" if '"ok"' in p else "no_ok")
f.append("has_reason" if '"reason"' in p else "no_reason")
f.append("has_decision" if '"decision"' in p else "no_decision")
f.append("has_guard" if "stop_hook_active" in p else "no_guard")
f.append("has_envelope" if "source: auto_capture" in p else "no_envelope")
f.append("has_sensitivity" if "normal" in p else "no_sensitivity")
f.append("has_type_enum" if "reference" in p else "no_type_enum")
f.append("has_tags_sibling" if "sibling of metadata" in p else "no_tags_sibling")
f.append("has_wrapper" if "memory-auto-capture.sh" in p else "no_wrapper")
print(";".join(f))
PY
)"
assert_contains ac_A2_type_prompt    "$hook_shape" "type=prompt"
assert_contains ac_A2_ok_shape       "$hook_shape" "has_ok"
assert_contains ac_A2_reason_shape   "$hook_shape" "has_reason"
assert_contains ac_A15_no_decision   "$hook_shape" "no_decision"   # NOT decision:block
assert_contains ac_A3_loop_guard     "$hook_shape" "has_guard"     # stop_hook_active -> ok:true
assert_contains ac_A21_envelope      "$hook_shape" "has_envelope"
assert_contains ac_A21_sensitivity   "$hook_shape" "has_sensitivity"
assert_contains ac_A21_type_enum     "$hook_shape" "has_type_enum"
assert_contains ac_A21_tags_sibling  "$hook_shape" "has_tags_sibling"
assert_contains ac_A2_routes_wrapper "$hook_shape" "has_wrapper"

# ---- A17: after capture, the nudge sees pending inbox items (combined flow) ---
# On Claude the opt-in prompt hook runs the capture pass in the agent's
# continuation; by the re-entrant Stop the inbox is populated and the (separate,
# non-blocking) nudge surfaces it — modelled here by staging then nudging.
nud="$(cd "$TMP/cap" && KNOWLEDGE_CONSOLIDATE_NUDGE=1 KNOWLEDGE_MEMORY_HOME="$capstore" bash "$NUDGE" --stop-json 2>/dev/null)"
assert_contains ac_A17_nudge_sees_pending "$nud" "pending memory candidate"

# ---------------------------------------------------------------------------
# syntax + zero-egress on the shipped hook scripts
# ---------------------------------------------------------------------------
for s in "$INJECT" "$NUDGE" "$LINT" "$AUTOCAP"; do
  if bash -n "$s" 2>/dev/null; then pass "bash_n_$(basename "$s")"; else fail "bash_n_$(basename "$s")" "syntax error"; fi
done
# ---- A16: zero network egress across the capture scripts + opt-in snippet -----
if grep -Eq 'curl|wget|http\.client|urllib|requests\.|socket\.connect' "$INJECT" "$NUDGE" "$AUTOCAP" "$ASSET"; then
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
