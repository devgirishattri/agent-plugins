#!/usr/bin/env bash
# test-session-workspace.sh — session-workspace plugin tests. This file is
# mirrored byte-for-byte into both provider trees (plugins/ and codex/plugins/);
# validate-release.sh enforces that every non-test script basename matches.
#
# Phase A covered only the scaffold contract (parses, --contract handshake,
# every verb fails clearly as "not implemented"). Phase B lands real config
# load/validation and a mutation-free `workspace-plan`, so this file now
# additionally proves:
#   - the two golden fixtures (fixtures/valid/project-a.json,
#     fixtures/valid/project-d.json) validate clean and produce a plan
#   - every validation rule in validate-config.sh / validate-structural.jq
#     has a failing fixture that trips exactly that rule
#     (fixtures/invalid/*.json, plus filesystem-dependent rules built here:
#     cwd path escape, cwd symlink escape, and the five secrets.env_file
#     gates)
#   - `workspace-plan` never touches tmux and never writes under
#     $XDG_STATE_HOME, proving the Phase B "mutation-free" contract
#   - `workspace.sh plan` (the dispatcher path) and workspace-plan.sh
#     (the standalone script) agree
#   - only `doctor` remains a Phase A stub (it lands in Phase F)
#
# Phase C lands adapters.sh (runtime argv construction, canonical env
# rendering, grants, secrets) and this file additionally proves:
#   - exact argv against stub claude/codex executables on PATH (never a real
#     agent), including inherit/omitted => no flag, and dangerous-flag
#     rejection for both runtimes
#   - special characters (space, apostrophe, ;, $, backtick) survive a value
#     as ONE inert argv element
#   - grants: a reviewer role that omits "memory" never receives an
#     --add-dir for it
#   - memory: executor/reviewer of one component share a shard; the
#     empty-after-stripping case falls back to "master"
#   - env-exports: canonical `export K=V; ...` form, engine-always identity
#     vars win even if a config tries to override them, coordination vars
#     only appear when pinned, KNOWLEDGE_AUTO_* engine defaults are present
#   - secrets: never appear in plan/argv/env-exports/log output — grepped
#     explicitly; caller environment wins over the env file; a role outside
#     secrets.visible_to_roles is refused
#
# Phase D lands the tmux lifecycle (tmux-lib.sh, lifecycle.sh, and
# workspace-{start,status,stop,reconcile,restart}.sh). Its tests run against a
# COMPLETELY ISOLATED tmux server — a private $TMUX_TMPDIR plus a private
# `-S <socket>` under the test tmpdir, reached through a PATH wrapper that
# force-injects that socket into every tmux call the engine makes, with $TMUX
# unset. They prove:
#   - start creates the full planned topology; a second start is idempotent
#     (healthy panes kept, pane ids unchanged, nothing respawned)
#   - the split_tree builder yields exactly the declared node count, maps
#     pane_order onto the configured panes, produces the declared geometry,
#     emits `-l <pct>%` (never the deprecated `-p`), and masks the window's
#     after-split-window hook during construction while RESTORING the user's
#     pre-existing hook array afterwards
#   - an unmanaged pane occupying a planned slot fails that slot and is never
#     renamed/marked/respawned; --adopt without --confirmed is refused; and
#     `reconcile --apply --adopt --confirmed` prints the adoption plan BEFORE
#     it claims the pane
#   - reconcile is dry-run by default and, with --apply, repairs only the
#     missing managed pane while healthy siblings keep their pane ids
#   - foreign sessions and surplus panes inside a managed window survive
#   - the project lock blocks a concurrent start, reclaims a stale lock whose
#     holder pid is dead, and serializes two racing starts
#   - layout save/restore round-trips exactly, into an owner-only state file
#   - status mutates nothing; stop refuses without --confirmed, kills only
#     marker-carrying sessions, and leaves a same-named UNMANAGED session alone
#   - env.groups.*.pin_to_session actually mirrors the pinned group values and
#     the stores.pin coordination vars into the tmux SESSION environment, so a
#     pane the USER creates by hand afterwards inherits them; pin_to_session:
#     false mirrors nothing; no secret ever reaches the session env (plain or
#     hidden, with a positive control that a secret was really delivered); the
#     per-pane identity vars and pane_name_aliases are never session-scoped;
#     values match the pane's own process env; and a second start does not
#     duplicate or corrupt it
#
# Phase E lands templates/workspace.sh, the project-local bootstrap shim.
# Its tests fake plugin-cache trees under a temp $HOME (never the real
# ~/.codex or ~/.claude) with stub scripts/workspace.sh executables and prove:
#   - SESSION_WORKSPACE_PLUGIN_ROOT wins over every cache candidate, even one
#     that answers --contract incorrectly
#   - the newest version is selected via `sort -V` (0.10.0 beats 0.9.0, which
#     a lexical sort would get backwards)
#   - a compatible Codex cache candidate is preferred over an equally
#     compatible Claude cache candidate
#   - a candidate whose --contract output is wrong or missing is skipped in
#     favor of the next compatible one
#   - when nothing anywhere is compatible, it exits non-zero with guidance
#     naming both providers
#   - a project path containing a space AND an apostrophe resolves correctly
#     end to end, and argv (including an argument containing spaces) is
#     forwarded to the resolved engine verbatim
#
# Phase F lands workspace-doctor.sh, the read-only diagnostic verb. Its tests
# run against a self-contained fixture with a fake $HOME (plugin caches), a
# fake source tree ($SESSION_WORKSPACE_SOURCE_TREE_DIR, for the drift
# comparison), a private $XDG_STATE_HOME, and a SANITIZED PATH containing
# only symlinks to the tools under test plus stub claude/codex — so a
# "missing tool" is simulated without touching the machine's real installs.
# They prove:
#   - every check reports OK on a healthy fixture, and each one reports
#     ERROR/WARN on a fixture that violates it: missing/too-old tmux, missing
#     jq, missing git, a plugin below its floor or absent, cache-vs-source
#     drift, a broken pane cwd, a secrets file with the wrong mode / not
#     git-ignored / symlinked / unresolvable allowed keys, an unwritable or non-0700 state dir, a runtime
#     program off PATH, ledger files under a non-configured coordination
#     base, and an unresolvable session-chat helper under both on_missing
#     policies
#   - an `optional: true` pane with a missing dir is INFO/skip, never ERROR
#   - --json is valid JSON whose per-check statuses match the human report —
#     including when jq itself is the missing dependency
#   - the doctor is STRICTLY READ-ONLY: the fixture tree and $XDG_STATE_HOME
#     are byte-identical (listing + cksum) before and after, the project
#     state dir is never created, and the only tmux call it ever makes is
#     `tmux -V` (asserted with a logging stub) — no tmux server is contacted
#   - exit code is non-zero when any check is ERROR, and zero when only WARNs
#     are present
#   - the doctor opens the metadata-gated secrets file to resolve allowed key
#     names with the adapter parser, but no planted secret value ever appears
#     in output (with a positive control proving the values were readable)
#
# Post-review lifecycle fixes are proven alongside the phase suites above:
#   - a same-named tmux SESSION carrying no managed marker is refused by
#     `start` with the remedy that actually works, previewed (never mutated) by
#     `reconcile --adopt --confirmed`, and adopted only by `--apply --adopt
#     --confirmed`, always after its adoption plan
#   - a pane whose launch FAILED is never reported healthy afterwards; it is
#     retried, because markers are written only after a successful launch
#   - `--no-agents` is not a one-way door: the claimed-but-unlaunched pane is a
#     repairable state a later plain `start` finishes
#   - behavior.attach is honoured (and `--no-attach` actually suppresses it),
#     behavior.default_start_target is the TARGET of a bare `start` and must
#     name a real session, and behavior.session_chat_helper.on_missing "fail"
#     aborts `start` before anything in tmux is touched
#   - an optional pane whose cwd is absent is skipped on BOTH the standard and
#     the split_tree slot-allocation paths
#
# Usage: bash test-session-workspace.sh [-v]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VERBOSE=0
PASS=0
FAIL=0
FAILURES=()

[ "${1:-}" = "-v" ] && VERBOSE=1

log()  { [ "$VERBOSE" -eq 1 ] && echo "[debug] $*" >&2; return 0; }
pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1: $2"); echo "  FAIL  $1 — $2"; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/session-workspace-test.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

# Guard against the whole class of bug fixed on 2026-07-26: a mutating verb
# invoked WITHOUT --config falls back to walking up from $PWD, so running this
# suite from inside a configured project used to drive the engine against that
# project's real config on the developer's real tmux server. Neutralising
# discovery here means such a call resolves nothing and errors out loudly,
# instead of silently finding — and destroying — a live workspace. Any test
# that wants a config must pass --config explicitly (or set the variable
# itself for the one discovery test that exercises the walk).
export SESSION_WORKSPACE_CONFIG="$TMPROOT/no-such-config.json"

echo "== bash -n on every script =="
for f in "$HERE"/*.sh; do
  if bash -n "$f" 2>"$HERE"/.syntax-err.tmp; then
    pass "syntax: $(basename "$f")"
  else
    fail "syntax: $(basename "$f")" "$(cat "$HERE"/.syntax-err.tmp)"
  fi
done
rm -f "$HERE"/.syntax-err.tmp

echo "== workspace.schema.json is valid JSON =="
if command -v jq >/dev/null 2>&1; then
  if jq empty "$HERE/workspace.schema.json" 2>"$HERE"/.jq-err.tmp; then
    pass "workspace.schema.json parses"
  else
    fail "workspace.schema.json parses" "$(cat "$HERE"/.jq-err.tmp)"
  fi
  rm -f "$HERE"/.jq-err.tmp
else
  log "jq not installed; skipping schema JSON validity check"
fi

echo "== workspace.sh --contract =="
CONTRACT_OUT="$(bash "$HERE/workspace.sh" --contract 2>&1)"
CONTRACT_STATUS=$?
if [ "$CONTRACT_STATUS" -eq 0 ] && [ "$CONTRACT_OUT" = "session-workspace-cli 1" ]; then
  pass "workspace.sh --contract"
else
  fail "workspace.sh --contract" "status=$CONTRACT_STATUS output=$CONTRACT_OUT"
fi

echo "== no unimplemented-verb stubs remain =="
check_not_stub() {
  local label="$1"
  shift
  local out
  out="$("$@" 2>&1)"
  if printf '%s' "$out" | grep -q "is not implemented"; then
    fail "$label — implemented" "still reports an unimplemented-verb message: $out"
  else
    pass "$label — implemented (no scaffold message)"
  fi
}
check_not_stub "workspace.sh doctor" bash "$HERE/workspace.sh" doctor --config "$HERE/fixtures/valid/project-d.json"
check_not_stub "workspace-doctor.sh" bash "$HERE/workspace-doctor.sh" --config "$HERE/fixtures/valid/project-d.json"

echo "== Phase D verbs are wired (no longer scaffold stubs) =="
# SAFETY (regression fixed 2026-07-26 — read before editing this loop):
# these are the real MUTATING verbs. This check previously ran them bare:
# no --config, no isolated tmux socket, no private state dir. With no
# --config the engine falls back to walking UP from $PWD for
# .agent-workspace/workspace.json — so running the suite from anywhere
# inside a configured project resolved that project's REAL config and
# operated on the developer's REAL tmux server. `restart` implies stop
# confirmation, so it killed and recreated the live session. Reproduced
# twice on a workstation; invisible in CI only because no session of that
# name exists there.
#
# The assertion is trivial (the verb must not print a scaffold message), so
# it gets a fixture config and a fully private environment. Every verb below
# is expected to FAIL against that empty private server — failure is fine and
# irrelevant here; only the absence of the scaffold message is asserted.
SW_WIRED_DIR="$TMPROOT/verb-wiring"
mkdir -p "$SW_WIRED_DIR/tmuxtmp" "$SW_WIRED_DIR/state"
chmod 700 "$SW_WIRED_DIR/tmuxtmp"
for verb in start status stop reconcile restart; do
  OUT="$(env -u TMUX -u TMUX_PANE -u SESSION_WORKSPACE_CONFIG \
    TMUX_TMPDIR="$SW_WIRED_DIR/tmuxtmp" \
    XDG_STATE_HOME="$SW_WIRED_DIR/state" \
    SESSION_WORKSPACE_STOP_GRACE_SECONDS=0 \
    bash "$HERE/workspace.sh" "$verb" --config "$HERE/fixtures/valid/project-d.json" 2>&1)"
  if printf '%s' "$OUT" | grep -q "is not implemented"; then
    fail "workspace.sh $verb — implemented" "still reports an unimplemented-verb message: $OUT"
  else
    pass "workspace.sh $verb — implemented (no scaffold message)"
  fi
done

echo "== adapters.sh CLI: no subcommand / bad subcommand =="
OUT="$(bash "$HERE/adapters.sh" 2>&1)"
STATUS=$?
if [ "$STATUS" -ne 0 ] && printf '%s' "$OUT" | grep -q "Usage:"; then
  pass "adapters.sh — no subcommand prints usage and fails"
else
  fail "adapters.sh — no subcommand prints usage and fails" "status=$STATUS output=$OUT"
fi
OUT="$(bash "$HERE/adapters.sh" bogus-sub 2>&1)"
STATUS=$?
if [ "$STATUS" -ne 0 ] && printf '%s' "$OUT" | grep -q "unknown subcommand"; then
  pass "adapters.sh — unknown subcommand rejected"
else
  fail "adapters.sh — unknown subcommand rejected" "status=$STATUS output=$OUT"
fi

echo "== dispatcher rejects unknown verbs =="
OUT="$(bash "$HERE/workspace.sh" bogus-verb 2>&1)"
STATUS=$?
if [ "$STATUS" -ne 0 ] && printf '%s' "$OUT" | grep -q "unknown verb"; then
  pass "workspace.sh bogus-verb — rejected"
else
  fail "workspace.sh bogus-verb — rejected" "status=$STATUS output=$OUT"
fi

echo "== config.sh / validate-config.sh refuse direct execution as a lib-only entrypoint =="
OUT="$(bash "$HERE/config.sh" 2>&1)"
STATUS=$?
# The refusal must describe what is actually wrong (a library was executed),
# never claim the engine is unimplemented: every verb is implemented.
if [ "$STATUS" -ne 0 ] &&
   printf '%s' "$OUT" | grep -q "is a library and must not be executed directly" &&
   ! printf '%s' "$OUT" | grep -q "not implemented"; then
  pass "config.sh — not directly executable (reported as a library, not as unimplemented)"
else
  fail "config.sh — not directly executable (reported as a library, not as unimplemented)" "status=$STATUS output=$OUT"
fi

echo "== no script still carries a scaffold label =="
# Assembled at runtime so this test file is not itself a match for the label
# it is sweeping for.
SCAFFOLD_LABEL="Phase A""$(printf ' ')""scaffold"
SCAFFOLD_HITS="$(grep -l "$SCAFFOLD_LABEL" "$HERE"/*.sh "$HERE"/*.jq "$HERE"/*.json 2>/dev/null | tr '\n' ' ')"
if [ -z "$SCAFFOLD_HITS" ]; then
  pass "scripts/: no file contains the scaffold label"
else
  fail "scripts/: no file contains the scaffold label" "still labelled: $SCAFFOLD_HITS"
fi

echo "== golden fixtures validate clean =="
for fx in project-a project-d harness-v2 harness-disabled-v2 harness-v3 orchestration-v4 browser browser-multipane; do
  OUT="$(bash "$HERE/validate-config.sh" --config "$HERE/fixtures/valid/$fx.json" 2>&1)"
  STATUS=$?
  if [ "$STATUS" -eq 0 ] && printf '%s' "$OUT" | grep -q "^OK:"; then
    pass "fixtures/valid/$fx.json validates"
  else
    fail "fixtures/valid/$fx.json validates" "status=$STATUS output=$OUT"
  fi
done

echo "== reference-schema scalar/cardinality contracts are executable =="
SHAPE_BASE="$HERE/fixtures/valid/project-a.json"
SHAPE_BAD="$TMPROOT/shape-invalid.json"
assert_shape_invalid() {
  local label="$1" needle="$2" filter="$3" out status
  jq "$filter" "$SHAPE_BASE" > "$SHAPE_BAD"
  out="$(bash "$HERE/validate-config.sh" --config "$SHAPE_BAD" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ] && printf '%s' "$out" | grep -qF "$needle"; then
    pass "$label"
  else
    fail "$label" "status=$status output=$out"
  fi
}
assert_shape_invalid "shape: project.display_name must be a string" \
  "project.display_name must be a string" '.project.display_name = 42'
assert_shape_invalid "shape: sessions must contain at least one entry" \
  "sessions must be a non-empty array" '.sessions = []'
assert_shape_invalid "shape: window_index must be a non-negative integer" \
  "window_index must be an integer >= 0" '.sessions[0].window_index = "zero"'

echo "== schema v2 harness is opt-in, typed, and fail-closed =="
HARNESS_BASE="$HERE/fixtures/valid/harness-v2.json"
HARNESS_BAD="$TMPROOT/harness-invalid.json"
# Mutated configs below live directly under TMPROOT, so give their relative
# child cwd a real directory for filesystem-dependent harness assertions.
mkdir -p "$TMPROOT/component-a" "$TMPROOT/component-b"

assert_harness_invalid() {
  local label="$1" needle="$2" filter="$3" out status
  jq "$filter" "$HARNESS_BASE" > "$HARNESS_BAD"
  out="$(bash "$HERE/validate-config.sh" --config "$HARNESS_BAD" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ] && printf '%s' "$out" | grep -qF "$needle"; then
    pass "$label"
  else
    fail "$label" "status=$status output=$out"
  fi
}

assert_harness_invalid "harness: schema v1 rejects the v2 harness key" \
  "unknown key in top-level: harness" '.schema_version = 1'
assert_harness_invalid "harness: enabled=false rejects policy-bearing siblings" \
  "harness.enabled=false must not include" '.harness.enabled = false'
assert_harness_invalid "harness: unknown mode rejected" \
  "harness.mode must be one of" '.harness.mode = "permissive"'
assert_harness_invalid "harness: unknown profile rejected" \
  "harness.profile must be strict-v1" '.harness.profile = "custom"'
assert_harness_invalid "harness: duplicate semantic roles rejected" \
  "must name three distinct roles" '.harness.roles.reviewer = "executor"'
assert_harness_invalid "harness: unknown semantic role rejected" \
  "references unknown role" '.harness.roles.reviewer = "missing"'
assert_harness_invalid "harness: reserved service semantic role rejected" \
  "must not use the reserved service role" '.roles.service = .roles.reviewer | .harness.roles.reviewer = "service" | .sessions[0].panes[2].role = "service"'
assert_harness_invalid "harness: shell runtime role rejected" \
  "must not use the built-in shell runtime" '.roles.reviewer.runtime = "shell"'
assert_harness_invalid "harness: executor without matching reviewer rejected" \
  "must have exactly one reviewer pane" '.sessions[0].panes[2].cwd = "component-b"'
assert_harness_invalid "harness: resolved child cwd cannot collapse to project root" \
  "resolves to the project root" '.sessions[0].panes[1].cwd = "component-a/.." | .sessions[0].panes[2].cwd = "component-a/.."'
assert_harness_invalid "harness: out-of-range plan TTL rejected" \
  "plan_review_ttl_minutes must be an integer in 1..1440" '.harness.gates.plan_review_ttl_minutes = 0'
assert_harness_invalid "harness: out-of-range audit TTL rejected" \
  "audit_ttl_minutes must be an integer in 1..1440" '.harness.gates.audit_ttl_minutes = 1441'
assert_harness_invalid "harness: engine-owned config env rejected" \
  "reserved for engine-owned per-pane harness identity" '.env.groups.dev.values.SESSION_WORKSPACE_ROLE = "forged"'
assert_harness_invalid "harness: engine-owned pane alias rejected" \
  "reserved engine-owned harness identity" '.env.pane_name_aliases = ["SESSION_WORKSPACE_PANE_NAME"]'

HARNESS_OFF="$HERE/fixtures/valid/harness-disabled-v2.json"
if bash "$HERE/validate-config.sh" --config "$HARNESS_OFF" >/dev/null 2>&1; then
  pass "harness: schema v2 enabled=false is a valid inactive no-op configuration"
else
  fail "harness: schema v2 enabled=false is a valid inactive no-op configuration" "validation failed"
fi

echo "== schema v3 guard packs are additive and identity-bound =="
HARNESS_V3="$HERE/fixtures/valid/harness-v3.json"
V3_COMPAT="$TMPROOT/harness-v3-no-guards.json"
cp "$HARNESS_BASE" "$V3_COMPAT"
V2_PLAN="$(bash "$HERE/workspace-plan.sh" --config "$V3_COMPAT" --json)"
jq '.schema_version = 3' "$V3_COMPAT" > "$V3_COMPAT.next"
mv "$V3_COMPAT.next" "$V3_COMPAT"
V3_COMPAT_PLAN="$(bash "$HERE/workspace-plan.sh" --config "$V3_COMPAT" --json)"
if [ "$V2_PLAN" = "$V3_COMPAT_PLAN" ]; then
  pass "schema v3 without guards produces byte-identical normalized plan to v2"
else
  fail "schema v3 without guards produces byte-identical normalized plan to v2" "plans differ"
fi
V3_PLAN="$(bash "$HERE/workspace-plan.sh" --config "$HARNESS_V3" --json)"
if printf '%s' "$V3_PLAN" | jq -e '.harness.guards.protected_files.profile == "credentials-lockfiles-v1" and (.sessions[0].panes[0].env_names | index("SESSION_WORKSPACE_GUARDS_JSON") != null)' >/dev/null; then
  pass "schema v3 plan exposes guards and launcher guard identity"
else
  fail "schema v3 plan exposes guards and launcher guard identity" "$V3_PLAN"
fi
V3_GUARDS="$(jq -cS '.harness.guards' "$HARNESS_V3")"
V3_ROOT="$(cd "$HERE/fixtures/valid" && pwd -P)"
V3_STATUS="$(env -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME SESSION_WORKSPACE_CONFIG="$V3_ROOT/harness-v3.json" SESSION_WORKSPACE_PROJECT_ROOT="$V3_ROOT" \
  SESSION_WORKSPACE_PANE_NAME=harness-sample-master SESSION_WORKSPACE_ROLE=master SESSION_WORKSPACE_PANE_CWD="$V3_ROOT" \
  SESSION_WORKSPACE_HARNESS_MODE=enforce SESSION_WORKSPACE_GUARDS_JSON="$V3_GUARDS" \
  bash "$HERE/harness-status.sh" --config "$V3_ROOT/harness-v3.json" --json)"
if printf '%s' "$V3_STATUS" | jq -e '.guards.lifecycle.prompt_reminder == true and .identity.matches == true and .policy.decision == "allow"' >/dev/null; then
  pass "harness-status exposes schema-v3 guards and accepts matching identity"
else
  fail "harness-status exposes schema-v3 guards and accepts matching identity" "$V3_STATUS"
fi
V3_DOCTOR="$(env -u SESSION_WORKSPACE_CONFIG -u SESSION_WORKSPACE_GUARDS_JSON bash "$HERE/harness-doctor.sh" --config "$HARNESS_V3" --json)"
if printf '%s' "$V3_DOCTOR" | jq -e '([.checks[] | select(.id == "guards.configuration") | .status] == ["OK"]) and .status.guards.workspace_health.warn_root_dirty == true' >/dev/null; then
  pass "harness-doctor exposes validated schema-v3 guard configuration"
else
  fail "harness-doctor exposes validated schema-v3 guard configuration" "$V3_DOCTOR"
fi
for hook in guard-lifecycle.sh guard-health.sh; do
  NOOP="$(env -u SESSION_WORKSPACE_CONFIG -u SESSION_WORKSPACE_GUARDS_JSON bash "$HERE/$hook" --event prompt 2>&1)"
  if [ -z "$NOOP" ]; then pass "$hook has a silent no-env fast path"; else fail "$hook has a silent no-env fast path" "$NOOP"; fi
done

GH_ROOT="$TMPROOT/guard-health-project"
GH_CHILD="$GH_ROOT/component-a"
GH_BIN="$TMPROOT/guard-health-bin"
mkdir -p "$GH_ROOT/.agent-workspace" "$GH_CHILD" "$GH_BIN"
cp "$HARNESS_V3" "$GH_ROOT/.agent-workspace/workspace.json"
git -C "$GH_ROOT" init -q
git -C "$GH_ROOT" config user.email test@example.invalid
git -C "$GH_ROOT" config user.name Test
printf 'root\n' > "$GH_ROOT/README.md"
git -C "$GH_ROOT" add README.md
git -C "$GH_ROOT" commit -qm root
git -C "$GH_CHILD" init -q
git -C "$GH_CHILD" config user.email test@example.invalid
git -C "$GH_CHILD" config user.name Test
printf 'base\n' > "$GH_CHILD/file.txt"
git -C "$GH_CHILD" add file.txt
git -C "$GH_CHILD" commit -qm base
git -C "$GH_CHILD" branch -M main
git -C "$GH_CHILD" checkout -qb production
printf 'release\n' >> "$GH_CHILD/file.txt"
git -C "$GH_CHILD" commit -qam release
git -C "$GH_CHILD" checkout -q main
printf 'dirty\n' >> "$GH_ROOT/README.md"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" harness-sample-master' > "$GH_BIN/tmux"
chmod +x "$GH_BIN/tmux"
GH_CONFIG="$GH_ROOT/.agent-workspace/workspace.json"
GH_GUARDS="$(jq -cS '.harness.guards' "$GH_CONFIG")"
GH_ENV=(env PATH="$GH_BIN:$PATH" SESSION_WORKSPACE_CONFIG="$GH_CONFIG" SESSION_WORKSPACE_PROJECT_ROOT="$GH_ROOT" \
  SESSION_WORKSPACE_PANE_NAME=harness-sample-master SESSION_WORKSPACE_ROLE=master SESSION_WORKSPACE_PANE_CWD="$GH_ROOT" \
  SESSION_WORKSPACE_HARNESS_MODE=enforce SESSION_WORKSPACE_GUARDS_JSON="$GH_GUARDS")
GH_CLAUDE="$(printf '{}' | "${GH_ENV[@]}" bash "$HERE/guard-health.sh")"
if printf '%s' "$GH_CLAUDE" | jq -e '.systemMessage | contains("uncommitted") and contains("non-optional workspace panes are missing") and contains("production is ahead of main by 1")' >/dev/null 2>&1; then
  pass "schema-v3 Stop health emits bounded Claude systemMessage diagnostics"
else
  fail "schema-v3 Stop health emits bounded Claude systemMessage diagnostics" "$GH_CLAUDE"
fi
GH_CODEX="$(printf '{}' | "${GH_ENV[@]}" bash "$HERE/guard-health.sh" --codex-hook-output)"
if printf '%s' "$GH_CODEX" | jq -e 'keys == ["systemMessage"] and (.systemMessage | contains("uncommitted") and contains("non-optional workspace panes are missing") and contains("production is ahead of main by 1"))' >/dev/null 2>&1; then
  pass "schema-v3 Stop health emits Codex-valid systemMessage JSON"
else
  fail "schema-v3 Stop health emits Codex-valid systemMessage JSON" "$GH_CODEX"
fi
GL_SESSION="$("${GH_ENV[@]}" bash "$HERE/guard-lifecycle.sh" --event session)"
if printf '%s' "$GL_SESSION" | jq -e '(.hookSpecificOutput.hookEventName == "SessionStart") and (.hookSpecificOutput.additionalContext | contains("pane harness-sample-master") and contains("role master"))' >/dev/null 2>&1; then
  pass "schema-v3 SessionStart reminder is generic structured context"
else
  fail "schema-v3 SessionStart reminder is generic structured context" "$GL_SESSION"
fi
GL_PROMPT="$("${GH_ENV[@]}" bash "$HERE/guard-lifecycle.sh" --event prompt)"
if printf '%s' "$GL_PROMPT" | jq -e '(.hookSpecificOutput.hookEventName == "UserPromptSubmit") and (.hookSpecificOutput.additionalContext | contains("strict-v1 gates"))' >/dev/null 2>&1; then
  pass "schema-v3 UserPromptSubmit reminder uses Claude additionalContext"
else
  fail "schema-v3 UserPromptSubmit reminder uses Claude additionalContext" "$GL_PROMPT"
fi
GL_CODEX_SESSION="$("${GH_ENV[@]}" bash "$HERE/guard-lifecycle.sh" --event session --codex-hook-output)"
GL_CODEX_PROMPT="$("${GH_ENV[@]}" bash "$HERE/guard-lifecycle.sh" --event prompt --codex-hook-output)"
if printf '%s' "$GL_CODEX_SESSION" | jq -e '(.hookSpecificOutput.hookEventName == "SessionStart") and (.hookSpecificOutput.additionalContext | contains("pane harness-sample-master"))' >/dev/null 2>&1 && \
   printf '%s' "$GL_CODEX_PROMPT" | jq -e '(.hookSpecificOutput.hookEventName == "UserPromptSubmit") and (.hookSpecificOutput.additionalContext | contains("strict-v1 gates"))' >/dev/null 2>&1; then
  pass "schema-v3 lifecycle reminders use Codex-valid additionalContext JSON"
else
  fail "schema-v3 lifecycle reminders use Codex-valid additionalContext JSON" "session=$GL_CODEX_SESSION prompt=$GL_CODEX_PROMPT"
fi
GH_LAST_CONFIG="$GH_ROOT/.agent-workspace/workspace-last-schema.json"
jq 'del(.schema_version) + {schema_version: 3}' "$GH_CONFIG" > "$GH_LAST_CONFIG"
GH_LAST_ENV=(env PATH="$GH_BIN:$PATH" SESSION_WORKSPACE_CONFIG="$GH_LAST_CONFIG" SESSION_WORKSPACE_PROJECT_ROOT="$GH_ROOT" \
  SESSION_WORKSPACE_PANE_NAME=harness-sample-master SESSION_WORKSPACE_ROLE=master SESSION_WORKSPACE_PANE_CWD="$GH_ROOT" \
  SESSION_WORKSPACE_HARNESS_MODE=enforce SESSION_WORKSPACE_GUARDS_JSON="$GH_GUARDS")
GL_LAST="$("${GH_LAST_ENV[@]}" bash "$HERE/guard-lifecycle.sh" --event prompt)"
GH_LAST="$(printf '{}' | "${GH_LAST_ENV[@]}" bash "$HERE/guard-health.sh")"
if printf '%s' "$GL_LAST" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null 2>&1 && \
   printf '%s' "$GH_LAST" | jq -e '.systemMessage | contains("session-workspace health")' >/dev/null 2>&1; then
  pass "schema-v3 guard fast paths accept schema_version as the final JSON key"
else
  fail "schema-v3 guard fast paths accept schema_version as the final JSON key" "lifecycle=$GL_LAST health=$GH_LAST"
fi
GH_V4_CONFIG="$GH_ROOT/.agent-workspace/workspace-schema-v4.json"
jq '.schema_version = 4' "$GH_CONFIG" > "$GH_V4_CONFIG"
GH_V4_ENV=(env PATH="$GH_BIN:$PATH" SESSION_WORKSPACE_CONFIG="$GH_V4_CONFIG" SESSION_WORKSPACE_PROJECT_ROOT="$GH_ROOT" \
  SESSION_WORKSPACE_PANE_NAME=harness-sample-master SESSION_WORKSPACE_ROLE=master SESSION_WORKSPACE_PANE_CWD="$GH_ROOT" \
  SESSION_WORKSPACE_HARNESS_MODE=enforce SESSION_WORKSPACE_GUARDS_JSON="$GH_GUARDS")
GL_V4="$("${GH_V4_ENV[@]}" bash "$HERE/guard-lifecycle.sh" --event prompt)"
GH_V4="$(printf '{}' | "${GH_V4_ENV[@]}" bash "$HERE/guard-health.sh")"
if printf '%s' "$GL_V4" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null 2>&1 && \
   printf '%s' "$GH_V4" | jq -e '.systemMessage | contains("session-workspace health")' >/dev/null 2>&1; then
  pass "schema-v4 guard lifecycle and health fast paths remain active"
else
  fail "schema-v4 guard lifecycle and health fast paths remain active" "lifecycle=$GL_V4 health=$GH_V4"
fi

echo "== schema v4 reviewed orchestration is closed, additive, and normalized =="
ORCH_V4="$HERE/fixtures/valid/orchestration-v4.json"
V4_COMPAT="$TMPROOT/harness-v4-no-orchestration.json"
cp "$HARNESS_V3" "$V4_COMPAT"
V3_NO_ORCH_PLAN="$(bash "$HERE/workspace-plan.sh" --config "$V4_COMPAT" --json)"
jq '.schema_version = 4' "$V4_COMPAT" > "$V4_COMPAT.next"
mv "$V4_COMPAT.next" "$V4_COMPAT"
V4_NO_ORCH_PLAN="$(bash "$HERE/workspace-plan.sh" --config "$V4_COMPAT" --json)"
if [ "$V3_NO_ORCH_PLAN" = "$V4_NO_ORCH_PLAN" ]; then
  pass "schema v4 without orchestration produces byte-identical normalized plan to v3"
else
  fail "schema v4 without orchestration produces byte-identical normalized plan to v3" "plans differ"
fi

ORCH_PLAN="$(bash "$HERE/workspace-plan.sh" --config "$ORCH_V4" --json 2>&1)"
if printf '%s' "$ORCH_PLAN" | jq -e '
  .orchestration == {
    active:true,
    profile:"reviewed-git-v1",
    gates:{plan_review_ttl_minutes:60,audit_ttl_minutes:60},
    targets:[{
      id:"component",cwd_raw:"component-a",cwd:(.project.root + "/component-a"),
      executor:"harness-sample-component-executor",reviewer:"harness-sample-component-reviewer",
      remote:"origin",work_branch:"main",release_branch:"production",
      deploy:{strategy:"merge-no-ff-v1",align_work_after_release:true}
    }]
  }
' >/dev/null 2>&1; then
  pass "schema v4 plan resolves reviewed-git target, pane pair, TTLs, and Git coordinates"
else
  fail "schema v4 plan resolves reviewed-git target, pane pair, TTLs, and Git coordinates" "$ORCH_PLAN"
fi
ORCH_HUMAN="$(bash "$HERE/workspace-plan.sh" --config "$ORCH_V4" 2>&1)"
if printf '%s' "$ORCH_HUMAN" | grep -q '^orchestration: active  profile=reviewed-git-v1  targets=1$' && \
   printf '%s' "$ORCH_HUMAN" | grep -q 'target component:.*executor=harness-sample-component-executor.*reviewer=harness-sample-component-reviewer'; then
  pass "schema v4 human plan renders redacted orchestration coordinates"
else
  fail "schema v4 human plan renders redacted orchestration coordinates" "$ORCH_HUMAN"
fi
ORCH_FILTER_CONFIG="$TMPROOT/orchestration-filter.json"
jq '
  .roles.service = {runtime:"shell"} |
  .sessions += [{id:"services",name:"harness-sample-services",panes:[{name:"harness-sample-service",role:"service",cwd:"."}]}]
' "$ORCH_V4" > "$ORCH_FILTER_CONFIG"
ORCH_FILTER_PLAN="$(bash "$HERE/workspace-plan.sh" services --config "$ORCH_FILTER_CONFIG" --json 2>&1)"
if printf '%s' "$ORCH_FILTER_PLAN" | jq -e '.sessions == [(.sessions[0] | select(.id == "services"))] and (.orchestration.targets | length) == 1 and .orchestration.targets[0].executor == "harness-sample-component-executor"' >/dev/null 2>&1; then
  pass "schema v4 session filtering preserves the workspace-wide orchestration target map"
else
  fail "schema v4 session filtering preserves the workspace-wide orchestration target map" "$ORCH_FILTER_PLAN"
fi

ORCH_BAD="$TMPROOT/orchestration-invalid.json"
assert_orchestration_invalid() {
  local label="$1" needle="$2" filter="$3" out status
  jq "$filter" "$ORCH_V4" > "$ORCH_BAD"
  out="$(bash "$HERE/validate-config.sh" --config "$ORCH_BAD" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ] && printf '%s' "$out" | grep -qF "$needle"; then
    pass "$label"
  else
    fail "$label" "status=$status output=$out"
  fi
}
assert_orchestration_invalid "orchestration: schema v3 rejects the v4 key" \
  "unknown key in top-level: orchestration" '.schema_version = 3'
assert_orchestration_invalid "orchestration: enabled=false rejects siblings" \
  "orchestration.enabled=false must not include" '.orchestration.enabled = false'
assert_orchestration_invalid "orchestration: fixed profile enforced" \
  "orchestration.profile must be reviewed-git-v1" '.orchestration.profile = "custom"'
assert_orchestration_invalid "orchestration: strict-v1 harness required" \
  "enabled orchestration requires harness.enabled=true" '.harness = {enabled:false}'
assert_orchestration_invalid "orchestration: messages and scheduler stores required" \
  "requires stores.pin to include messages and scheduler" '.stores.pin = ["messages"]'
assert_orchestration_invalid "orchestration: at least one target required" \
  "orchestration.targets must be a non-empty array" '.orchestration.targets = []'
assert_orchestration_invalid "orchestration: target ids are restricted" \
  "target id must match" '.orchestration.targets[0].id = "Bad_ID"'
assert_orchestration_invalid "orchestration: target cwd is a safe child literal" \
  "cwd must be a safe relative" '.orchestration.targets[0].cwd = "../component-a"'
assert_orchestration_invalid "orchestration: named remote cannot be a URL" \
  "remote must match" '.orchestration.targets[0].remote = "https://example.invalid/repo"'
assert_orchestration_invalid "orchestration: work and release refs are distinct" \
  "work_branch and release_branch must be distinct" '.orchestration.targets[0].release_branch = "main"'
assert_orchestration_invalid "orchestration: unsafe refs rejected" \
  "work_branch is not a safe literal ref name" '.orchestration.targets[0].work_branch = "../main"'
assert_orchestration_invalid "orchestration: deploy strategy is closed" \
  "deploy.strategy must be merge-no-ff-v1" '.orchestration.targets[0].deploy.strategy = "shell"'
assert_orchestration_invalid "orchestration: align flag is typed" \
  "align_work_after_release must be a boolean" '.orchestration.targets[0].deploy.align_work_after_release = "yes"'
assert_orchestration_invalid "orchestration: target must exactly map to a pair" \
  "must exactly match one configured executor and reviewer pair" '.orchestration.targets[0].cwd = "component-b"'
assert_orchestration_invalid "orchestration: target ids are unique" \
  "orchestration.targets ids must be unique" '.orchestration.targets += [.orchestration.targets[0]]'

ln -s component-a "$TMPROOT/component-alias"
jq '
  .sessions[0].panes += [
    {name:"harness-sample-alias-executor",role:"executor",cwd:"component-alias"},
    {name:"harness-sample-alias-reviewer",role:"reviewer",cwd:"component-alias"}
  ] |
  .orchestration.targets += [(
    .orchestration.targets[0] |
    .id = "alias" | .cwd = "component-alias"
  )]
' "$ORCH_V4" > "$ORCH_BAD"
ORCH_ALIAS_OUT="$(bash "$HERE/validate-config.sh" --config "$ORCH_BAD" 2>&1)"
if [ $? -ne 0 ] && printf '%s' "$ORCH_ALIAS_OUT" | grep -qF "resolves to a child checkout already selected"; then
  pass "orchestration: physical target cwd aliases are unique"
else
  fail "orchestration: physical target cwd aliases are unique" "$ORCH_ALIAS_OUT"
fi

ORCH_DEFAULT_ALIGN="$TMPROOT/orchestration-default-align.json"
jq 'del(.orchestration.targets[0].deploy.align_work_after_release)' "$ORCH_V4" > "$ORCH_DEFAULT_ALIGN"
ORCH_DEFAULT_PLAN="$(bash "$HERE/workspace-plan.sh" --config "$ORCH_DEFAULT_ALIGN" --json 2>&1)"
if printf '%s' "$ORCH_DEFAULT_PLAN" | jq -e '.orchestration.targets[0].deploy.align_work_after_release == false' >/dev/null 2>&1; then
  pass "orchestration: align_work_after_release defaults false in the normalized plan"
else
  fail "orchestration: align_work_after_release defaults false in the normalized plan" "$ORCH_DEFAULT_PLAN"
fi

ORCH_OFF="$TMPROOT/orchestration-off.json"
jq '.orchestration = {enabled:false}' "$ORCH_V4" > "$ORCH_OFF"
if bash "$HERE/validate-config.sh" --config "$ORCH_OFF" >/dev/null 2>&1; then
  pass "orchestration: schema v4 enabled=false is a valid inactive configuration"
else
  fail "orchestration: schema v4 enabled=false is a valid inactive configuration" "validation failed"
fi

echo "== golden plans render (human + --json) without error =="
PLAN_A_JSON="$(bash "$HERE/workspace-plan.sh" --config "$HERE/fixtures/valid/project-a.json" --json 2>&1)"
if echo "$PLAN_A_JSON" | jq -e '.sessions | length == 2' >/dev/null 2>&1; then
  pass "project-a plan has 2 sessions"
else
  fail "project-a plan has 2 sessions" "$PLAN_A_JSON"
fi
DEV_PANES="$(echo "$PLAN_A_JSON" | jq '[.sessions[] | select(.id=="development") | .panes[]] | length' 2>/dev/null)"
SVC_PANES="$(echo "$PLAN_A_JSON" | jq '[.sessions[] | select(.id=="services") | .panes[]] | length' 2>/dev/null)"
if [ "$DEV_PANES" = "7" ] && [ "$SVC_PANES" = "4" ]; then
  pass "project-a golden plan is 7 dev + 4 service panes"
else
  fail "project-a golden plan is 7 dev + 4 service panes" "dev=$DEV_PANES services=$SVC_PANES"
fi
PLAN_A_HUMAN="$(bash "$HERE/workspace-plan.sh" --config "$HERE/fixtures/valid/project-a.json" 2>&1)"
if [ $? -eq 0 ] && printf '%s' "$PLAN_A_HUMAN" | grep -q "project-a-web-service"; then
  pass "project-a human plan renders"
else
  fail "project-a human plan renders" "$PLAN_A_HUMAN"
fi

PLAN_D_JSON="$(bash "$HERE/workspace-plan.sh" --config "$HERE/fixtures/valid/project-d.json" --json 2>&1)"
D_SESSIONS="$(echo "$PLAN_D_JSON" | jq '.sessions | length' 2>/dev/null)"
D_PANES="$(echo "$PLAN_D_JSON" | jq '[.sessions[].panes[]] | length' 2>/dev/null)"
if [ "$D_SESSIONS" = "1" ] && [ "$D_PANES" = "2" ]; then
  pass "project-d golden plan is 1 session / 2 panes"
else
  fail "project-d golden plan is 1 session / 2 panes" "sessions=$D_SESSIONS panes=$D_PANES"
fi

PLAN_HARNESS_JSON="$(bash "$HERE/workspace-plan.sh" --config "$HARNESS_BASE" --json 2>&1)"
if printf '%s' "$PLAN_HARNESS_JSON" | jq -e '
  .harness == {
    "active": true,
    "mode": "enforce",
    "profile": "strict-v1",
    "roles": {"orchestrator":"master","executor":"executor","reviewer":"reviewer"},
    "gates": {"plan_review_ttl_minutes":60,"audit_ttl_minutes":60}
  }
' >/dev/null 2>&1; then
  pass "harness: normalized plan exposes the active typed policy"
else
  fail "harness: normalized plan exposes the active typed policy" "$PLAN_HARNESS_JSON"
fi
if printf '%s' "$PLAN_D_JSON" | jq -e '.harness == {"active":false}' >/dev/null 2>&1; then
  pass "harness: unchanged schema v1 plan is explicitly inactive"
else
  fail "harness: unchanged schema v1 plan is explicitly inactive" "$PLAN_D_JSON"
fi

echo "== harness surfaces: status/doctor verbs, hook registration, OK line schema version =="
HARNESS_OK_LINE="$(bash "$HERE/validate-config.sh" --config "$HARNESS_BASE" 2>&1)"
if printf '%s' "$HARNESS_OK_LINE" | grep -q "schema_version 2)"; then
  pass "validate-config OK line reports schema_version 2 for the harness fixture"
else
  fail "validate-config OK line reports schema_version 2 for the harness fixture" "$HARNESS_OK_LINE"
fi
V1_OK_LINE="$(bash "$HERE/validate-config.sh" --config "$HERE/fixtures/valid/project-d.json" 2>&1)"
if printf '%s' "$V1_OK_LINE" | grep -q "schema_version 1)"; then
  pass "validate-config OK line still reports schema_version 1 for a v1 config"
else
  fail "validate-config OK line still reports schema_version 1 for a v1 config" "$V1_OK_LINE"
fi
HS_JSON="$(env -u SESSION_WORKSPACE_CONFIG -u SESSION_WORKSPACE_PROJECT_ROOT -u SESSION_WORKSPACE_PANE_NAME -u SESSION_WORKSPACE_ROLE -u SESSION_WORKSPACE_PANE_CWD -u SESSION_WORKSPACE_HARNESS_MODE -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME bash "$HERE/workspace.sh" harness-status --config "$HARNESS_BASE" --json 2>&1)"
if printf '%s' "$HS_JSON" | jq -e '.active == true and .mode == "enforce" and .profile == "strict-v1" and .roles.orchestrator == "master" and .identity.present == false and .identity.matches == null' >/dev/null 2>&1; then
  pass "harness-status (via dispatcher): active fixture reports mode/profile/roles and no live identity"
else
  fail "harness-status (via dispatcher): active fixture reports mode/profile/roles and no live identity" "$HS_JSON"
fi
HS_HUMAN="$(env -u SESSION_WORKSPACE_CONFIG -u SESSION_WORKSPACE_PROJECT_ROOT -u SESSION_WORKSPACE_PANE_NAME -u SESSION_WORKSPACE_ROLE -u SESSION_WORKSPACE_PANE_CWD -u SESSION_WORKSPACE_HARNESS_MODE -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME bash "$HERE/harness-status.sh" --config "$HARNESS_BASE" 2>&1)"
if printf '%s' "$HS_HUMAN" | grep -q "^state: active  mode=enforce  profile=strict-v1" && printf '%s' "$HS_HUMAN" | grep -q "^identity: not present"; then
  pass "harness-status human renderer: active state and identity lines"
else
  fail "harness-status human renderer: active state and identity lines" "$HS_HUMAN"
fi
HS_V1="$(env -u SESSION_WORKSPACE_CONFIG -u SESSION_WORKSPACE_PROJECT_ROOT -u SESSION_WORKSPACE_PANE_NAME -u SESSION_WORKSPACE_ROLE -u SESSION_WORKSPACE_PANE_CWD -u SESSION_WORKSPACE_HARNESS_MODE -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME bash "$HERE/harness-status.sh" --config "$HERE/fixtures/valid/project-d.json" --json 2>&1)"
if printf '%s' "$HS_V1" | jq -e '.active == false and .mode == "inactive"' >/dev/null 2>&1; then
  pass "harness-status: schema v1 config reports inactive"
else
  fail "harness-status: schema v1 config reports inactive" "$HS_V1"
fi
HS_OFF="$(env -u SESSION_WORKSPACE_CONFIG -u SESSION_WORKSPACE_PROJECT_ROOT -u SESSION_WORKSPACE_PANE_NAME -u SESSION_WORKSPACE_ROLE -u SESSION_WORKSPACE_PANE_CWD -u SESSION_WORKSPACE_HARNESS_MODE -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME bash "$HERE/harness-status.sh" --config "$HARNESS_OFF" --json 2>&1)"
if printf '%s' "$HS_OFF" | jq -e '.active == false' >/dev/null 2>&1; then
  pass "harness-status: schema v2 enabled=false reports inactive"
else
  fail "harness-status: schema v2 enabled=false reports inactive" "$HS_OFF"
fi
HARNESS_FIX_ROOT="$(cd "$HERE/fixtures/valid" && pwd -P)"
HARNESS_CFG_ABS="$HARNESS_FIX_ROOT/harness-v2.json"
HS_MATCH="$(env -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME SESSION_WORKSPACE_CONFIG="$HARNESS_CFG_ABS" SESSION_WORKSPACE_PROJECT_ROOT="$HARNESS_FIX_ROOT" \
  SESSION_WORKSPACE_PANE_NAME=harness-sample-component-reviewer SESSION_WORKSPACE_ROLE=reviewer \
  SESSION_WORKSPACE_PANE_CWD="$HARNESS_FIX_ROOT/component-a" SESSION_WORKSPACE_HARNESS_MODE=enforce \
  bash "$HERE/harness-status.sh" --config "$HARNESS_CFG_ABS" 2>&1)"
if printf '%s' "$HS_MATCH" | grep -q "^identity: MATCH  pane=harness-sample-component-reviewer role=reviewer"; then
  pass "harness-status: a matching engine identity reports MATCH"
else
  fail "harness-status: a matching engine identity reports MATCH" "$HS_MATCH"
fi
HS_MISMATCH="$(env -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME SESSION_WORKSPACE_CONFIG="$HARNESS_CFG_ABS" SESSION_WORKSPACE_PROJECT_ROOT="$HARNESS_FIX_ROOT" \
  SESSION_WORKSPACE_PANE_NAME=harness-sample-component-reviewer SESSION_WORKSPACE_ROLE=executor \
  SESSION_WORKSPACE_PANE_CWD="$HARNESS_FIX_ROOT/component-a" SESSION_WORKSPACE_HARNESS_MODE=enforce \
  bash "$HERE/harness-status.sh" --config "$HARNESS_CFG_ABS" 2>&1)"
if printf '%s' "$HS_MISMATCH" | grep -q "^identity: MISMATCH  pane=harness-sample-component-reviewer role=executor"; then
  pass "harness-status: a forged role reports MISMATCH (human renderer)"
else
  fail "harness-status: a forged role reports MISMATCH (human renderer)" "$HS_MISMATCH"
fi
HD_OUT="$(env -u SESSION_WORKSPACE_CONFIG -u SESSION_WORKSPACE_PROJECT_ROOT -u SESSION_WORKSPACE_PANE_NAME -u SESSION_WORKSPACE_ROLE -u SESSION_WORKSPACE_PANE_CWD -u SESSION_WORKSPACE_HARNESS_MODE -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME bash "$HERE/workspace.sh" harness-doctor --config "$HARNESS_BASE" 2>&1)"
HD_RC=$?
if [ "$HD_RC" -eq 0 ] && printf '%s' "$HD_OUT" | grep -q "\[OK\] harness.activation" && printf '%s' "$HD_OUT" | grep -q "\[OK\] hook.registration" && printf '%s' "$HD_OUT" | grep -q "\[INFO\] identity.live"; then
  pass "harness-doctor (via dispatcher): active fixture is OK with an INFO identity line, exit 0"
else
  fail "harness-doctor (via dispatcher): active fixture is OK with an INFO identity line, exit 0" "rc=$HD_RC $HD_OUT"
fi
HD_MIS="$(env -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME SESSION_WORKSPACE_CONFIG="$HARNESS_CFG_ABS" SESSION_WORKSPACE_PROJECT_ROOT="$HARNESS_FIX_ROOT" \
  SESSION_WORKSPACE_PANE_NAME=harness-sample-component-reviewer SESSION_WORKSPACE_ROLE=executor \
  SESSION_WORKSPACE_PANE_CWD="$HARNESS_FIX_ROOT/component-a" SESSION_WORKSPACE_HARNESS_MODE=enforce \
  bash "$HERE/harness-doctor.sh" --config "$HARNESS_CFG_ABS" --json 2>&1)"
HD_MIS_RC=$?
if [ "$HD_MIS_RC" -ne 0 ] && printf '%s' "$HD_MIS" | jq -e '.summary.errors == 1 and ([.checks[] | select(.id == "identity.live") | .status] == ["ERROR"])' >/dev/null 2>&1; then
  pass "harness-doctor: a mismatched identity is an ERROR and exits non-zero"
else
  fail "harness-doctor: a mismatched identity is an ERROR and exits non-zero" "rc=$HD_MIS_RC $HD_MIS"
fi
HD_V1="$(env -u SESSION_WORKSPACE_CONFIG -u SESSION_WORKSPACE_PROJECT_ROOT -u SESSION_WORKSPACE_PANE_NAME -u SESSION_WORKSPACE_ROLE -u SESSION_WORKSPACE_PANE_CWD -u SESSION_WORKSPACE_HARNESS_MODE -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME bash "$HERE/harness-doctor.sh" --config "$HERE/fixtures/valid/project-d.json" --json 2>&1)"
if [ $? -eq 0 ] && printf '%s' "$HD_V1" | jq -e '([.checks[] | select(.id == "harness.activation") | .status] == ["INFO"]) and ([.checks[] | select(.id == "runtime.python3") | .status] == ["INFO"])' >/dev/null 2>&1; then
  pass "harness-doctor: schema v1 config is INFO-only (inactive, python3 not required)"
else
  fail "harness-doctor: schema v1 config is INFO-only (inactive, python3 not required)" "$HD_V1"
fi
HD_PARTIAL="$(env -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME SESSION_WORKSPACE_CONFIG="$HARNESS_CFG_ABS" SESSION_WORKSPACE_HARNESS_MODE=enforce \
  bash "$HERE/harness-doctor.sh" --config "$HARNESS_CFG_ABS" --json 2>&1)"
HD_PARTIAL_RC=$?
if [ "$HD_PARTIAL_RC" -ne 0 ] && printf '%s' "$HD_PARTIAL" | jq -e '
  ([.checks[] | select(.id == "identity.env") | .status] == ["ERROR"]) and
  ([.checks[] | select(.id == "identity.live") | .status] == ["ERROR"]) and
  .status.identity.partial == true and .status.policy.decision == "deny"' >/dev/null 2>&1; then
  pass "harness-doctor: a PARTIAL identity (config+mode only) is ERROR on identity.env and identity.live, exits non-zero"
else
  fail "harness-doctor: a PARTIAL identity (config+mode only) is ERROR on identity.env and identity.live, exits non-zero" "rc=$HD_PARTIAL_RC $HD_PARTIAL"
fi
HD_ALIAS="$(env -u KNOWLEDGE_PANE_NAME SESSION_WORKSPACE_CONFIG="$HARNESS_CFG_ABS" SESSION_WORKSPACE_PROJECT_ROOT="$HARNESS_FIX_ROOT" \
  SESSION_WORKSPACE_PANE_NAME=harness-sample-component-reviewer SESSION_WORKSPACE_ROLE=reviewer \
  SESSION_WORKSPACE_PANE_CWD="$HARNESS_FIX_ROOT/component-a" SESSION_WORKSPACE_HARNESS_MODE=enforce \
  SESSION_CHAT_PANE_NAME=someone-else \
  bash "$HERE/harness-doctor.sh" --config "$HARNESS_CFG_ABS" --json 2>&1)"
HD_ALIAS_RC=$?
if [ "$HD_ALIAS_RC" -ne 0 ] && printf '%s' "$HD_ALIAS" | jq -e '
  ([.checks[] | select(.id == "identity.alias") | .status] == ["ERROR"]) and
  ([.checks[] | select(.id == "identity.live") | .status] == ["ERROR"]) and
  .status.policy.rule == "identity.alias"' >/dev/null 2>&1; then
  pass "harness-doctor: SESSION_CHAT_PANE_NAME alias drift is ERROR (identity.alias + policy probe agree)"
else
  fail "harness-doctor: SESSION_CHAT_PANE_NAME alias drift is ERROR (identity.alias + policy probe agree)" "rc=$HD_ALIAS_RC $HD_ALIAS"
fi
HD_OK="$(env SESSION_WORKSPACE_CONFIG="$HARNESS_CFG_ABS" SESSION_WORKSPACE_PROJECT_ROOT="$HARNESS_FIX_ROOT" \
  SESSION_WORKSPACE_PANE_NAME=harness-sample-component-reviewer SESSION_WORKSPACE_ROLE=reviewer \
  SESSION_WORKSPACE_PANE_CWD="$HARNESS_FIX_ROOT/component-a" SESSION_WORKSPACE_HARNESS_MODE=enforce \
  SESSION_CHAT_PANE_NAME=harness-sample-component-reviewer KNOWLEDGE_PANE_NAME=harness-sample-component-reviewer \
  bash "$HERE/harness-doctor.sh" --config "$HARNESS_CFG_ABS" --json 2>&1)"
HD_OK_RC=$?
if [ "$HD_OK_RC" -eq 0 ] && printf '%s' "$HD_OK" | jq -e '
  ([.checks[] | select(.id == "identity.live") | .status] == ["OK"]) and .status.policy.decision == "allow" and .status.identity.matches == true' >/dev/null 2>&1; then
  pass "harness-doctor: a complete, agreeing identity is OK and the policy probe allows"
else
  fail "harness-doctor: a complete, agreeing identity is OK and the policy probe allows" "rc=$HD_OK_RC $HD_OK"
fi
V1_FIX_ABS="$(cd "$HERE/fixtures/valid" && pwd -P)/project-d.json"
HD_INACTIVE_DRIFT="$(env -u SESSION_WORKSPACE_HARNESS_MODE -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME \
  SESSION_WORKSPACE_CONFIG="$V1_FIX_ABS" SESSION_WORKSPACE_PROJECT_ROOT="$HARNESS_FIX_ROOT" \
  SESSION_WORKSPACE_PANE_NAME=project-d-executor SESSION_WORKSPACE_ROLE=orchestrator \
  SESSION_WORKSPACE_PANE_CWD="$HARNESS_FIX_ROOT" \
  bash "$HERE/harness-doctor.sh" --config "$V1_FIX_ABS" --json 2>&1)"
HD_ID_RC=$?
if [ "$HD_ID_RC" -eq 0 ] && printf '%s' "$HD_INACTIVE_DRIFT" | jq -e '
  ([.checks[] | select(.id == "identity.live") | .status] == ["WARN"]) and .status.policy.active == false and .summary.errors == 0' >/dev/null 2>&1; then
  pass "harness-doctor: mismatched identity on an INACTIVE (v1) config is WARN, not ERROR — the hook really no-ops there"
else
  fail "harness-doctor: mismatched identity on an INACTIVE (v1) config is WARN, not ERROR — the hook really no-ops there" "rc=$HD_ID_RC $HD_INACTIVE_DRIFT"
fi
HD_BAD_JSON="$(env -u SESSION_WORKSPACE_CONFIG -u SESSION_WORKSPACE_PROJECT_ROOT -u SESSION_WORKSPACE_PANE_NAME -u SESSION_WORKSPACE_ROLE -u SESSION_WORKSPACE_PANE_CWD -u SESSION_WORKSPACE_HARNESS_MODE -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME bash "$HERE/harness-doctor.sh" --config "$HERE/fixtures/invalid/unknown-key.json" --json 2>&1)"
HD_BAD_RC=$?
if [ "$HD_BAD_RC" -ne 0 ] && printf '%s' "$HD_BAD_JSON" | jq -e '
  ([.checks[] | select(.id == "config.validation") | .status] == ["ERROR"]) and .summary.errors == 1 and .status == null' >/dev/null 2>&1; then
  pass "harness-doctor --json: an invalid config still yields one structured report (config.validation ERROR)"
else
  fail "harness-doctor --json: an invalid config still yields one structured report (config.validation ERROR)" "rc=$HD_BAD_RC $HD_BAD_JSON"
fi
HS_PARTIAL="$(env -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME SESSION_WORKSPACE_CONFIG="$HARNESS_CFG_ABS" SESSION_WORKSPACE_HARNESS_MODE=enforce \
  bash "$HERE/harness-status.sh" --config "$HARNESS_CFG_ABS" 2>&1)"
if printf '%s' "$HS_PARTIAL" | grep -q "^identity: PARTIAL" && printf '%s' "$HS_PARTIAL" | grep -q "^policy: BLOCKING in this process \[identity.missing\]"; then
  pass "harness-status: a partial identity is reported PARTIAL with the policy's blocking verdict"
else
  fail "harness-status: a partial identity is reported PARTIAL with the policy's blocking verdict" "$HS_PARTIAL"
fi
HOOKS_JSON="$HERE/../hooks/hooks.json"
HOOK_COMMON_OK=0
HOOK_PROVIDER_OK=0
if jq -e '.hooks.PreToolUse[0].hooks[0].command | test("harness-hook\\.sh")' "$HOOKS_JSON" >/dev/null 2>&1 && \
   jq -e '.hooks.PreToolUse[0].matcher | test("Bash")' "$HOOKS_JSON" >/dev/null 2>&1 && \
   jq -e '[.hooks.SessionStart,.hooks.UserPromptSubmit,.hooks.Stop] | all(type == "array" and length > 0)' "$HOOKS_JSON" >/dev/null 2>&1; then
  HOOK_COMMON_OK=1
fi
if [ -f "$HERE/../.codex-plugin/plugin.json" ]; then
  if jq -e '.hooks.PreToolUse[0].matcher | test("Edit") and test("Write") and test("apply_patch")' "$HOOKS_JSON" >/dev/null 2>&1 && \
     jq -e '.hooks.PreToolUse[0].hooks[0].command | test("--codex-hook-output")' "$HOOKS_JSON" >/dev/null 2>&1; then
    HOOK_PROVIDER_OK=1
  fi
else
  if jq -e '.hooks.PreToolUse[0].matcher | test("Edit") and test("Write")' "$HOOKS_JSON" >/dev/null 2>&1 && \
     jq -e '.hooks.PreToolUse[0].hooks[0].command | test("--codex-hook-output") | not' "$HOOKS_JSON" >/dev/null 2>&1; then
    HOOK_PROVIDER_OK=1
  fi
fi
if [ "$HOOK_COMMON_OK" -eq 1 ] && [ "$HOOK_PROVIDER_OK" -eq 1 ]; then
  pass "hooks/hooks.json registers provider-correct PreToolUse/lifecycle/Stop hooks and renderers"
else
  fail "hooks/hooks.json registers provider-correct PreToolUse/lifecycle/Stop hooks and renderers" "$(cat "$HOOKS_JSON" 2>/dev/null)"
fi
HOOK_NOOP_OUT="$(printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | env -u SESSION_WORKSPACE_CONFIG -u SESSION_WORKSPACE_HARNESS_MODE bash "$HERE/harness-hook.sh" 2>&1)"
if [ $? -eq 0 ] && [ -z "$HOOK_NOOP_OUT" ]; then
  pass "harness-hook.sh: no SESSION_WORKSPACE_CONFIG is a silent no-op (exit 0, no output)"
else
  fail "harness-hook.sh: no SESSION_WORKSPACE_CONFIG is a silent no-op (exit 0, no output)" "$HOOK_NOOP_OUT"
fi
HOOK_V1_OUT="$(printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | env -u SESSION_WORKSPACE_HARNESS_MODE SESSION_WORKSPACE_CONFIG="$HERE/fixtures/valid/project-d.json" bash "$HERE/harness-hook.sh" 2>&1)"
if [ $? -eq 0 ] && [ -z "$HOOK_V1_OUT" ]; then
  pass "harness-hook.sh: a schema v1 config is a silent no-op"
else
  fail "harness-hook.sh: a schema v1 config is a silent no-op" "$HOOK_V1_OUT"
fi

echo "== workspace.sh plan (dispatcher) agrees with workspace-plan.sh (standalone) =="
VIA_DISPATCH="$(bash "$HERE/workspace.sh" plan --config "$HERE/fixtures/valid/project-d.json" --json 2>&1)"
VIA_STANDALONE="$(bash "$HERE/workspace-plan.sh" --config "$HERE/fixtures/valid/project-d.json" --json 2>&1)"
if [ "$VIA_DISPATCH" = "$VIA_STANDALONE" ]; then
  pass "workspace.sh plan == workspace-plan.sh"
else
  fail "workspace.sh plan == workspace-plan.sh" "dispatcher and standalone output differ"
fi

echo "== workspace-plan TARGET filtering =="
ONLY_DEV="$(bash "$HERE/workspace-plan.sh" development --config "$HERE/fixtures/valid/project-a.json" --json 2>&1)"
if echo "$ONLY_DEV" | jq -e '.sessions | length == 1 and .[0].id == "development"' >/dev/null 2>&1; then
  pass "workspace-plan TARGET filters to one session"
else
  fail "workspace-plan TARGET filters to one session" "$ONLY_DEV"
fi
BOGUS_TARGET_OUT="$(bash "$HERE/workspace-plan.sh" bogus-session --config "$HERE/fixtures/valid/project-a.json" 2>&1)"
BOGUS_TARGET_STATUS=$?
if [ "$BOGUS_TARGET_STATUS" -ne 0 ] && printf '%s' "$BOGUS_TARGET_OUT" | grep -q "unknown session target"; then
  pass "workspace-plan rejects an unknown TARGET"
else
  fail "workspace-plan rejects an unknown TARGET" "status=$BOGUS_TARGET_STATUS output=$BOGUS_TARGET_OUT"
fi

echo "== workspace-plan resolves per-pane sharded memory paths =="
SHARD_PATH="$(echo "$PLAN_A_JSON" | jq -r '.sessions[] | select(.id=="development") | .panes[] | select(.name=="project-a-web-executor") | .memory.path')"
case "$SHARD_PATH" in
  */.agents/memory/web) pass "per-pane memory shard strips project id prefix + role suffix" ;;
  *) fail "per-pane memory shard strips project id prefix + role suffix" "got: $SHARD_PATH" ;;
esac
MASTER_SHARD="$(echo "$PLAN_A_JSON" | jq -r '.sessions[] | select(.id=="development") | .panes[] | select(.name=="project-a-master") | .memory.path')"
case "$MASTER_SHARD" in
  */.agents/memory/master) pass "per-pane memory shard falls back to 'master' for the orchestrator pane" ;;
  *) fail "per-pane memory shard falls back to 'master' for the orchestrator pane" "got: $MASTER_SHARD" ;;
esac

echo "== workspace-plan never prints an env value, only names =="
if printf '%s' "$PLAN_A_HUMAN" | grep -q "Asia/Kolkata"; then
  fail "workspace-plan never prints env values" "found a configured env VALUE (Asia/Kolkata) in plan output"
else
  pass "workspace-plan never prints env values"
fi
if printf '%s' "$PLAN_A_HUMAN" | grep -q "AGENT_PLUGINS_TIME_ZONE"; then
  pass "workspace-plan prints env var NAMES"
else
  fail "workspace-plan prints env var NAMES" "expected AGENT_PLUGINS_TIME_ZONE name in plan output"
fi

echo "== workspace-plan resolution precedence: pane-level agent overrides role =="
PRECEDENCE_DIR="$TMPROOT/precedence"
mkdir -p "$PRECEDENCE_DIR/.agent-workspace"
jq '.sessions[0].panes[0].agent = {"model":"opus"}' "$HERE/fixtures/valid/project-d.json" \
  | jq '.roles.orchestrator.agent = {"model":"sonnet","effort":"high"}' \
  > "$PRECEDENCE_DIR/.agent-workspace/workspace.json"
PRECEDENCE_JSON="$(bash "$HERE/workspace-plan.sh" --config "$PRECEDENCE_DIR/.agent-workspace/workspace.json" --json 2>&1)"
PANE0_MODEL="$(echo "$PRECEDENCE_JSON" | jq -r '.sessions[0].panes[0].agent.model')"
PANE0_EFFORT="$(echo "$PRECEDENCE_JSON" | jq -r '.sessions[0].panes[0].agent.effort')"
if [ "$PANE0_MODEL" = "opus" ] && [ "$PANE0_EFFORT" = "high" ]; then
  pass "pane-level agent.model wins over role, role fills in agent.effort"
else
  fail "pane-level agent.model wins over role, role fills in agent.effort" "model=$PANE0_MODEL effort=$PANE0_EFFORT"
fi

echo "== workspace-plan is mutation-free: no tmux invocation, no state-dir writes =="
FAKE_BIN="$TMPROOT/fakebin"
mkdir -p "$FAKE_BIN"
TMUX_CALL_LOG="$TMPROOT/tmux-calls.log"
: > "$TMUX_CALL_LOG"
cat > "$FAKE_BIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TMUX_CALL_LOG"
exit 1
EOF
chmod +x "$FAKE_BIN/tmux"
STATE_DIR="$TMPROOT/state"
mkdir -p "$STATE_DIR"
BEFORE_LISTING="$(find "$STATE_DIR" -type f | sort)"
PATH="$FAKE_BIN:$PATH" XDG_STATE_HOME="$STATE_DIR" \
  bash "$HERE/workspace-plan.sh" --config "$HERE/fixtures/valid/project-a.json" --json >/dev/null 2>"$TMPROOT/plan-stderr.log"
AFTER_LISTING="$(find "$STATE_DIR" -type f | sort)"
if [ -s "$TMUX_CALL_LOG" ]; then
  fail "workspace-plan never invokes tmux" "tmux was called: $(cat "$TMUX_CALL_LOG")"
else
  pass "workspace-plan never invokes tmux"
fi
if [ "$BEFORE_LISTING" = "$AFTER_LISTING" ]; then
  pass "workspace-plan writes nothing under \$XDG_STATE_HOME"
else
  fail "workspace-plan writes nothing under \$XDG_STATE_HOME" "state dir contents changed"
fi

echo "== config discovery order =="
DISC_DIR="$TMPROOT/discovery/project-e/nested/deep"
mkdir -p "$DISC_DIR"
mkdir -p "$TMPROOT/discovery/project-e/.agent-workspace"
cp "$HERE/fixtures/valid/project-d.json" "$TMPROOT/discovery/project-e/.agent-workspace/workspace.json"
(cd "$DISC_DIR" && env -u SESSION_WORKSPACE_CONFIG bash "$HERE/workspace-plan.sh" --json >/dev/null 2>"$TMPROOT/discovery-out.log")
if [ $? -eq 0 ]; then
  pass "config discovery walks upward from a nested cwd"
else
  fail "config discovery walks upward from a nested cwd" "$(cat "$TMPROOT/discovery-out.log")"
fi
(cd "$TMPROOT" && env -u SESSION_WORKSPACE_CONFIG bash "$HERE/workspace-plan.sh" >"$TMPROOT/no-config-out.log" 2>&1)
NO_CONFIG_STATUS=$?
if [ "$NO_CONFIG_STATUS" -ne 0 ] && grep -q "no session-workspace config found" "$TMPROOT/no-config-out.log"; then
  pass "config discovery fails with init guidance when nothing is found"
else
  fail "config discovery fails with init guidance when nothing is found" "status=$NO_CONFIG_STATUS $(cat "$TMPROOT/no-config-out.log")"
fi
ENV_OVERRIDE_OUT="$(cd "$TMPROOT" && SESSION_WORKSPACE_CONFIG="$TMPROOT/discovery/project-e/.agent-workspace/workspace.json" bash "$HERE/workspace-plan.sh" --json 2>&1)"
if echo "$ENV_OVERRIDE_OUT" | jq -e '.project.id == "project-d"' >/dev/null 2>&1; then
  pass "\$SESSION_WORKSPACE_CONFIG override is honored"
else
  fail "\$SESSION_WORKSPACE_CONFIG override is honored" "$ENV_OVERRIDE_OUT"
fi

echo "== every static invalid fixture fails validation =="
declare -a RULE_FIXTURES=(
  "schema-version.json:schema_version must be 1, 2, 3, or 4"
  "harness-v2-guards.json:unknown key in harness: guards"
  "harness-v3-disabled-guards.json:harness.enabled=false must not include"
  "harness-v3-bad-guards.json:unknown key in harness.guards: unknown"
  "harness-v3-top-level-guards.json:unknown key in top-level: guards"
  "unknown-key.json:unknown key in project"
  "duplicate-pane-names.json:duplicate pane name after resolution"
  "bad-charset-name.json:invalid characters"
  "command-string.json:must be an argv array, not a string"
  "split-tree-bad-permutation.json:must be a permutation"
  "split-tree-bad-percent.json:percent must be 1..99"
  "split-tree-bad-from.json:does not exist earlier in nodes"
  "env-var-name-bad.json:must match \^\[A-Z_\]"
  "env-var-value-dollar.json:must not contain"
  "coordination-var-in-env.json:derived from stores.pin"
  "per-pane-memory-bad-prefix.json:must start with"
  "grants-unpinned-store.json:not in stores.pin"
  "permission-mode-bypass.json:bypassPermissions is never allowed"
  "secrets-allow-rce.json:secrets.allow entry .* must match \^\[A-Za-z_\]"
  "pane-name-alias-rce.json:env.pane_name_aliases entry .* must match \^\[A-Z_\]"
  "project-id-bad-charset.json:project.id has invalid characters"
  "session-id-bad-charset.json:session id has invalid characters"
  "browser-multipane-missing-pane-name.json:has 3 panes; set browser.pane_name"
  "browser-pane-name-unknown.json:does not match any pane in browser session services"
  "browser-pane-name-foreign-session.json:belongs to session other, not to browser.session_id services"
  "browser-pane-name-bad-charset.json:browser.pane_name must match"
  "browser-selected-pane-role.json:browser session pane role must be named service"
  "browser-selected-pane-optional.json:browser session pane must not be optional"
  "browser-selected-pane-command.json:browser session pane must omit command"
  "browser-selected-pane-port.json:browser session pane must omit port"
  "browser-selected-pane-runtime.json:browser session pane role must use the built-in shell runtime"
)
for entry in "${RULE_FIXTURES[@]}"; do
  fx="${entry%%:*}"
  expect="${entry#*:}"
  OUT="$(bash "$HERE/validate-config.sh" --config "$HERE/fixtures/invalid/$fx" 2>&1)"
  STATUS=$?
  if [ "$STATUS" -ne 0 ] && printf '%s' "$OUT" | grep -qE "$expect"; then
    pass "fixtures/invalid/$fx trips its rule"
  else
    fail "fixtures/invalid/$fx trips its rule" "status=$STATUS output=$OUT"
  fi
done

echo "== jq \A...\z anchors: a trailing newline must not slip past ^...\$ =="
# Oniguruma's $ matches before a trailing newline (and ^ after one), so the
# old "^...$" patterns let "name\n" validate -- which then breaks tab-
# delimited tmux record parsing downstream. project.id is the cheapest field
# to prove this on: it uses the exact same test("^...$") shape the other six
# anchored fields do.
ANCHOR_JSON="$(jq -n --arg pid $'proj-master\n' \
  '{schema_version:1,project:{id:$pid,root:"."},runtimes:{claude:{program:"claude"}},
    roles:{orchestrator:{runtime:"claude",env_group:"dev"}},stores:{pin:[]},
    sessions:[{id:"s",name:"s",panes:[{name:"p1",role:"orchestrator",cwd:"."}]}]}')"
ANCHOR_CFG="$TMPROOT/trailing-newline-name.json"
printf '%s' "$ANCHOR_JSON" > "$ANCHOR_CFG"
OUT="$(bash "$HERE/validate-config.sh" --config "$ANCHOR_CFG" 2>&1)"
if [ $? -ne 0 ] && printf '%s' "$OUT" | grep -q "project.id has invalid characters"; then
  pass "jq anchors: a trailing-newline project.id fails validation (\\A...\\z, not ^...\$)"
else
  fail "jq anchors: a trailing-newline project.id fails validation (\\A...\\z, not ^...\$)" "$OUT"
fi

echo "== filesystem-dependent rules: cwd escape =="
ESCAPE_DIR="$TMPROOT/escape-project"
mkdir -p "$ESCAPE_DIR/.agent-workspace" "$TMPROOT/outside-root"
ln -s "$TMPROOT/outside-root" "$ESCAPE_DIR/symlink-out"
cat > "$ESCAPE_DIR/.agent-workspace/workspace.json" <<EOF
{"schema_version":1,"project":{"id":"p","root":"."},"runtimes":{"claude":{"program":"claude"}},
"roles":{"orchestrator":{"runtime":"claude","env_group":"dev"}},"stores":{"pin":[]},
"sessions":[{"id":"s","name":"s","panes":[
  {"name":"p1","role":"orchestrator","cwd":"../../outside-root"},
  {"name":"p2","role":"orchestrator","cwd":"symlink-out"}
]}]}
EOF
ESCAPE_OUT="$(bash "$HERE/validate-config.sh" --config "$ESCAPE_DIR/.agent-workspace/workspace.json" 2>&1)"
ESCAPE_STATUS=$?
if [ "$ESCAPE_STATUS" -ne 0 ] && printf '%s' "$ESCAPE_OUT" | grep -q "p1: cwd" && printf '%s' "$ESCAPE_OUT" | grep -q "p2: cwd"; then
  pass "cwd path escape (..) and symlink escape are both rejected"
else
  fail "cwd path escape (..) and symlink escape are both rejected" "status=$ESCAPE_STATUS output=$ESCAPE_OUT"
fi

echo "== defect 4: stores.base / stores.overrides.* / stores.memory.root containment =="
STORES_DIR="$TMPROOT/stores-project"
mkdir -p "$STORES_DIR/.agent-workspace"
stores_config() {
  # $1=stores object (raw JSON)
  cat <<EOF
{"schema_version":1,"project":{"id":"p","root":"."},"runtimes":{"claude":{"program":"claude"}},
"roles":{"orchestrator":{"runtime":"claude","env_group":"dev"}},
"stores":$1,
"sessions":[{"id":"s","name":"s","panes":[{"name":"p1","role":"orchestrator","cwd":"."}]}]}
EOF
}
STORES_CFG="$STORES_DIR/.agent-workspace/workspace.json"

# stores.base escaping three levels above the project root -- the exact
# example from the defect report.
stores_config '{"base":"../../..","pin":[]}' > "$STORES_CFG"
OUT="$(bash "$HERE/validate-config.sh" --config "$STORES_CFG" 2>&1)"
if [ $? -ne 0 ] && printf '%s' "$OUT" | grep -q "stores.base"; then
  pass "defect 4: stores.base escaping via \"../../..\" fails validation"
else
  fail "defect 4: stores.base escaping via \"../../..\" fails validation" "$OUT"
fi

# an absolute stores.overrides.* pointing outside the project root.
stores_config '{"base":".tmp","pin":["messages"],"overrides":{"messages":"/etc/definitely-outside"}}' > "$STORES_CFG"
OUT="$(bash "$HERE/validate-config.sh" --config "$STORES_CFG" 2>&1)"
if [ $? -ne 0 ] && printf '%s' "$OUT" | grep -q "stores.overrides.messages"; then
  pass "defect 4: an absolute stores.overrides.* outside the root fails validation"
else
  fail "defect 4: an absolute stores.overrides.* outside the root fails validation" "$OUT"
fi

# an escaping stores.memory.root.
stores_config '{"base":".tmp","pin":[],"memory":{"mode":"shared","root":"../outside-memory"}}' > "$STORES_CFG"
OUT="$(bash "$HERE/validate-config.sh" --config "$STORES_CFG" 2>&1)"
if [ $? -ne 0 ] && printf '%s' "$OUT" | grep -q "stores.memory.root"; then
  pass "defect 4: an escaping stores.memory.root fails validation"
else
  fail "defect 4: an escaping stores.memory.root fails validation" "$OUT"
fi

# Legitimate values (including a base that does not exist yet -- lazily
# created by session-chat/session-scheduler/knowledge on first write, and an
# absolute override that resolves INSIDE the root) still pass. The override
# is built from the project root's OWN canonicalized form (cd + pwd -P) so
# this assertion is not tripped by an unrelated OS-level symlink in the
# tmpdir path itself (e.g. macOS's /var -> /private/var) -- root_abs is
# always the canonicalized form internally, so the raw mktemp path would not
# textually match it even though both refer to the same directory.
STORES_DIR_PHYS="$(cd "$STORES_DIR" && pwd -P)"
stores_config "{\"base\":\".tmp\",\"pin\":[\"messages\"],\"overrides\":{\"messages\":\"$STORES_DIR_PHYS/.tmp/messages\"},\"memory\":{\"mode\":\"shared\",\"root\":\".agents/memory\"}}" > "$STORES_CFG"
OUT="$(bash "$HERE/validate-config.sh" --config "$STORES_CFG" 2>&1)"
if [ $? -eq 0 ]; then
  pass "defect 4: legitimate stores.base/overrides/memory.root (including not-yet-created dirs) still pass"
else
  fail "defect 4: legitimate stores.base/overrides/memory.root (including not-yet-created dirs) still pass" "$OUT"
fi

echo "== filesystem-dependent rules: secrets.env_file gates =="
SECRETS_DIR="$TMPROOT/secrets-project"
mkdir -p "$SECRETS_DIR/.agent-workspace"
(cd "$SECRETS_DIR" && git init -q .)
base_config() {
  cat <<EOF
{"schema_version":1,"project":{"id":"p","root":"."},"runtimes":{"claude":{"program":"claude"}},
"roles":{"orchestrator":{"runtime":"claude","env_group":"dev"}},"stores":{"pin":[]},
"secrets":{"env_file":"workspace.local.env","allow":["SOME_TOKEN"],"visible_to_roles":[],"on_missing":"warn"},
"sessions":[{"id":"s","name":"s","panes":[{"name":"p1","role":"orchestrator","cwd":"."}]}]}
EOF
}
base_config > "$SECRETS_DIR/.agent-workspace/workspace.json"

# gate 1: file missing
OUT="$(bash "$HERE/validate-config.sh" --config "$SECRETS_DIR/.agent-workspace/workspace.json" 2>&1)"
if [ $? -ne 0 ] && printf '%s' "$OUT" | grep -q "does not exist"; then pass "secrets gate: missing file rejected"; else fail "secrets gate: missing file rejected" "$OUT"; fi

( umask 077; echo "SOME_TOKEN=abc" > "$SECRETS_DIR/workspace.local.env" )
chmod 600 "$SECRETS_DIR/workspace.local.env"

# gate 2: not git-ignored
OUT="$(bash "$HERE/validate-config.sh" --config "$SECRETS_DIR/.agent-workspace/workspace.json" 2>&1)"
if [ $? -ne 0 ] && printf '%s' "$OUT" | grep -q "must be git-ignored"; then pass "secrets gate: not git-ignored rejected"; else fail "secrets gate: not git-ignored rejected" "$OUT"; fi

echo "workspace.local.env" > "$SECRETS_DIR/.gitignore"

# gate 3: happy path passes
OUT="$(bash "$HERE/validate-config.sh" --config "$SECRETS_DIR/.agent-workspace/workspace.json" 2>&1)"
if [ $? -eq 0 ]; then pass "secrets gate: 0600 owner-owned git-ignored file passes"; else fail "secrets gate: 0600 owner-owned git-ignored file passes" "$OUT"; fi

# gate 4: bad mode
chmod 644 "$SECRETS_DIR/workspace.local.env"
OUT="$(bash "$HERE/validate-config.sh" --config "$SECRETS_DIR/.agent-workspace/workspace.json" 2>&1)"
if [ $? -ne 0 ] && printf '%s' "$OUT" | grep -q "must be mode 0600"; then pass "secrets gate: non-0600 mode rejected"; else fail "secrets gate: non-0600 mode rejected" "$OUT"; fi
chmod 600 "$SECRETS_DIR/workspace.local.env"

# gate 5: symlink rejected
rm -f "$SECRETS_DIR/workspace.local.env"
: > "$SECRETS_DIR/real-secret.env"
chmod 600 "$SECRETS_DIR/real-secret.env"
ln -s "$SECRETS_DIR/real-secret.env" "$SECRETS_DIR/workspace.local.env"
OUT="$(bash "$HERE/validate-config.sh" --config "$SECRETS_DIR/.agent-workspace/workspace.json" 2>&1)"
if [ $? -ne 0 ] && printf '%s' "$OUT" | grep -q "must not be a symlink"; then pass "secrets gate: symlink rejected"; else fail "secrets gate: symlink rejected" "$OUT"; fi
rm -f "$SECRETS_DIR/workspace.local.env"

# gate 6: outside root rejected
mkdir -p "$TMPROOT/outside-secrets"
( umask 077; echo "SOME_TOKEN=abc" > "$TMPROOT/outside-secrets/workspace.local.env" )
chmod 600 "$TMPROOT/outside-secrets/workspace.local.env"
jq --arg f "$TMPROOT/outside-secrets/workspace.local.env" '.secrets.env_file = $f' "$SECRETS_DIR/.agent-workspace/workspace.json" > "$TMPROOT/outside-secrets-cfg.json"
mv "$TMPROOT/outside-secrets-cfg.json" "$SECRETS_DIR/.agent-workspace/workspace.json"
OUT="$(bash "$HERE/validate-config.sh" --config "$SECRETS_DIR/.agent-workspace/workspace.json" 2>&1)"
if [ $? -ne 0 ] && printf '%s' "$OUT" | grep -q "must resolve inside the project root"; then pass "secrets gate: outside project root rejected"; else fail "secrets gate: outside project root rejected" "$OUT"; fi
base_config > "$SECRETS_DIR/.agent-workspace/workspace.json"

echo "== Phase C: adapters.sh — stub claude/codex on PATH, assert exact argv =="
STUBBIN="$TMPROOT/stubbin"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
cat > "$STUBBIN/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
chmod +x "$STUBBIN/claude" "$STUBBIN/codex"

# project-a-master (orchestrator, claude, agent all "inherit", grants=[]):
# every field should emit NO flag at all -- argv is exactly the program name.
ARGV_MASTER="$(PATH="$STUBBIN:$PATH" bash "$HERE/adapters.sh" agent-argv --config "$HERE/fixtures/valid/project-a.json" --pane project-a-master --exec 2>"$TMPROOT/argv-master.err")"
if [ "$ARGV_MASTER" = "" ]; then
  pass "agent-argv: inherit/omitted on every field emits no flags"
else
  fail "agent-argv: inherit/omitted on every field emits no flags" "got: $(printf '%s' "$ARGV_MASTER" | tr '\n' '|')"
fi

# project-a-web-executor (executor, codex, grants messages/scheduler/contexts/memory).
ROOT_A="$(cd "$HERE/fixtures/valid" && pwd -P)"
EXPECT_MSG_DIR="$ROOT_A/.tmp/messages"
EXPECT_SCHED_DIR="$ROOT_A/.tmp/scheduler"
EXPECT_CTX_DIR="$ROOT_A/.tmp/contexts"
EXPECT_MEM_WEB_DIR="$ROOT_A/.agents/memory/web"
ARGV_EXEC="$(PATH="$STUBBIN:$PATH" bash "$HERE/adapters.sh" agent-argv --config "$HERE/fixtures/valid/project-a.json" --pane project-a-web-executor --exec 2>"$TMPROOT/argv-exec.err")"
EXPECT_EXEC="$(printf '%s\n' --add-dir "$EXPECT_MSG_DIR" --add-dir "$EXPECT_SCHED_DIR" --add-dir "$EXPECT_CTX_DIR" --add-dir "$EXPECT_MEM_WEB_DIR")"
if [ "$ARGV_EXEC" = "$EXPECT_EXEC" ]; then
  pass "agent-argv: executor grants render as --add-dir in stores.pin order + memory last"
else
  fail "agent-argv: executor grants render as --add-dir in stores.pin order + memory last" "got:$(printf '\n%s' "$ARGV_EXEC")"$'\n'"want:$(printf '\n%s' "$EXPECT_EXEC")"
fi

echo "== Phase C: grants -- reviewer without memory never receives it =="
ARGV_REVIEW="$(PATH="$STUBBIN:$PATH" bash "$HERE/adapters.sh" agent-argv --config "$HERE/fixtures/valid/project-a.json" --pane project-a-web-reviewer --exec 2>"$TMPROOT/argv-review.err")"
if printf '%s' "$ARGV_REVIEW" | grep -qF "$EXPECT_MEM_WEB_DIR"; then
  fail "grants: reviewer never receives --add-dir for memory" "memory dir leaked into reviewer argv: $ARGV_REVIEW"
else
  pass "grants: reviewer never receives --add-dir for memory"
fi
if printf '%s' "$ARGV_REVIEW" | grep -qF -- "$EXPECT_MSG_DIR" && printf '%s' "$ARGV_REVIEW" | grep -qF -- "$EXPECT_CTX_DIR"; then
  pass "grants: reviewer still receives its other pinned-store grants"
else
  fail "grants: reviewer still receives its other pinned-store grants" "$ARGV_REVIEW"
fi

echo "== Phase C: explicit agent.{model,effort,profile,permission_mode} render as flags, in order =="
CLAUDE_CFG="$TMPROOT/claude-explicit.json"
jq '.sessions[0].panes[0].agent = {"model":"opus","effort":"high","profile":"my-agent","permission_mode":"acceptEdits"}' \
  "$HERE/fixtures/valid/project-d.json" > "$CLAUDE_CFG"
mkdir -p "$TMPROOT/claude-explicit-root/.agent-workspace"
cp "$CLAUDE_CFG" "$TMPROOT/claude-explicit-root/.agent-workspace/workspace.json"
ARGV_CLAUDE_EXPLICIT="$(PATH="$STUBBIN:$PATH" bash "$HERE/adapters.sh" agent-argv --config "$TMPROOT/claude-explicit-root/.agent-workspace/workspace.json" --pane project-d-master --exec 2>"$TMPROOT/argv-claude-explicit.err")"
EXPECT_CLAUDE_EXPLICIT="$(printf '%s\n' --model opus --agent my-agent --effort high --permission-mode acceptEdits)"
if [ "$ARGV_CLAUDE_EXPLICIT" = "$EXPECT_CLAUDE_EXPLICIT" ]; then
  pass "agent-argv: claude explicit model/agent/effort/permission-mode, in order"
else
  fail "agent-argv: claude explicit model/agent/effort/permission-mode, in order" "got:$(printf '\n%s' "$ARGV_CLAUDE_EXPLICIT")"$'\n'"want:$(printf '\n%s' "$EXPECT_CLAUDE_EXPLICIT")"
fi

CODEX_CFG="$TMPROOT/codex-explicit-root/.agent-workspace/workspace.json"
mkdir -p "$(dirname "$CODEX_CFG")"
jq '.sessions[0].panes[1].agent = {"model":"o1","effort":"high","profile":"work"} | .stores.pin = []' \
  "$HERE/fixtures/valid/project-d.json" > "$CODEX_CFG"
ROOT_CODEX_EXPLICIT="$(cd "$TMPROOT/codex-explicit-root" && pwd -P)"
ARGV_CODEX_EXPLICIT="$(PATH="$STUBBIN:$PATH" bash "$HERE/adapters.sh" agent-argv --config "$CODEX_CFG" --pane project-d-executor --exec 2>"$TMPROOT/argv-codex-explicit.err")"
EXPECT_CODEX_EXPLICIT="$(printf '%s\n' --model o1 -p work -c model_reasoning_effort=high --add-dir "$ROOT_CODEX_EXPLICIT/.agents/memory")"
if [ "$ARGV_CODEX_EXPLICIT" = "$EXPECT_CODEX_EXPLICIT" ]; then
  pass "agent-argv: codex explicit model/-p profile/-c model_reasoning_effort, in order"
else
  fail "agent-argv: codex explicit model/-p profile/-c model_reasoning_effort, in order" "got:$(printf '\n%s' "$ARGV_CODEX_EXPLICIT")"$'\n'"want:$(printf '\n%s' "$EXPECT_CODEX_EXPLICIT")"
fi

echo "== Phase C: special characters survive as ONE inert argv element =="
NASTY='hello; world $(rm -rf /) `echo hi` '"'"'quote'"'"' "dbl" $HOME'
NASTY_CFG="$TMPROOT/nasty-root/.agent-workspace/workspace.json"
mkdir -p "$(dirname "$NASTY_CFG")"
jq --arg m "$NASTY" '.sessions[0].panes[0].agent = {"model": $m}' "$HERE/fixtures/valid/project-d.json" > "$NASTY_CFG"
NASTY_OUT="$(PATH="$STUBBIN:$PATH" bash "$HERE/adapters.sh" agent-argv --config "$NASTY_CFG" --pane project-d-master --exec 2>"$TMPROOT/argv-nasty.err")"
EXPECT_NASTY="$(printf '%s\n' --model "$NASTY")"
if [ "$NASTY_OUT" = "$EXPECT_NASTY" ]; then
  pass "agent-argv: spaces/;/\$()/backticks/quotes survive as one inert argument"
else
  fail "agent-argv: spaces/;/\$()/backticks/quotes survive as one inert argument" "got:$(printf '\n%s' "$NASTY_OUT")"$'\n'"want:$(printf '\n%s' "$EXPECT_NASTY")"
fi

echo "== Phase C: dangerous-flag rejection =="
BYPASS_CFG="$TMPROOT/bypass-root/.agent-workspace/workspace.json"
mkdir -p "$(dirname "$BYPASS_CFG")"
jq '.sessions[0].panes[0].agent = {"permission_mode":"bypassPermissions"}' "$HERE/fixtures/valid/project-d.json" > "$BYPASS_CFG"
BYPASS_OUT="$(bash "$HERE/validate-config.sh" --config "$BYPASS_CFG" 2>&1)"
if [ $? -ne 0 ] && printf '%s' "$BYPASS_OUT" | grep -q "bypassPermissions"; then
  pass "dangerous flags: claude bypassPermissions rejected at config validation (defense layer 1)"
else
  fail "dangerous flags: claude bypassPermissions rejected at config validation (defense layer 1)" "$BYPASS_OUT"
fi
( source "$HERE/lib.sh"; source "$HERE/adapters.sh"
  # Every ADAPT_* global below is consumed by build_agent_argv, not directly
  # referenced in this subshell -- shellcheck can't see across that boundary.
  # shellcheck disable=SC2034
  ADAPT_RUNTIME=claude
  # shellcheck disable=SC2034
  ADAPT_PROGRAM=claude
  # shellcheck disable=SC2034
  ADAPT_STATIC_ARGS=()
  # shellcheck disable=SC2034
  ADAPT_MODEL=""
  # shellcheck disable=SC2034
  ADAPT_EFFORT=""
  # shellcheck disable=SC2034
  ADAPT_PROFILE=""
  # shellcheck disable=SC2034
  ADAPT_PERMISSION_MODE="bypassPermissions"
  # shellcheck disable=SC2034
  ADAPT_GRANT_DIRS=()
  build_agent_argv
) >"$TMPROOT/adapt-unit.out" 2>"$TMPROOT/adapt-unit.err"
ADAPT_UNIT_STATUS=$?
if [ "$ADAPT_UNIT_STATUS" -ne 0 ] && grep -q "never allowed" "$TMPROOT/adapt-unit.err"; then
  pass "dangerous flags: build_agent_argv refuses bypassPermissions directly (defense layer 2)"
else
  fail "dangerous flags: build_agent_argv refuses bypassPermissions directly (defense layer 2)" "status=$ADAPT_UNIT_STATUS $(cat "$TMPROOT/adapt-unit.err")"
fi

for dangerous_flag in "--dangerously-bypass-approvals-and-sandbox" "--dangerously-bypass-hook-trust"; do
  DANGER_CFG="$TMPROOT/danger-root/.agent-workspace/workspace.json"
  mkdir -p "$(dirname "$DANGER_CFG")"
  jq --arg f "$dangerous_flag" '.runtimes.codex.args = [$f]' "$HERE/fixtures/valid/project-d.json" > "$DANGER_CFG"
  DANGER_OUT="$(PATH="$STUBBIN:$PATH" bash "$HERE/adapters.sh" agent-argv --config "$DANGER_CFG" --pane project-d-executor --exec 2>&1)"
  DANGER_STATUS=$?
  if [ "$DANGER_STATUS" -ne 0 ] && printf '%s' "$DANGER_OUT" | grep -q "dangerous flag"; then
    pass "dangerous flags: codex $dangerous_flag rejected"
  else
    fail "dangerous flags: codex $dangerous_flag rejected" "status=$DANGER_STATUS output=$DANGER_OUT"
  fi
done

echo "== Phase C: memory shard derivation (unit) =="
( source "$HERE/lib.sh"; source "$HERE/adapters.sh"
  echo "web:$(memory_shard_name project-a-web-executor project-a- master -executor -reviewer)"
  echo "web2:$(memory_shard_name project-a-web-reviewer project-a- master -executor -reviewer)"
  echo "fallback:$(memory_shard_name project-a--executor project-a- master -executor -reviewer)"
) > "$TMPROOT/shard-unit.out" 2>&1
if grep -q "^web:web$" "$TMPROOT/shard-unit.out" && grep -q "^web2:web$" "$TMPROOT/shard-unit.out"; then
  pass "memory: executor and reviewer of one component resolve to the same shard"
else
  fail "memory: executor and reviewer of one component resolve to the same shard" "$(cat "$TMPROOT/shard-unit.out")"
fi
if grep -q "^fallback:master$" "$TMPROOT/shard-unit.out"; then
  pass "memory: an empty-after-stripping pane name falls back to \"master\""
else
  fail "memory: an empty-after-stripping pane name falls back to \"master\"" "$(cat "$TMPROOT/shard-unit.out")"
fi

echo "== Phase C: env-exports canonical form =="
ENV_OUT_MASTER="$(bash "$HERE/adapters.sh" env-exports --config "$HERE/fixtures/valid/project-a.json" --pane project-a-master --tmux-pane '%5' 2>"$TMPROOT/env-master.err")"
if ! printf '%s' "$ENV_OUT_MASTER" | grep -qE '^(export [A-Z_][A-Z0-9_]*=[^;]*; )+$'; then
  fail "env-exports: canonical 'export K=V; ...' form" "$ENV_OUT_MASTER"
else
  pass "env-exports: canonical 'export K=V; ...' form"
fi
for expect in 'TMUX_PANE=%5' 'SESSION_CHAT_PANE_NAME=project-a-master' 'KNOWLEDGE_PANE_NAME=project-a-master' \
  'PROJECT_A_CODEX_PANE_NAME=project-a-master' 'AGENT_PLUGINS_TIME_ZONE=Asia/Kolkata' \
  'KNOWLEDGE_AUTO_RECALL=1' 'KNOWLEDGE_AUTO_RECALL_LIMIT=5' 'KNOWLEDGE_AUTO_RECALL_TERMS=4' \
  'KNOWLEDGE_AUTO_RECALL_BUDGET=4000' 'KNOWLEDGE_CONSOLIDATE_NUDGE=1' 'KNOWLEDGE_AUTO_CAPTURE_LIMIT=3' \
  'KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING=20' 'KNOWLEDGE_AUTO_CAPTURE_MAX_BYTES=4096' \
  "SESSION_CHAT_TARGET_MESSAGES_DIR=$EXPECT_MSG_DIR" "SESSION_SCHEDULER_HOME=$EXPECT_SCHED_DIR" \
  "SESSION_CONTEXT_HOME=$EXPECT_CTX_DIR"; do
  if printf '%s' "$ENV_OUT_MASTER" | grep -qF -- "$expect"; then
    pass "env-exports: contains $expect"
  else
    fail "env-exports: contains $expect" "$ENV_OUT_MASTER"
  fi
done

ENV_OUT_D_EXEC="$(bash "$HERE/adapters.sh" env-exports --config "$HERE/fixtures/valid/project-d.json" --pane project-d-executor 2>"$TMPROOT/env-d.err")"
if printf '%s' "$ENV_OUT_D_EXEC" | grep -q "SESSION_CHAT_TARGET_MESSAGES_DIR\|SESSION_SCHEDULER_HOME\|SESSION_CONTEXT_HOME"; then
  fail "env-exports: project-d (stores.pin=[]) exports no coordination vars" "$ENV_OUT_D_EXEC"
else
  pass "env-exports: project-d (stores.pin=[]) exports no coordination vars"
fi

echo "== Phase C: engine-owned per-pane harness identity =="
HARNESS_ENV="$(bash "$HERE/adapters.sh" env-exports --config "$HARNESS_BASE" --pane harness-sample-component-executor --tmux-pane '%77' 2>"$TMPROOT/env-harness.err")"
HARNESS_ROOT="$(cd "$HERE/fixtures/valid/component-a" && pwd -P)"
HARNESS_CONFIG_ABS="$(cd "$HERE/fixtures/valid" && pwd -P)/harness-v2.json"
for expect in \
  "SESSION_WORKSPACE_CONFIG=$HARNESS_CONFIG_ABS" \
  "SESSION_WORKSPACE_PROJECT_ROOT=$(cd "$HERE/fixtures/valid" && pwd -P)" \
  "SESSION_WORKSPACE_PANE_NAME=harness-sample-component-executor" \
  "SESSION_WORKSPACE_ROLE=executor" \
  "SESSION_WORKSPACE_PANE_CWD=$HARNESS_ROOT" \
  "SESSION_WORKSPACE_HARNESS_MODE=enforce"; do
  if printf '%s' "$HARNESS_ENV" | grep -qF -- "$expect"; then
    pass "harness env: contains $expect"
  else
    fail "harness env: contains $expect" "$HARNESS_ENV"
  fi
done

HARNESS_SESSION_ENV="$(bash "$HERE/adapters.sh" session-env --config "$HARNESS_BASE" --pane harness-sample-component-executor | tr '\0' '\n')"
if printf '%s' "$HARNESS_SESSION_ENV" | grep -q 'SESSION_WORKSPACE_'; then
  fail "harness env: engine-owned identity is never pinned to the tmux session" "$HARNESS_SESSION_ENV"
else
  pass "harness env: engine-owned identity is never pinned to the tmux session"
fi

if printf '%s' "$ENV_OUT_D_EXEC" | grep -qF 'SESSION_WORKSPACE_CONFIG=' && \
   printf '%s' "$ENV_OUT_D_EXEC" | grep -qF "SESSION_WORKSPACE_HARNESS_MODE='';"; then
  pass "harness env: schema v1 carries identity but an empty inactive mode"
else
  fail "harness env: schema v1 carries identity but an empty inactive mode" "$ENV_OUT_D_EXEC"
fi

echo "== Phase C: engine-always identity vars win even if config tries to override them =="
OVERRIDE_ROOT="$TMPROOT/override-root"
mkdir -p "$OVERRIDE_ROOT/.agent-workspace"
cp -r "$HERE/fixtures/valid/component-a" "$HERE/fixtures/valid/component-b" "$HERE/fixtures/valid/component-c" "$OVERRIDE_ROOT/"
OVERRIDE_CFG="$OVERRIDE_ROOT/.agent-workspace/workspace.json"
jq '.env.groups.dev.values.KNOWLEDGE_PANE_NAME = "evil-pane" | .env.groups.dev.values.TMUX_PANE = "%666"' \
  "$HERE/fixtures/valid/project-a.json" > "$OVERRIDE_CFG"
OVERRIDE_OUT="$(bash "$HERE/adapters.sh" env-exports --config "$OVERRIDE_CFG" --pane project-a-master --tmux-pane '%5' 2>"$TMPROOT/env-override.err")"
if printf '%s' "$OVERRIDE_OUT" | grep -qF 'KNOWLEDGE_PANE_NAME=project-a-master' && printf '%s' "$OVERRIDE_OUT" | grep -qF 'TMUX_PANE=%5' \
  && ! printf '%s' "$OVERRIDE_OUT" | grep -q "evil-pane" && ! printf '%s' "$OVERRIDE_OUT" | grep -qF '%666'; then
  pass "env-exports: engine-always vars cannot be overridden by config values"
else
  fail "env-exports: engine-always vars cannot be overridden by config values" "$OVERRIDE_OUT"
fi

echo "== Phase C: secrets =="
SECRET_VALUE="SUPER-SECRET-VALUE-9f8e7d2c1b"
SECRETS2_DIR="$TMPROOT/secrets2-project"
mkdir -p "$SECRETS2_DIR/.agent-workspace"
(cd "$SECRETS2_DIR" && git init -q .)
cat > "$SECRETS2_DIR/.agent-workspace/workspace.json" <<EOF
{"schema_version":1,"project":{"id":"p2","root":"."},
"runtimes":{"claude":{"program":"claude"},"codex":{"program":"codex"}},
"roles":{"orchestrator":{"runtime":"claude","env_group":"dev"},"executor":{"runtime":"codex","grants":[],"env_group":"dev"}},
"stores":{"pin":[]},
"env":{"groups":{"dev":{"values":{}}}},
"secrets":{"env_file":"workspace.local.env","allow":["SOME_TOKEN"],"visible_to_roles":["executor"],"on_missing":"warn"},
"sessions":[{"id":"s","name":"s","panes":[
  {"name":"p2-master","role":"orchestrator","cwd":"."},
  {"name":"p2-executor","role":"executor","cwd":"."}
]}]}
EOF
( umask 077; printf 'SOME_TOKEN=%s\n' "$SECRET_VALUE" > "$SECRETS2_DIR/workspace.local.env" )
chmod 600 "$SECRETS2_DIR/workspace.local.env"
echo "workspace.local.env" > "$SECRETS2_DIR/.gitignore"

SECRET_CFG="$SECRETS2_DIR/.agent-workspace/workspace.json"
SECRET_GOT="$(bash "$HERE/adapters.sh" secret-value --config "$SECRET_CFG" --pane p2-executor --key SOME_TOKEN 2>"$TMPROOT/secret1.err")"
if [ "$SECRET_GOT" = "$SECRET_VALUE" ]; then
  pass "secrets: visible role reads the allowlisted value from the env file"
else
  fail "secrets: visible role reads the allowlisted value from the env file" "got=$SECRET_GOT"
fi

SECRET_DENIED_OUT="$(bash "$HERE/adapters.sh" secret-value --config "$SECRET_CFG" --pane p2-master --key SOME_TOKEN 2>&1)"
SECRET_DENIED_STATUS=$?
if [ "$SECRET_DENIED_STATUS" -ne 0 ] && printf '%s' "$SECRET_DENIED_OUT" | grep -q "visible_to_roles"; then
  pass "secrets: a role outside secrets.visible_to_roles is refused"
else
  fail "secrets: a role outside secrets.visible_to_roles is refused" "status=$SECRET_DENIED_STATUS output=$SECRET_DENIED_OUT"
fi

CALLER_SECRET="CALLER-ENV-WINS-VALUE"
SECRET_CALLER_GOT="$(SOME_TOKEN="$CALLER_SECRET" bash "$HERE/adapters.sh" secret-value --config "$SECRET_CFG" --pane p2-executor --key SOME_TOKEN 2>"$TMPROOT/secret2.err")"
if [ "$SECRET_CALLER_GOT" = "$CALLER_SECRET" ]; then
  pass "secrets: caller environment wins over the env file"
else
  fail "secrets: caller environment wins over the env file" "got=$SECRET_CALLER_GOT"
fi

# secrets.env_file is optional: an allowlisted value already present in the
# launcher environment still uses the same private single-use delivery path.
SECRET_ENV_ONLY_CFG="$SECRETS2_DIR/.agent-workspace/workspace-env-only.json"
jq 'del(.secrets.env_file)' "$SECRET_CFG" > "$SECRET_ENV_ONLY_CFG"
SECRET_ENV_ONLY_VALUE="ENV-ONLY-SECRET-31d4b2"
SECRET_ENV_ONLY_GOT="$(SOME_TOKEN="$SECRET_ENV_ONLY_VALUE" bash "$HERE/adapters.sh" secret-value --config "$SECRET_ENV_ONLY_CFG" --pane p2-executor --key SOME_TOKEN 2>"$TMPROOT/secret-env-only-value.err")"
SECRET_ENV_ONLY_FILE="$(SOME_TOKEN="$SECRET_ENV_ONLY_VALUE" bash "$HERE/adapters.sh" secret-file --config "$SECRET_ENV_ONLY_CFG" --pane p2-executor 2>"$TMPROOT/secret-env-only-file.err")"
if [ "$SECRET_ENV_ONLY_GOT" = "$SECRET_ENV_ONLY_VALUE" ] &&
   [ -f "$SECRET_ENV_ONLY_FILE" ] &&
   [ "$(cat "$SECRET_ENV_ONLY_FILE")" = "SOME_TOKEN=$SECRET_ENV_ONLY_VALUE" ]; then
  pass "secrets: env_file may be omitted when the launcher environment supplies the allowlisted value"
else
  fail "secrets: env_file may be omitted when the launcher environment supplies the allowlisted value" \
    "value=$SECRET_ENV_ONLY_GOT file=$SECRET_ENV_ONLY_FILE content=$(cat "$SECRET_ENV_ONLY_FILE" 2>/dev/null)"
fi
rm -f "$SECRET_ENV_ONLY_FILE"

# plan defect #1 fix: secrets are no longer delivered via `tmux
# set-environment -h` (hidden vars are NEVER passed into the environment of
# new processes -- verified against the tmux(1) manual and by experiment; see
# lifecycle.sh's _sw_secret_loader_snippet). adapters.sh's `secret-file`
# subcommand instead writes "KEY=VALUE" to a fresh, private (0600), single-use
# file and prints only its PATH -- never the value -- on stdout.
SECRET_FILE_OUT="$(bash "$HERE/adapters.sh" secret-file --config "$SECRET_CFG" --pane p2-executor 2>"$TMPROOT/secret3.err")"
SECRET_FILE_MODE="$(stat -c '%a' "$SECRET_FILE_OUT" 2>/dev/null || stat -f '%Lp' "$SECRET_FILE_OUT" 2>/dev/null)"
if [ -n "$SECRET_FILE_OUT" ] && [ -f "$SECRET_FILE_OUT" ] && [ "$SECRET_FILE_MODE" = "600" ] &&
   [ "$(cat "$SECRET_FILE_OUT")" = "SOME_TOKEN=$SECRET_VALUE" ]; then
  pass "secrets: secret-file writes a private 0600 KEY=VALUE file and prints only its path"
else
  fail "secrets: secret-file writes a private 0600 KEY=VALUE file and prints only its path" \
    "path=$SECRET_FILE_OUT mode=$SECRET_FILE_MODE content=$(cat "$SECRET_FILE_OUT" 2>/dev/null)"
fi
if printf '%s' "$SECRET_FILE_OUT" | grep -qF "$SECRET_VALUE"; then
  fail "secrets: secret-file's own stdout (the path) never contains the secret value" "leaked"
else
  pass "secrets: secret-file's own stdout (the path) never contains the secret value"
fi
rm -f "$SECRET_FILE_OUT"

# A pane whose role is NOT in secrets.visible_to_roles gets nothing at all --
# no file, no error (it is simply not entitled to any secret).
SECRET_FILE_DENIED="$(bash "$HERE/adapters.sh" secret-file --config "$SECRET_CFG" --pane p2-master 2>"$TMPROOT/secret3b.err")"
SECRET_FILE_DENIED_RC=$?
if [ -z "$SECRET_FILE_DENIED" ] && [ "$SECRET_FILE_DENIED_RC" -eq 0 ]; then
  pass "secrets: a role outside secrets.visible_to_roles gets no secret file at all"
else
  fail "secrets: a role outside secrets.visible_to_roles gets no secret file at all" \
    "out=$SECRET_FILE_DENIED rc=$SECRET_FILE_DENIED_RC"
fi

echo "== Phase C: secrets never leak into plan / argv / env-exports / logs =="
SECRET_LEAK_HAYSTACK="$TMPROOT/secret-leak-haystack.txt"
{
  bash "$HERE/workspace-plan.sh" --config "$SECRET_CFG" --json
  bash "$HERE/workspace-plan.sh" --config "$SECRET_CFG"
  PATH="$STUBBIN:$PATH" bash "$HERE/adapters.sh" agent-argv --config "$SECRET_CFG" --pane p2-executor --exec
  bash "$HERE/adapters.sh" env-exports --config "$SECRET_CFG" --pane p2-executor --tmux-pane '%9'
  cat "$TMPROOT"/*.err 2>/dev/null
  cat "$TMPROOT"/*.log 2>/dev/null
} > "$SECRET_LEAK_HAYSTACK" 2>&1
if grep -qF "$SECRET_VALUE" "$SECRET_LEAK_HAYSTACK"; then
  fail "secrets: value never appears in plan/argv/env-exports/log output" "leak found in $SECRET_LEAK_HAYSTACK"
else
  pass "secrets: value never appears in plan/argv/env-exports/log output"
fi

echo "== Phase C security: config-derived identifiers can never inject code =="
# CRITICAL #1 regression: secrets.allow[] used to be resolved via bash
# indirect expansion ("${!key}"), and an indirect-expansion subscript may
# contain command substitution -- so a key of "x[$(cmd)]" ran `cmd`. Prove
# (a) config validation now rejects such a key outright, and (b) even asking
# adapters.sh to resolve it end-to-end creates no side effect.
RCE1_MARKER="$TMPROOT/rce1-pwned"
RCE1_DIR="$TMPROOT/rce1-project"
mkdir -p "$RCE1_DIR/.agent-workspace"
(cd "$RCE1_DIR" && git init -q .)
cat > "$RCE1_DIR/.agent-workspace/workspace.json" <<EOF
{"schema_version":1,"project":{"id":"rce1","root":"."},
"runtimes":{"claude":{"program":"claude"}},
"roles":{"orchestrator":{"runtime":"claude","env_group":"dev"}},
"stores":{"pin":[]},
"env":{"groups":{"dev":{"values":{}}}},
"secrets":{"env_file":"workspace.local.env","allow":["x[\$(touch $RCE1_MARKER)]"],"visible_to_roles":["orchestrator"],"on_missing":"warn"},
"sessions":[{"id":"s","name":"s","panes":[{"name":"rce1-master","role":"orchestrator","cwd":"."}]}]}
EOF
( umask 077; printf 'placeholder=1\n' > "$RCE1_DIR/workspace.local.env" )
chmod 600 "$RCE1_DIR/workspace.local.env"
echo "workspace.local.env" > "$RCE1_DIR/.gitignore"
RCE1_CFG="$RCE1_DIR/.agent-workspace/workspace.json"

RCE1_VALIDATE_OUT="$(bash "$HERE/validate-config.sh" --config "$RCE1_CFG" 2>&1)"
if [ $? -ne 0 ] && printf '%s' "$RCE1_VALIDATE_OUT" | grep -qE 'secrets\.allow entry .* must match \^\[A-Za-z_\]'; then
  pass "security: secrets.allow with an indirect-expansion payload fails validation"
else
  fail "security: secrets.allow with an indirect-expansion payload fails validation" "$RCE1_VALIDATE_OUT"
fi

bash "$HERE/adapters.sh" secret-value --config "$RCE1_CFG" --pane rce1-master --key 'x[$(touch '"$RCE1_MARKER"')]' >/dev/null 2>"$TMPROOT/rce1-secret.err"
RCE1_SECRET_STATUS=$?
if [ "$RCE1_SECRET_STATUS" -ne 0 ] && [ ! -e "$RCE1_MARKER" ]; then
  pass "security: adapters.sh secret-value refuses the hostile key end-to-end (no side effect)"
else
  fail "security: adapters.sh secret-value refuses the hostile key end-to-end (no side effect)" \
    "status=$RCE1_SECRET_STATUS marker_exists=$([ -e "$RCE1_MARKER" ] && echo yes || echo no) err=$(cat "$TMPROOT/rce1-secret.err")"
fi

# Defense layer 2: resolve_secret_value itself must refuse a hostile key even
# when called directly, bypassing config validation entirely (e.g. a future
# caller that forgets to validate first).
RCE1_UNIT_MARKER="$TMPROOT/rce1-unit-pwned"
( source "$HERE/lib.sh"; source "$HERE/adapters.sh"
  resolve_secret_value "$RCE1_DIR/workspace.local.env" 'x[$(touch '"$RCE1_UNIT_MARKER"')]'
) >"$TMPROOT/rce1-unit.out" 2>"$TMPROOT/rce1-unit.err"
RCE1_UNIT_STATUS=$?
if [ "$RCE1_UNIT_STATUS" -ne 0 ] && [ ! -e "$RCE1_UNIT_MARKER" ] && grep -q "not a valid identifier" "$TMPROOT/rce1-unit.err"; then
  pass "security: resolve_secret_value refuses a hostile key directly (defense layer 2)"
else
  fail "security: resolve_secret_value refuses a hostile key directly (defense layer 2)" \
    "status=$RCE1_UNIT_STATUS marker_exists=$([ -e "$RCE1_UNIT_MARKER" ] && echo yes || echo no) err=$(cat "$TMPROOT/rce1-unit.err")"
fi

# CRITICAL #2 regression: env.pane_name_aliases[] names were spliced
# unquoted into "export NAME=VALUE; " (only VALUE was %q-quoted), and
# lifecycle.sh executes that whole string via `bash -c`. A name like
# "EVIL; touch MARKER; export X" therefore injected a second statement.
RCE2_MARKER="$TMPROOT/rce2-pwned"
RCE2_DIR="$TMPROOT/rce2-project"
mkdir -p "$RCE2_DIR/.agent-workspace"
cat > "$RCE2_DIR/.agent-workspace/workspace.json" <<EOF
{"schema_version":1,"project":{"id":"rce2","root":"."},
"runtimes":{"claude":{"program":"claude"}},
"roles":{"orchestrator":{"runtime":"claude","env_group":"dev"}},
"stores":{"pin":[]},
"env":{"groups":{"dev":{"values":{}}},"pane_name_aliases":["EVIL; touch $RCE2_MARKER; export X"]},
"sessions":[{"id":"s","name":"s","panes":[{"name":"rce2-master","role":"orchestrator","cwd":"."}]}]}
EOF
RCE2_CFG="$RCE2_DIR/.agent-workspace/workspace.json"

RCE2_VALIDATE_OUT="$(bash "$HERE/validate-config.sh" --config "$RCE2_CFG" 2>&1)"
if [ $? -ne 0 ] && printf '%s' "$RCE2_VALIDATE_OUT" | grep -qE 'env\.pane_name_aliases entry .* must match \^\[A-Z_\]'; then
  pass "security: pane_name_aliases with an injected statement fails validation"
else
  fail "security: pane_name_aliases with an injected statement fails validation" "$RCE2_VALIDATE_OUT"
fi

RCE2_ENV_OUT="$(bash "$HERE/adapters.sh" env-exports --config "$RCE2_CFG" --pane rce2-master 2>"$TMPROOT/rce2-env.err")"
RCE2_ENV_STATUS=$?
# End-to-end: even if the (empty, error'd-out) stdout were fed to `bash -c`
# exactly as lifecycle.sh would, it must never touch the filesystem.
bash -c "${RCE2_ENV_OUT:-true}" >/dev/null 2>&1 || true
if [ "$RCE2_ENV_STATUS" -ne 0 ] && [ ! -e "$RCE2_MARKER" ]; then
  pass "security: adapters.sh env-exports refuses the hostile alias end-to-end (no side effect under bash -c)"
else
  fail "security: adapters.sh env-exports refuses the hostile alias end-to-end (no side effect under bash -c)" \
    "status=$RCE2_ENV_STATUS marker_exists=$([ -e "$RCE2_MARKER" ] && echo yes || echo no) out=$RCE2_ENV_OUT err=$(cat "$TMPROOT/rce2-env.err")"
fi

# Defense layer 2: render_env_exports must drop a hostile alias name even
# when called directly with an unvalidated ENV_PANE_NAME_ALIASES array, and
# the string it DOES produce must be inert under `bash -c`.
RCE2_UNIT_MARKER="$TMPROOT/rce2-unit-pwned"
RCE2_UNIT_OUT="$(
  source "$HERE/lib.sh"; source "$HERE/adapters.sh"
  # Every ENV_* global below is consumed by render_env_exports, not directly
  # referenced in this subshell -- shellcheck cannot see across that boundary.
  # shellcheck disable=SC2034
  ENV_PANE_NAME="rce2-master"
  # shellcheck disable=SC2034
  ENV_GROUP_VALUE_NAMES=()
  # shellcheck disable=SC2034
  ENV_GROUP_VALUE_VALUES=()
  # shellcheck disable=SC2034
  ENV_PANE_NAME_ALIASES=("EVIL; touch $RCE2_UNIT_MARKER; export X")
  # shellcheck disable=SC2034
  ENV_PIN_TO_SESSION="false"
  # shellcheck disable=SC2034
  ENV_COORD_VAR_NAMES=()
  # shellcheck disable=SC2034
  ENV_COORD_VAR_VALUES=()
  # shellcheck disable=SC2034
  ENV_TMUX_PANE_ID=""
  render_env_exports
)"
bash -c "$RCE2_UNIT_OUT" >/dev/null 2>&1 || true
if [ ! -e "$RCE2_UNIT_MARKER" ] && ! printf '%s' "$RCE2_UNIT_OUT" | grep -qF "$RCE2_UNIT_MARKER"; then
  pass "security: render_env_exports drops a hostile alias name directly (defense layer 2)"
else
  fail "security: render_env_exports drops a hostile alias name directly (defense layer 2)" "$RCE2_UNIT_OUT"
fi

echo "== Phase C: adapters.sh never invokes tmux (no mutation this phase) =="
ADAPT_TMUX_LOG="$TMPROOT/adapt-tmux-calls.log"
: > "$ADAPT_TMUX_LOG"
cat > "$STUBBIN/tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$ADAPT_TMUX_LOG"
exit 1
EOF
chmod +x "$STUBBIN/tmux"
PATH="$STUBBIN:$PATH" bash "$HERE/adapters.sh" agent-argv --config "$HERE/fixtures/valid/project-a.json" --pane project-a-master --exec >/dev/null 2>&1
PATH="$STUBBIN:$PATH" bash "$HERE/adapters.sh" env-exports --config "$HERE/fixtures/valid/project-a.json" --pane project-a-master >/dev/null 2>&1
SW_ADAPT_TMUX_TEST_FILE="$(PATH="$STUBBIN:$PATH" bash "$HERE/adapters.sh" secret-file --config "$SECRET_CFG" --pane p2-executor 2>/dev/null)"
rm -f "$SW_ADAPT_TMUX_TEST_FILE"
if [ -s "$ADAPT_TMUX_LOG" ]; then
  fail "adapters.sh never invokes tmux directly" "tmux was called: $(cat "$ADAPT_TMUX_LOG")"
else
  pass "adapters.sh never invokes tmux directly"
fi

# ============================================================================
# Phase D — tmux lifecycle, on a COMPLETELY ISOLATED tmux server.
#
# SAFETY CONTRACT (read before editing anything below):
#   * A dedicated $TMUX_TMPDIR AND a dedicated `-S <socket>` under $TMPROOT.
#   * Every tmux invocation the engine makes goes through a wrapper on PATH
#     that force-injects `-S "$SWT_SOCKET"`, so no engine code path can reach
#     the developer's real tmux server even if TMUX/TMUX_TMPDIR leak in.
#   * $TMUX is unset for every engine call (tmux prefers $TMUX's socket over
#     $TMUX_TMPDIR, so unsetting it is load-bearing, not decoration).
#   * Teardown kills ONLY that socket's server, and refuses to run at all
#     unless the socket path is inside $TMPROOT.
# Never add a kill-server/kill-session/kill-pane here that is not routed
# through "$SWT_TMUX".
# ============================================================================
echo "== Phase D: tmux lifecycle (isolated tmux server) =="

SWT_REAL_TMUX="$(command -v tmux 2>/dev/null || true)"
SWT_SOCKET=""
# A second, fully independent private socket used only by the "forced split
# failure" regression test below — it needs its own from-scratch server (no
# pre-existing sessions for a fresh session to inherit geometry from; see
# that test's comment) and is torn down the same way, through the same
# hard-guarded helper, immediately after that one test runs (not left for
# the final EXIT trap, so it never lingers as a second live server for the
# rest of this file's run).
SWT_SOCKET2=""
sw_tmux_teardown_one() {
  local sock="$1"
  [ -n "$sock" ] || return 0
  [ -n "$SWT_REAL_TMUX" ] || return 0
  # Hard guard: only ever tear down a socket we created under $TMPROOT.
  case "$sock" in
    "$TMPROOT"/*) ;;
    *) echo "REFUSING to tear down tmux socket outside \$TMPROOT: $sock" >&2; return 0 ;;
  esac
  "$SWT_REAL_TMUX" -S "$sock" kill-server >/dev/null 2>&1 || true
}
sw_tmux_teardown() {
  sw_tmux_teardown_one "$SWT_SOCKET"
  sw_tmux_teardown_one "$SWT_SOCKET2"
}
trap 'sw_tmux_teardown; rm -rf "$TMPROOT"' EXIT

if [ -z "$SWT_REAL_TMUX" ]; then
  log "tmux not installed; skipping the entire Phase D lifecycle section"
else

SWT_ROOT="$TMPROOT/lifecycle"
SWT_BIN="$SWT_ROOT/bin"
SWT_STATE="$SWT_ROOT/state"
SWT_TMPDIR="$SWT_ROOT/tmuxtmp"
SWT_SOCKET="$SWT_ROOT/sock"
SWT_CONF="$SWT_ROOT/tmux.conf"
mkdir -p "$SWT_BIN" "$SWT_STATE" "$SWT_TMPDIR"
chmod 700 "$SWT_TMPDIR"

# A large, explicit default pane geometry — NOT left to the host's terminal
# size or tmux's own compiled-in fallback. Pane-count assertions below split
# a real window down to 11 individual panes; on a host/runner whose default
# is small (or absent entirely, e.g. no controlling tty in CI), some of
# those splits can fail with "no space for new pane" well before 11 are
# reached, which is exactly the failure this suite must otherwise catch on
# purpose (see the "forced split failure" regression test) rather than hit
# by accident. This goes in a CONFIG FILE, loaded via `-f` on every tmux
# invocation, rather than a one-time `set-option -g default-size`: tmux's
# default `exit-empty` behavior kills the server the moment its last session
# closes (this suite's preflight session is killed below), and the next
# tmux command then transparently spawns a brand-new server process with
# none of the previous one's in-memory global options — a `-f`-loaded config
# file is read fresh on every such spawn, so it survives that restart.
cat > "$SWT_CONF" <<'EOF'
set-option -g default-size 200x50
EOF

cat > "$SWT_BIN/tmux" <<EOF
#!/usr/bin/env bash
# Isolation wrapper: pins EVERY tmux call to the test's private socket and
# private config (large deterministic default-size — see SWT_CONF above).
exec "$SWT_REAL_TMUX" -f "$SWT_CONF" -S "$SWT_SOCKET" "\$@"
EOF
chmod +x "$SWT_BIN/tmux"
# Agent runtimes are never really launched: inert long-lived stubs stand in
# for claude/codex so a pane's foreground process is stable and identifiable.
for swt_prog in claude codex; do
  printf '#!/usr/bin/env bash\nexec sleep 3600\n' > "$SWT_BIN/$swt_prog"
  chmod +x "$SWT_BIN/$swt_prog"
done

# Direct tmux access for the TEST's own assertions (same private socket AND
# the same -f config, so a test-created session — e.g. swt-preflight, an
# "unrelated-bystander"/"impostor-session" fixture — gets the same
# deterministic 200x50 default-size as everything the engine creates).
SWT_TMUX() { "$SWT_REAL_TMUX" -f "$SWT_CONF" -S "$SWT_SOCKET" "$@"; }
# Run an engine script inside the sandbox.
swrun() {
  env -u TMUX \
    TMUX_TMPDIR="$SWT_TMPDIR" \
    PATH="$SWT_BIN:$PATH" \
    XDG_STATE_HOME="$SWT_STATE" \
    SESSION_WORKSPACE_STOP_GRACE_SECONDS=0 \
    bash "$@"
}
swt_pane_field() { SWT_TMUX display-message -p -t "$1" "$2" 2>/dev/null; }
swt_names_in_window() {
  SWT_TMUX list-panes -t "$1" -F "#{pane_index}	#{@session_workspace_pane}" 2>/dev/null | sort -n | cut -f2- | tr '\n' ' '
}
swt_ids_in_window() {
  SWT_TMUX list-panes -t "$1" -F '#{pane_index}	#{pane_id}' 2>/dev/null | sort -n | cut -f2- | tr '\n' ' '
}

# --- pre-flight: prove the sandbox really is a separate server ------------
if [ "${SWT_SOCKET#"$TMPROOT"/}" != "$SWT_SOCKET" ]; then
  pass "lifecycle sandbox: tmux socket is inside the test tmpdir"
else
  fail "lifecycle sandbox: tmux socket is inside the test tmpdir" "socket=$SWT_SOCKET tmproot=$TMPROOT"
fi
SWT_TMUX new-session -d -s swt-preflight 'sleep 3600' >/dev/null 2>&1
if [ "$(SWT_TMUX list-sessions -F '#{session_name}' 2>/dev/null | tr '\n' ' ')" = "swt-preflight " ]; then
  pass "lifecycle sandbox: private server starts empty (no host sessions visible)"
else
  fail "lifecycle sandbox: private server starts empty (no host sessions visible)" \
    "sessions=$(SWT_TMUX list-sessions -F '#{session_name}' 2>/dev/null | tr '\n' ' ')"
fi
SWT_TMUX kill-session -t '=swt-preflight' >/dev/null 2>&1

# --- fixture project (placeholder names only) -----------------------------
SWT_PROJ="$SWT_ROOT/sample-project"
mkdir -p "$SWT_PROJ/.agent-workspace" "$SWT_PROJ/component-a" "$SWT_PROJ/component-b" "$SWT_PROJ/component-c"
jq '
  .project.id = "sample-project"
  | .project.display_name = "Sample Project"
  | .sessions |= map(.panes |= map(if has("command") then .command = ["sleep", "3600"] else . end))
' "$HERE/fixtures/valid/project-a.json" > "$SWT_PROJ/.agent-workspace/workspace.json"
SWT_CFG="$SWT_PROJ/.agent-workspace/workspace.json"
SWT_DEV='=sample-project-development:0'
SWT_SVC='=sample-project-services:0'

# --- 1. create -----------------------------------------------------------
SWT_OUT="$(swrun "$HERE/workspace-start.sh" --config "$SWT_CFG" --no-attach 2>&1)"
SWT_STATUS=$?
if [ "$SWT_STATUS" -eq 0 ] && printf '%s' "$SWT_OUT" | grep -q "started/adopted: 11  kept (already healthy): 0  failed: 0"; then
  pass "start: creates the full topology (11 panes across 2 sessions)"
else
  fail "start: creates the full topology (11 panes across 2 sessions)" "status=$SWT_STATUS output=$SWT_OUT"
fi

SWT_DEV_NAMES="$(swt_names_in_window "$SWT_DEV")"
SWT_EXPECT_DEV="sample-project-master sample-project-web-executor sample-project-web-reviewer sample-project-api-executor sample-project-api-reviewer sample-project-worker-executor sample-project-worker-reviewer "
if [ "$SWT_DEV_NAMES" = "$SWT_EXPECT_DEV" ]; then
  pass "start: development window panes carry the planned managed names, in order"
else
  fail "start: development window panes carry the planned managed names, in order" "got=[$SWT_DEV_NAMES]"
fi

# --- 2. split-tree: exact pane count + pane_order geometry ----------------
SWT_SVC_COUNT="$(SWT_TMUX list-panes -t "$SWT_SVC" -F '#{pane_id}' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$SWT_SVC_COUNT" = "4" ]; then
  pass "split_tree: builds exactly the 4 declared nodes (no extra/dropped panes)"
else
  fail "split_tree: builds exactly the 4 declared nodes (no extra/dropped panes)" "pane count=$SWT_SVC_COUNT"
fi

SWT_SVC_NAMES="$(swt_names_in_window "$SWT_SVC")"
SWT_EXPECT_SVC="sample-project-shell sample-project-web-service sample-project-api-service sample-project-worker-service "
if [ "$SWT_SVC_NAMES" = "$SWT_EXPECT_SVC" ]; then
  pass "split_tree: pane_order [top,bl,br,brb] maps onto the 4 configured panes in order"
else
  fail "split_tree: pane_order [top,bl,br,brb] maps onto the 4 configured panes in order" "got=[$SWT_SVC_NAMES]"
fi

# Geometry proves the TREE shape, not merely the count: top spans the top of
# the window; bl is bottom-left; br/brb are stacked bottom-right.
swt_geom() {
  SWT_TMUX list-panes -t "$SWT_SVC" -F "#{@session_workspace_pane}	#{pane_left}	#{pane_top}" 2>/dev/null |
    awk -F'\t' -v n="$1" '$1 == n {print $2 " " $3}'
}
SWT_G_TOP="$(swt_geom sample-project-shell)"
SWT_G_BL="$(swt_geom sample-project-web-service)"
SWT_G_BR="$(swt_geom sample-project-api-service)"
SWT_G_BRB="$(swt_geom sample-project-worker-service)"
# Compared RELATIVELY, never against absolute coordinates: tmux offsets the
# first row by the pane border/status line, so "top" sits at y=1, not y=0.
SWT_GEOM_OK=1
[ "${SWT_G_TOP% *}" = "0" ] || SWT_GEOM_OK=0                                          # top: left edge
[ "${SWT_G_BL% *}" = "0" ] || SWT_GEOM_OK=0                                           # bl:  left edge
[ "${SWT_G_BL#* }" -gt "${SWT_G_TOP#* }" ] 2>/dev/null || SWT_GEOM_OK=0               # bl:  below top
[ "${SWT_G_BR% *}" -gt "${SWT_G_BL% *}" ] 2>/dev/null || SWT_GEOM_OK=0                # br:  right of bl
[ "${SWT_G_BR#* }" = "${SWT_G_BL#* }" ] || SWT_GEOM_OK=0                              # br:  same row as bl
[ "${SWT_G_BRB% *}" = "${SWT_G_BR% *}" ] || SWT_GEOM_OK=0                             # brb: same column as br
[ "${SWT_G_BRB#* }" -gt "${SWT_G_BR#* }" ] 2>/dev/null || SWT_GEOM_OK=0               # brb: stacked under br
if [ "$SWT_GEOM_OK" -eq 1 ]; then
  pass "split_tree: resulting geometry matches the declared tree (top / bl / br+brb)"
else
  fail "split_tree: resulting geometry matches the declared tree (top / bl / br+brb)" \
    "top=[$SWT_G_TOP] bl=[$SWT_G_BL] br=[$SWT_G_BR] brb=[$SWT_G_BRB]"
fi

if grep -n 'split-window' "$HERE/tmux-lib.sh" "$HERE/lifecycle.sh" | grep -q -- ' -p '; then
  fail "split_tree: emits -l <pct>% and never the deprecated -p" "found a '-p' split-window invocation"
else
  pass "split_tree: emits -l <pct>% and never the deprecated -p"
fi

# --- 3. after-split-window hook: masked during build AND restored ---------
SWT_HOOK_WIN="$SWT_DEV"
SWT_TMUX set-hook -w -t "$SWT_HOOK_WIN" after-split-window 'run-shell -b "echo hook-one"' 2>/dev/null
SWT_TMUX set-hook -w -t "$SWT_HOOK_WIN" -a after-split-window 'run-shell -b "echo hook-two"' 2>/dev/null
SWT_HOOK_BEFORE="$(SWT_TMUX show-options -w -t "$SWT_HOOK_WIN" -v 'after-split-window[0]' 2>/dev/null)|$(SWT_TMUX show-options -w -t "$SWT_HOOK_WIN" -v 'after-split-window[1]' 2>/dev/null)"
SWT_HOOK_MASKED="$(env -u TMUX TMUX_TMPDIR="$SWT_TMPDIR" PATH="$SWT_BIN:$PATH" bash -c '
  source "$1/tmux-lib.sh"
  sw_mask_after_split_hook "$2"
  tmux show-options -w -t "$2" -v after-split-window
  sw_unmask_after_split_hook "$2"
' bash "$HERE" "$SWT_HOOK_WIN" 2>/dev/null)"
SWT_HOOK_AFTER="$(SWT_TMUX show-options -w -t "$SWT_HOOK_WIN" -v 'after-split-window[0]' 2>/dev/null)|$(SWT_TMUX show-options -w -t "$SWT_HOOK_WIN" -v 'after-split-window[1]' 2>/dev/null)"
if [ "$SWT_HOOK_MASKED" = "run-shell -b true" ]; then
  pass "after-split-window: masked with an inert hook while splitting"
else
  fail "after-split-window: masked with an inert hook while splitting" "masked value=[$SWT_HOOK_MASKED]"
fi
if [ "$SWT_HOOK_AFTER" = "$SWT_HOOK_BEFORE" ] && [ "$SWT_HOOK_BEFORE" != "|" ]; then
  pass "after-split-window: the user's pre-existing hook array is restored, not deleted"
else
  fail "after-split-window: the user's pre-existing hook array is restored, not deleted" \
    "before=[$SWT_HOOK_BEFORE] after=[$SWT_HOOK_AFTER]"
fi
SWT_TMUX set-hook -w -t "$SWT_HOOK_WIN" -u after-split-window 2>/dev/null

# --- 4. second start is idempotent ---------------------------------------
SWT_IDS_BEFORE="$(swt_ids_in_window "$SWT_DEV")$(swt_ids_in_window "$SWT_SVC")"
SWT_OUT="$(swrun "$HERE/workspace-start.sh" --config "$SWT_CFG" --no-attach 2>&1)"
SWT_STATUS=$?
SWT_IDS_AFTER="$(swt_ids_in_window "$SWT_DEV")$(swt_ids_in_window "$SWT_SVC")"
if [ "$SWT_STATUS" -eq 0 ] && printf '%s' "$SWT_OUT" | grep -q "started/adopted: 0  kept (already healthy): 11  failed: 0"; then
  pass "start: second run is idempotent — every healthy pane is kept, none respawned"
else
  fail "start: second run is idempotent — every healthy pane is kept, none respawned" "status=$SWT_STATUS output=$SWT_OUT"
fi
if [ "$SWT_IDS_AFTER" = "$SWT_IDS_BEFORE" ] && [ -n "$SWT_IDS_BEFORE" ]; then
  pass "start: second run leaves every pane id untouched (no silent respawn)"
else
  fail "start: second run leaves every pane id untouched (no silent respawn)" "before=[$SWT_IDS_BEFORE] after=[$SWT_IDS_AFTER]"
fi

# --- 4b. a forced split failure is REPORTED, never swallowed (regression) -
#
# Root cause this guards: when a planned pane's slot had no existing
# candidate AND the fallback `tmux split-window` genuinely failed (e.g. "no
# space for new pane"), the per-slot classifier saw an empty pane id and
# checked `optional="true"` FIRST -- true for every non-master pane in this
# fixture -- and reported it "[skipped] ... optional, cwd unavailable"
# without ever checking whether the cwd had actually resolved (it had; the
# earlier, correct skip_unresolved check is what "optional, cwd unavailable"
# is supposed to mean). That mislabeled skip never incremented
# SW_FAILED_SLOTS, so `start` printed [started] for every pane it DID
# create, exited 0, and looked completely healthy despite building a
# strictly incomplete topology. This test must FAIL against the old code.
#
# This needs its OWN from-scratch tmux server (a second, independent
# socket): a brand-new detached session inherits the size of an
# already-existing session on the same server when one exists, so shrinking
# `default-size` on the main $SWT_SOCKET (already carrying
# sample-project-development/-services at 200x50) would not reliably shrink
# a NEW session created on it. A clean server has no prior session to
# inherit from, so `default-size` alone (set via -f, the same
# survives-a-server-restart mechanism documented above) fully determines the
# geometry of the one session this test creates.
SWT_SOCKET2="$SWT_ROOT/sock-tiny"
SWT_TINY_CONF="$SWT_ROOT/tmux-tiny.conf"
SWT_TINY_BIN="$SWT_ROOT/bin-tiny"
SWT_TINY_TMPDIR="$SWT_ROOT/tmuxtmp-tiny"
SWT_TINY_STATE="$SWT_ROOT/state-tiny"
mkdir -p "$SWT_TINY_BIN" "$SWT_TINY_TMPDIR" "$SWT_TINY_STATE"
chmod 700 "$SWT_TINY_TMPDIR"
cat > "$SWT_TINY_CONF" <<'EOF'
set-option -g default-size 5x24
EOF
cat > "$SWT_TINY_BIN/tmux" <<EOF
#!/usr/bin/env bash
exec "$SWT_REAL_TMUX" -f "$SWT_TINY_CONF" -S "$SWT_SOCKET2" "\$@"
EOF
chmod +x "$SWT_TINY_BIN/tmux"
for swt_prog in claude codex; do
  printf '#!/usr/bin/env bash\nexec sleep 3600\n' > "$SWT_TINY_BIN/$swt_prog"
  chmod +x "$SWT_TINY_BIN/$swt_prog"
done

SWT_TINY_PROJ="$SWT_ROOT/tiny-project"
mkdir -p "$SWT_TINY_PROJ/.agent-workspace" "$SWT_TINY_PROJ/component-a" "$SWT_TINY_PROJ/component-b" "$SWT_TINY_PROJ/component-c"
jq '
  .project.id = "tiny-project"
  | .project.display_name = "Tiny Project"
  | .sessions |= map(.panes |= map(if has("command") then .command = ["sleep", "3600"] else . end))
  | .sessions |= map(select(.id == "development"))
' "$HERE/fixtures/valid/project-a.json" > "$SWT_TINY_PROJ/.agent-workspace/workspace.json"
SWT_TINY_CFG="$SWT_TINY_PROJ/.agent-workspace/workspace.json"

SWT_OUT="$(env -u TMUX \
  TMUX_TMPDIR="$SWT_TINY_TMPDIR" \
  PATH="$SWT_TINY_BIN:$PATH" \
  XDG_STATE_HOME="$SWT_TINY_STATE" \
  SESSION_WORKSPACE_STOP_GRACE_SECONDS=0 \
  bash "$HERE/workspace-start.sh" --config "$SWT_TINY_CFG" --no-attach 2>&1)"
SWT_STATUS=$?

if [ "$SWT_STATUS" -ne 0 ]; then
  pass "start: a genuinely failed split exits non-zero, never looks like success"
else
  fail "start: a genuinely failed split exits non-zero, never looks like success" "status=$SWT_STATUS output=$SWT_OUT"
fi
if printf '%s' "$SWT_OUT" | grep -Eq '\[failed\] tiny-project-development / tiny-project-[a-zA-Z-]+ — .+'; then
  pass "start: the specific pane and session that could not be built are named in a [failed] line"
else
  fail "start: the specific pane and session that could not be built are named in a [failed] line" "$SWT_OUT"
fi
if printf '%s' "$SWT_OUT" | grep -q "failed: 0"; then
  fail "start: the failed-slot count is non-zero when a split genuinely failed" "$SWT_OUT"
else
  pass "start: the failed-slot count is non-zero when a split genuinely failed"
fi
if printf '%s' "$SWT_OUT" | grep -Eqi "no space for (a )?new pane"; then
  pass "start: the reported reason is tmux's own stderr, not a generic placeholder"
else
  fail "start: the reported reason is tmux's own stderr, not a generic placeholder" "$SWT_OUT"
fi
if printf '%s' "$SWT_OUT" | grep -q "optional, cwd unavailable"; then
  fail "start: a failed split on an optional pane is never mislabeled as an unresolved-cwd skip" "$SWT_OUT"
else
  pass "start: a failed split on an optional pane is never mislabeled as an unresolved-cwd skip"
fi

sw_tmux_teardown_one "$SWT_SOCKET2"
SWT_SOCKET2=""

# --- 5. reconcile repairs a missing managed pane, restarts nothing else ---
SWT_VICTIM="$(SWT_TMUX list-panes -t "$SWT_DEV" -F "#{pane_id}	#{@session_workspace_pane}" 2>/dev/null | awk -F'\t' '$2 == "sample-project-web-reviewer" {print $1}')"
SWT_SURVIVOR_IDS="$(SWT_TMUX list-panes -t "$SWT_DEV" -F "#{pane_id}	#{@session_workspace_pane}" 2>/dev/null | awk -F'\t' -v v="$SWT_VICTIM" '$1 != v {print $1}' | sort | tr '\n' ' ')"
SWT_TMUX kill-pane -t "$SWT_VICTIM" >/dev/null 2>&1

SWT_OUT="$(swrun "$HERE/workspace-reconcile.sh" development --config "$SWT_CFG" 2>&1)"
if printf '%s' "$SWT_OUT" | grep -q "dry run — nothing was changed"; then
  pass "reconcile: default run is a dry run that changes nothing"
else
  fail "reconcile: default run is a dry run that changes nothing" "$SWT_OUT"
fi
if [ "$(SWT_TMUX list-panes -t "$SWT_DEV" -F '#{pane_id}' 2>/dev/null | wc -l | tr -d ' ')" = "6" ]; then
  pass "reconcile: the dry run really did not create the missing pane"
else
  fail "reconcile: the dry run really did not create the missing pane" "pane count changed"
fi

SWT_OUT="$(swrun "$HERE/workspace-reconcile.sh" development --config "$SWT_CFG" --apply 2>&1)"
SWT_STATUS=$?
SWT_SURVIVOR_AFTER="$(SWT_TMUX list-panes -t "$SWT_DEV" -F "#{pane_id}	#{@session_workspace_pane}" 2>/dev/null | awk -F'\t' -v n="sample-project-web-reviewer" '$2 != n {print $1}' | sort | tr '\n' ' ')"
if [ "$SWT_STATUS" -eq 0 ] && printf '%s' "$SWT_OUT" | grep -q "repaired/adopted: 1  kept (already healthy): 6  failed: 0"; then
  pass "reconcile --apply: repairs exactly the missing managed pane"
else
  fail "reconcile --apply: repairs exactly the missing managed pane" "status=$SWT_STATUS output=$SWT_OUT"
fi
if [ "$SWT_SURVIVOR_AFTER" = "$SWT_SURVIVOR_IDS" ]; then
  pass "reconcile --apply: healthy sibling panes are not restarted (ids stable)"
else
  fail "reconcile --apply: healthy sibling panes are not restarted (ids stable)" "before=[$SWT_SURVIVOR_IDS] after=[$SWT_SURVIVOR_AFTER]"
fi

# --- 6. unmanaged pane occupying a planned slot ---------------------------
SWT_VICTIM="$(SWT_TMUX list-panes -t "$SWT_DEV" -F "#{pane_id}	#{@session_workspace_pane}" 2>/dev/null | awk -F'\t' '$2 == "sample-project-web-reviewer" {print $1}')"
SWT_TMUX kill-pane -t "$SWT_VICTIM" >/dev/null 2>&1
SWT_FOREIGN="$(SWT_TMUX split-window -t "$SWT_DEV" -h -l 30% -P -F '#{pane_id}' 'sleep 3600' 2>/dev/null)"
SWT_TMUX set-option -p -t "$SWT_FOREIGN" @name "somebody-elses-pane" >/dev/null 2>&1

SWT_OUT="$(swrun "$HERE/workspace-start.sh" development --config "$SWT_CFG" --no-attach 2>&1)"
SWT_STATUS=$?
if [ "$SWT_STATUS" -ne 0 ] && printf '%s' "$SWT_OUT" | grep -q "unmanaged pane occupies this slot — left untouched"; then
  pass "start: an unmanaged pane in a planned slot FAILS that slot with guidance"
else
  fail "start: an unmanaged pane in a planned slot FAILS that slot with guidance" "status=$SWT_STATUS output=$SWT_OUT"
fi
if [ "$(swt_pane_field "$SWT_FOREIGN" '#{@name}')" = "somebody-elses-pane" ] &&
   [ -z "$(swt_pane_field "$SWT_FOREIGN" '#{@session_workspace_pane}')" ] &&
   [ "$(swt_pane_field "$SWT_FOREIGN" '#{pane_current_command}')" = "sleep" ]; then
  pass "start: the unmanaged pane is never renamed, marked, or respawned"
else
  fail "start: the unmanaged pane is never renamed, marked, or respawned" \
    "name=$(swt_pane_field "$SWT_FOREIGN" '#{@name}') marker=$(swt_pane_field "$SWT_FOREIGN" '#{@session_workspace_pane}') cmd=$(swt_pane_field "$SWT_FOREIGN" '#{pane_current_command}')"
fi

SWT_OUT="$(swrun "$HERE/workspace-start.sh" development --config "$SWT_CFG" --no-attach --adopt 2>&1)"
SWT_STATUS=$?
if [ "$SWT_STATUS" -ne 0 ] && printf '%s' "$SWT_OUT" | grep -q -- "--adopt requires --confirmed"; then
  pass "start: --adopt without --confirmed is refused"
else
  fail "start: --adopt without --confirmed is refused" "status=$SWT_STATUS output=$SWT_OUT"
fi
SWT_OUT="$(swrun "$HERE/workspace-reconcile.sh" development --config "$SWT_CFG" --apply --adopt 2>&1)"
SWT_STATUS=$?
if [ "$SWT_STATUS" -ne 0 ] && printf '%s' "$SWT_OUT" | grep -q -- "--adopt requires --confirmed"; then
  pass "reconcile: --adopt without --confirmed is refused"
else
  fail "reconcile: --adopt without --confirmed is refused" "status=$SWT_STATUS output=$SWT_OUT"
fi

# --adopt --confirmed WITHOUT --apply (dry run) must still preview exactly
# what would be adopted -- workspace-reconcile.md promises the adoption plan
# "always prints ... (even in dry-run / without --apply)". Run it here, before
# the real --apply below, and prove the foreign pane is NOT touched by it.
SWT_OUT="$(swrun "$HERE/workspace-reconcile.sh" development --config "$SWT_CFG" --adopt --confirmed 2>&1)"
SWT_STATUS=$?
if [ "$SWT_STATUS" -eq 0 ] &&
   printf '%s' "$SWT_OUT" | grep -q -- "-- adoption candidate --" &&
   printf '%s' "$SWT_OUT" | grep -q -- "\[would-adopt\] sample-project-development / sample-project-web-reviewer" &&
   printf '%s' "$SWT_OUT" | grep -q "dry run — nothing was changed"; then
  pass "reconcile --adopt --confirmed (no --apply): previews the adoption candidate without mutating"
else
  fail "reconcile --adopt --confirmed (no --apply): previews the adoption candidate without mutating" "status=$SWT_STATUS output=$SWT_OUT"
fi
if [ -z "$(swt_pane_field "$SWT_FOREIGN" '#{@session_workspace_pane}')" ] &&
   [ "$(swt_pane_field "$SWT_FOREIGN" '#{pane_current_command}')" = "sleep" ]; then
  pass "reconcile --adopt --confirmed (no --apply): the foreign pane is NOT actually claimed"
else
  fail "reconcile --adopt --confirmed (no --apply): the foreign pane is NOT actually claimed" \
    "marker=$(swt_pane_field "$SWT_FOREIGN" '#{@session_workspace_pane}') cmd=$(swt_pane_field "$SWT_FOREIGN" '#{pane_current_command}')"
fi

SWT_OUT="$(swrun "$HERE/workspace-reconcile.sh" development --config "$SWT_CFG" --apply --adopt --confirmed 2>&1)"
SWT_STATUS=$?
SWT_PLAN_LINE="$(printf '%s\n' "$SWT_OUT" | grep -n -- "-- adoption candidate --" | head -n1 | cut -d: -f1)"
SWT_ADOPT_LINE="$(printf '%s\n' "$SWT_OUT" | grep -n -- "\[adopted\]" | head -n1 | cut -d: -f1)"
if [ "$SWT_STATUS" -eq 0 ] && [ -n "$SWT_PLAN_LINE" ] && [ -n "$SWT_ADOPT_LINE" ] && [ "$SWT_PLAN_LINE" -lt "$SWT_ADOPT_LINE" ]; then
  pass "reconcile --adopt --confirmed: prints the adoption plan BEFORE claiming the pane"
else
  fail "reconcile --adopt --confirmed: prints the adoption plan BEFORE claiming the pane" "status=$SWT_STATUS output=$SWT_OUT"
fi
if [ "$(swt_pane_field "$SWT_FOREIGN" '#{@session_workspace_pane}')" = "sample-project-web-reviewer" ]; then
  pass "reconcile --adopt --confirmed: the pane is claimed and carries the managed marker"
else
  fail "reconcile --adopt --confirmed: the pane is claimed and carries the managed marker" \
    "marker=$(swt_pane_field "$SWT_FOREIGN" '#{@session_workspace_pane}')"
fi

# --- 7. foreign / surplus resources are preserved -------------------------
SWT_TMUX new-session -d -s "unrelated-bystander" 'sleep 3600' >/dev/null 2>&1
SWT_SURPLUS="$(SWT_TMUX split-window -t "$SWT_SVC" -v -l 20% -P -F '#{pane_id}' 'sleep 3600' 2>/dev/null)"
swrun "$HERE/workspace-start.sh" --config "$SWT_CFG" --no-attach >/dev/null 2>&1
if SWT_TMUX has-session -t '=unrelated-bystander' 2>/dev/null &&
   [ -n "$(swt_pane_field "$SWT_SURPLUS" '#{pane_id}')" ] &&
   [ -z "$(swt_pane_field "$SWT_SURPLUS" '#{@session_workspace_pane}')" ]; then
  pass "start: a foreign session and a surplus pane in a managed window are both preserved"
else
  fail "start: a foreign session and a surplus pane in a managed window are both preserved" \
    "bystander=$(SWT_TMUX has-session -t '=unrelated-bystander' 2>&1) surplus=$(swt_pane_field "$SWT_SURPLUS" '#{pane_id}')"
fi
SWT_TMUX kill-pane -t "$SWT_SURPLUS" >/dev/null 2>&1

# --- 8. locking -----------------------------------------------------------
SWT_LOCK_DIR="$SWT_STATE/session-workspace/sample-project/lock"
mkdir -p "$SWT_LOCK_DIR"
printf '%s\n' "$$" > "$SWT_LOCK_DIR/pid"   # a definitely-alive pid
SWT_OUT="$(env -u TMUX TMUX_TMPDIR="$SWT_TMPDIR" PATH="$SWT_BIN:$PATH" XDG_STATE_HOME="$SWT_STATE" \
  SESSION_WORKSPACE_LOCK_TIMEOUT=2 bash "$HERE/workspace-start.sh" --config "$SWT_CFG" --no-attach 2>&1)"
SWT_STATUS=$?
if [ "$SWT_STATUS" -ne 0 ] && printf '%s' "$SWT_OUT" | grep -q "could not acquire workspace lock"; then
  pass "lock: a start blocked by a live lock holder fails instead of racing"
else
  fail "lock: a start blocked by a live lock holder fails instead of racing" "status=$SWT_STATUS output=$SWT_OUT"
fi
printf '%s\n' "99999999" > "$SWT_LOCK_DIR/pid"   # dead pid => stale lock
SWT_OUT="$(env -u TMUX TMUX_TMPDIR="$SWT_TMPDIR" PATH="$SWT_BIN:$PATH" XDG_STATE_HOME="$SWT_STATE" \
  SESSION_WORKSPACE_LOCK_TIMEOUT=2 bash "$HERE/workspace-start.sh" --config "$SWT_CFG" --no-attach 2>&1)"
SWT_STATUS=$?
if [ "$SWT_STATUS" -eq 0 ] && printf '%s' "$SWT_OUT" | grep -q "reclaiming stale workspace lock"; then
  pass "lock: a stale lock (dead holder pid) is detected and reclaimed"
else
  fail "lock: a stale lock (dead holder pid) is detected and reclaimed" "status=$SWT_STATUS output=$SWT_OUT"
fi

# Concurrent starts must SERIALIZE: two racing starts against a fresh project
# must not double-split anything.
SWT_PROJ2="$SWT_ROOT/sample-solo"
mkdir -p "$SWT_PROJ2/.agent-workspace"
jq '.project.id = "sample-solo" | .project.display_name = "Sample Solo"' \
  "$HERE/fixtures/valid/project-d.json" > "$SWT_PROJ2/.agent-workspace/workspace.json"
SWT_CFG2="$SWT_PROJ2/.agent-workspace/workspace.json"

# --- 8a. reconcile dry-run against a session that does not exist yet: the
# per-pane "would-create" report must never be duplicated/corrupted. A prior
# defect had _sw_ensure_session print its own "[would-create] ... (session)"
# line to STDOUT while its caller captured that same stdout as the session
# name via command substitution -- so the captured "session name" became a
# two-line string containing the report text itself, and every subsequent
# per-pane report line embedded it, producing a doubled "[would-create]
# [would-create] ..." marker and a session name that was no longer a single
# clean token.
SWT_OUT="$(swrun "$HERE/workspace-reconcile.sh" --config "$SWT_CFG2" 2>&1)"
SWT_WOULD_CREATE_COUNT="$(printf '%s\n' "$SWT_OUT" | grep -c '\[would-create\]')"
SWT_DUP_MARKER_COUNT="$(printf '%s\n' "$SWT_OUT" | grep -c '\[would-create\].*\[would-create\]')"
if [ "$SWT_WOULD_CREATE_COUNT" = "2" ] && [ "$SWT_DUP_MARKER_COUNT" = "0" ]; then
  pass "reconcile dry-run (fresh session): [would-create] appears exactly once per pane"
else
  fail "reconcile dry-run (fresh session): [would-create] appears exactly once per pane" \
    "would_create_count=$SWT_WOULD_CREATE_COUNT dup_marker_lines=$SWT_DUP_MARKER_COUNT output=$SWT_OUT"
fi
if printf '%s\n' "$SWT_OUT" | grep -qx '  \[would-create\] sample-solo-development / sample-solo-master — fresh session' &&
   printf '%s\n' "$SWT_OUT" | grep -qx '  \[would-create\] sample-solo-development / sample-solo-executor — fresh session'; then
  pass "reconcile dry-run (fresh session): the session name is a single clean line, not corrupted"
else
  fail "reconcile dry-run (fresh session): the session name is a single clean line, not corrupted" "$SWT_OUT"
fi
if ! SWT_TMUX has-session -t '=sample-solo-development' 2>/dev/null; then
  pass "reconcile dry-run (fresh session): really did not create the session"
else
  fail "reconcile dry-run (fresh session): really did not create the session" "session exists after dry run"
fi

swrun "$HERE/workspace-start.sh" --config "$SWT_CFG2" --no-attach >"$TMPROOT/race-a.log" 2>&1 &
SWT_RACE_A=$!
swrun "$HERE/workspace-start.sh" --config "$SWT_CFG2" --no-attach >"$TMPROOT/race-b.log" 2>&1 &
SWT_RACE_B=$!
wait "$SWT_RACE_A"; SWT_RACE_A_ST=$?
wait "$SWT_RACE_B"; SWT_RACE_B_ST=$?
SWT_SOLO_COUNT="$(SWT_TMUX list-panes -t '=sample-solo-development:0' -F '#{pane_id}' 2>/dev/null | wc -l | tr -d ' ')"
SWT_SOLO_NAMES="$(swt_names_in_window '=sample-solo-development:0')"
if [ "$SWT_SOLO_COUNT" = "2" ] && [ "$SWT_SOLO_NAMES" = "sample-solo-master sample-solo-executor " ]; then
  pass "lock: two concurrent starts serialize — exactly the 2 planned panes exist"
else
  fail "lock: two concurrent starts serialize — exactly the 2 planned panes exist" \
    "count=$SWT_SOLO_COUNT names=[$SWT_SOLO_NAMES] a=$SWT_RACE_A_ST/$(cat "$TMPROOT/race-a.log") b=$SWT_RACE_B_ST/$(cat "$TMPROOT/race-b.log")"
fi

# --- 9. layout save/restore round-trip ------------------------------------
SWT_LAYOUT_OUT="$(env -u TMUX TMUX_TMPDIR="$SWT_TMPDIR" PATH="$SWT_BIN:$PATH" XDG_STATE_HOME="$SWT_STATE" bash -c '
  source "$1/tmux-lib.sh"
  win="$2"
  tmux select-layout -t "$win" tiled >/dev/null 2>&1
  sw_save_layout sample-project development "$win" || { echo "SAVE-FAILED"; exit 0; }
  saved="$(tmux display-message -p -t "$win" "#{window_layout}")"
  tmux select-layout -t "$win" even-horizontal >/dev/null 2>&1
  changed="$(tmux display-message -p -t "$win" "#{window_layout}")"
  sw_restore_layout sample-project development "$win" || { echo "RESTORE-FAILED"; exit 0; }
  now="$(tmux display-message -p -t "$win" "#{window_layout}")"
  if [ "$saved" = "$changed" ]; then echo "NO-CHANGE"; exit 0; fi
  if [ "$saved" = "$now" ]; then echo "ROUNDTRIP-OK"; else echo "MISMATCH saved=$saved now=$now"; fi
' bash "$HERE" "$SWT_DEV" 2>&1)"
if [ "$SWT_LAYOUT_OUT" = "ROUNDTRIP-OK" ]; then
  pass "layout: save/restore round-trips the window layout exactly"
else
  fail "layout: save/restore round-trips the window layout exactly" "$SWT_LAYOUT_OUT"
fi
if [ -s "$SWT_STATE/session-workspace/sample-project/layouts/development.layout" ]; then
  pass "layout: persisted under \$XDG_STATE_HOME/session-workspace/<project-id>/layouts/"
else
  fail "layout: persisted under \$XDG_STATE_HOME/session-workspace/<project-id>/layouts/" "file missing or empty"
fi
SWT_LAYOUT_MODE="$(stat -c '%a' "$SWT_STATE/session-workspace/sample-project/layouts/development.layout" 2>/dev/null ||
                   stat -f '%Lp' "$SWT_STATE/session-workspace/sample-project/layouts/development.layout" 2>/dev/null)"
if [ "$SWT_LAYOUT_MODE" = "600" ]; then
  pass "layout: state file is owner-only (umask 077)"
else
  fail "layout: state file is owner-only (umask 077)" "mode=$SWT_LAYOUT_MODE"
fi

# --- 10. status is read-only ----------------------------------------------
SWT_IDS_BEFORE="$(swt_ids_in_window "$SWT_DEV")$(swt_ids_in_window "$SWT_SVC")"
SWT_STATUS_JSON="$(swrun "$HERE/workspace-status.sh" --config "$SWT_CFG" --json 2>&1)"
SWT_IDS_AFTER="$(swt_ids_in_window "$SWT_DEV")$(swt_ids_in_window "$SWT_SVC")"
if [ "$SWT_IDS_AFTER" = "$SWT_IDS_BEFORE" ] &&
   printf '%s' "$SWT_STATUS_JSON" | jq -e '[.[] | select(.health == "healthy")] | length == 11' >/dev/null 2>&1; then
  pass "status: reports all 11 panes healthy and mutates nothing"
else
  fail "status: reports all 11 panes healthy and mutates nothing" "$SWT_STATUS_JSON"
fi
if printf '%s' "$SWT_STATUS_JSON" | jq -e 'all(.session_exists == true and .session_managed == true)' >/dev/null 2>&1; then
  pass "status: reports both sessions as existing AND managed by this project"
else
  fail "status: reports both sessions as existing AND managed by this project" "$SWT_STATUS_JSON"
fi

# --- 10a. status: unknown target is rejected, not silently returning [] ---
SWT_OUT="$(swrun "$HERE/workspace-status.sh" bogus-target --config "$SWT_CFG" 2>&1)"
SWT_STATUS=$?
if [ "$SWT_STATUS" -ne 0 ] && printf '%s' "$SWT_OUT" | grep -q 'unknown session target "bogus-target"'; then
  pass "status: an unknown target exits non-zero with a clear error"
else
  fail "status: an unknown target exits non-zero with a clear error" "status=$SWT_STATUS output=$SWT_OUT"
fi
SWT_OUT="$(swrun "$HERE/workspace-status.sh" development --config "$SWT_CFG" --json 2>&1)"
SWT_STATUS=$?
if [ "$SWT_STATUS" -eq 0 ] && printf '%s' "$SWT_OUT" | jq -e 'length > 0' >/dev/null 2>&1; then
  pass "status: a valid target still works after adding target validation"
else
  fail "status: a valid target still works after adding target validation" "status=$SWT_STATUS output=$SWT_OUT"
fi

# --- 10a-2. status: pane search is scoped to the target session, never the
# whole server -- a stale same-named marker left on a pane in some OTHER
# session must not false-report health for this project's slot.
SWT_TMUX new-session -d -s "impostor-session" 'sleep 3600' >/dev/null 2>&1
SWT_IMPOSTOR_PANE="$(SWT_TMUX list-panes -t '=impostor-session' -F '#{pane_id}' 2>/dev/null | head -n1)"
SWT_TMUX set-option -p -t "$SWT_IMPOSTOR_PANE" @session_workspace_project "sample-project" >/dev/null 2>&1
SWT_TMUX set-option -p -t "$SWT_IMPOSTOR_PANE" @session_workspace_pane "sample-project-shell" >/dev/null 2>&1
SWT_REAL_SHELL_PANE="$(SWT_TMUX list-panes -t "$SWT_SVC" -F "#{pane_id}	#{@session_workspace_pane}" 2>/dev/null | awk -F'\t' '$2 == "sample-project-shell" {print $1}')"
SWT_STATUS_JSON2="$(swrun "$HERE/workspace-status.sh" services --config "$SWT_CFG" --json 2>&1)"
SWT_REPORTED_PANE="$(printf '%s' "$SWT_STATUS_JSON2" | jq -r '.[] | select(.pane == "sample-project-shell") | .pane_id')"
if [ -n "$SWT_REAL_SHELL_PANE" ] && [ "$SWT_REPORTED_PANE" = "$SWT_REAL_SHELL_PANE" ] && [ "$SWT_REPORTED_PANE" != "$SWT_IMPOSTOR_PANE" ]; then
  pass "status: pane search is scoped to the target session (a same-named marker elsewhere is ignored)"
else
  fail "status: pane search is scoped to the target session (a same-named marker elsewhere is ignored)" \
    "reported=$SWT_REPORTED_PANE real=$SWT_REAL_SHELL_PANE impostor=$SWT_IMPOSTOR_PANE"
fi
SWT_TMUX kill-session -t '=impostor-session' >/dev/null 2>&1

# --- 10a-3. an optional pane whose cwd is absent (un-cloned child repo) is
# never launched -- it must be skipped BEFORE slot allocation, never handed
# the inherited/empty cwd of whatever process launched the engine.
SWT_PROJ_PARTIAL="$SWT_ROOT/sample-partial"
mkdir -p "$SWT_PROJ_PARTIAL/.agent-workspace"
cat > "$SWT_PROJ_PARTIAL/.agent-workspace/workspace.json" <<'EOF'
{"schema_version":1,"project":{"id":"sample-partial","root":"."},
"runtimes":{"claude":{"program":"claude"}},
"roles":{"orchestrator":{"runtime":"claude","grants":[],"env_group":"dev"}},
"stores":{"pin":[]},
"env":{"groups":{"dev":{"values":{}}}},
"sessions":[{"id":"development","name":"sample-partial-development","panes":[
  {"name":"sample-partial-master","role":"orchestrator","cwd":"."},
  {"name":"sample-partial-child","role":"orchestrator","cwd":"not-cloned-yet","optional":true}
]}]}
EOF
SWT_CFG_PARTIAL="$SWT_PROJ_PARTIAL/.agent-workspace/workspace.json"

SWT_PLAN_PARTIAL="$(bash "$HERE/workspace-plan.sh" --config "$SWT_CFG_PARTIAL" 2>&1)"
if printf '%s' "$SWT_PLAN_PARTIAL" | grep -q -- 'sample-partial-child.*\[SKIPPED: cwd unavailable'; then
  pass "plan: an optional pane with an unresolved cwd is shown as skipped"
else
  fail "plan: an optional pane with an unresolved cwd is shown as skipped" "$SWT_PLAN_PARTIAL"
fi

SWT_OUT="$(swrun "$HERE/workspace-start.sh" --config "$SWT_CFG_PARTIAL" --no-attach 2>&1)"
SWT_STATUS=$?
if [ "$SWT_STATUS" -eq 0 ] &&
   printf '%s' "$SWT_OUT" | grep -q '\[skipped\] sample-partial-development / sample-partial-child — optional, cwd unavailable' &&
   printf '%s' "$SWT_OUT" | grep -q "started/adopted: 1  kept (already healthy): 0  failed: 0"; then
  pass "start: an optional pane with an absent cwd is skipped, not launched"
else
  fail "start: an optional pane with an absent cwd is skipped, not launched" "status=$SWT_STATUS output=$SWT_OUT"
fi
SWT_PARTIAL_PANE_COUNT="$(SWT_TMUX list-panes -t '=sample-partial-development:0' -F '#{pane_id}' 2>/dev/null | wc -l | tr -d ' ')"
SWT_PARTIAL_CHILD_MARKER="$(SWT_TMUX list-panes -t '=sample-partial-development:0' -F '#{@session_workspace_pane}' 2>/dev/null | grep -c '^sample-partial-child$')"
if [ "$SWT_PARTIAL_PANE_COUNT" = "1" ] && [ "$SWT_PARTIAL_CHILD_MARKER" = "0" ]; then
  pass "start: no pane is ever allocated/claimed for the skipped optional slot"
else
  fail "start: no pane is ever allocated/claimed for the skipped optional slot" \
    "pane_count=$SWT_PARTIAL_PANE_COUNT child_marker_matches=$SWT_PARTIAL_CHILD_MARKER"
fi

# The same must hold on the split_tree path, which is a DIFFERENT slot
# allocator: it builds every node in layout.nodes unconditionally and maps
# pane_order onto the pane slots positionally, so the skip cannot come from
# "no pane was allocated" there -- only the per-slot skip_unresolved check can
# stop it. Without that check the optional pane's agent is launched in the
# WRONG directory (whatever cwd the split inherited), which is silent and
# indistinguishable from success.
SWT_PROJ_PARTIAL_ST="$SWT_ROOT/sample-partial-tree"
mkdir -p "$SWT_PROJ_PARTIAL_ST/.agent-workspace"
cat > "$SWT_PROJ_PARTIAL_ST/.agent-workspace/workspace.json" <<'EOF'
{"schema_version":1,"project":{"id":"sample-partial-tree","root":"."},
"runtimes":{"claude":{"program":"claude"}},
"roles":{"orchestrator":{"runtime":"claude","grants":[],"env_group":"dev"}},
"stores":{"pin":[]},
"env":{"groups":{"dev":{"values":{}}}},
"sessions":[{"id":"development","name":"sample-partial-tree-development",
"layout":{"kind":"split_tree","only_when_fresh":true,
  "nodes":[{"id":"top"},{"id":"bottom","from":"top","dir":"v","percent":50}],
  "pane_order":["top","bottom"]},
"panes":[
  {"name":"sample-partial-tree-master","role":"orchestrator","cwd":"."},
  {"name":"sample-partial-tree-child","role":"orchestrator","cwd":"not-cloned-yet","optional":true}
]}]}
EOF
SWT_CFG_PARTIAL_ST="$SWT_PROJ_PARTIAL_ST/.agent-workspace/workspace.json"
SWT_OUT="$(swrun "$HERE/workspace-start.sh" --config "$SWT_CFG_PARTIAL_ST" --no-attach 2>&1)"
SWT_STATUS=$?
SWT_PST_WIN='=sample-partial-tree-development:0'
SWT_PST_CHILD_MARKED="$(SWT_TMUX list-panes -t "$SWT_PST_WIN" -F '#{@session_workspace_pane}' 2>/dev/null | grep -c '^sample-partial-tree-child$')"
SWT_PST_LAUNCHED="$(SWT_TMUX list-panes -t "$SWT_PST_WIN" -F '#{@session_workspace_launched}' 2>/dev/null | grep -c 'claude')"
if [ "$SWT_STATUS" -eq 0 ] &&
   printf '%s' "$SWT_OUT" | grep -q '\[skipped\] sample-partial-tree-development / sample-partial-tree-child — optional, cwd unavailable' &&
   printf '%s' "$SWT_OUT" | grep -q "started/adopted: 1  kept (already healthy): 0  failed: 0" &&
   [ "$SWT_PST_CHILD_MARKED" = "0" ] && [ "$SWT_PST_LAUNCHED" = "1" ]; then
  pass "start (split_tree): an optional pane with an absent cwd is skipped, never claimed or launched"
else
  fail "start (split_tree): an optional pane with an absent cwd is skipped, never claimed or launched" \
    "status=$SWT_STATUS child_marked=$SWT_PST_CHILD_MARKED launched_panes=$SWT_PST_LAUNCHED output=$SWT_OUT"
fi

# --- 10b. secret delivery: hidden session env, never send-keys ------------
SWT_SECRET="LIFECYCLE-SECRET-4b1c9ae207"
SWT_PROJ3="$SWT_ROOT/sample-vault"
mkdir -p "$SWT_PROJ3/.agent-workspace"
# secrets.env_file validation requires a real repo: it hard-fails unless the
# file is verifiably git-ignored, so the fixture has to be a git repository.
( cd "$SWT_PROJ3" && git init -q . )
cat > "$SWT_PROJ3/.agent-workspace/workspace.json" <<'EOF'
{"schema_version":1,"project":{"id":"sample-vault","root":"."},
"runtimes":{"claude":{"program":"claude"},"codex":{"program":"codex"}},
"roles":{"orchestrator":{"runtime":"claude","grants":[],"env_group":"dev"},
         "executor":{"runtime":"codex","grants":[],"env_group":"dev"}},
"stores":{"pin":[]},
"env":{"groups":{"dev":{"values":{}}}},
"secrets":{"env_file":"workspace.local.env","allow":["SAMPLE_TOKEN"],
           "visible_to_roles":["executor"],"on_missing":"warn"},
"sessions":[{"id":"development","name":"sample-vault-development","panes":[
  {"name":"sample-vault-master","role":"orchestrator","cwd":"."},
  {"name":"sample-vault-executor","role":"executor","cwd":"."}
]}]}
EOF
( umask 077; printf 'SAMPLE_TOKEN=%s\n' "$SWT_SECRET" > "$SWT_PROJ3/workspace.local.env" )
chmod 600 "$SWT_PROJ3/workspace.local.env"
printf 'workspace.local.env\n' > "$SWT_PROJ3/.gitignore"
SWT_CFG3="$SWT_PROJ3/.agent-workspace/workspace.json"
SWT_VAULT_LOG="$TMPROOT/vault-start.log"

# Temporarily swap the inert claude/codex stubs for ones that dump their own
# argv AND their SAMPLE_TOKEN env var to a per-pane file (keyed by
# KNOWLEDGE_PANE_NAME, an engine-always var every pane gets), then restore
# the plain stubs immediately after this sub-test. This is what proves
# delivery reaches the actual spawned PROCESS's environment -- not merely
# tmux session metadata (plan defect #1: `set-environment -h` never does).
rm -f "$SWT_ROOT"/dump-*.txt
cat > "$SWT_BIN/claude" <<EOF
#!/usr/bin/env bash
{ printf 'ARGV:'; printf ' %s' "\$@"; printf '\n'; printf 'SAMPLE_TOKEN=%s\n' "\${SAMPLE_TOKEN:-<unset>}"; } \\
  > "$SWT_ROOT/dump-\${KNOWLEDGE_PANE_NAME:-unknown}.txt" 2>&1
exec sleep 3600
EOF
cp "$SWT_BIN/claude" "$SWT_BIN/codex"
chmod +x "$SWT_BIN/claude" "$SWT_BIN/codex"

swrun "$HERE/workspace-start.sh" --config "$SWT_CFG3" --no-attach > "$SWT_VAULT_LOG" 2>&1
sleep 1
SWT_VAULT_SESSION='=sample-vault-development'

# Positive control: the AUTHORIZED pane's spawned process receives it.
SWT_DUMP_EXECUTOR="$SWT_ROOT/dump-sample-vault-executor.txt"
if [ -f "$SWT_DUMP_EXECUTOR" ] && grep -qF "SAMPLE_TOKEN=$SWT_SECRET" "$SWT_DUMP_EXECUTOR"; then
  pass "secrets: the authorized pane's spawned PROCESS receives the secret in its own environment"
else
  fail "secrets: the authorized pane's spawned PROCESS receives the secret in its own environment" \
    "$(cat "$SWT_DUMP_EXECUTOR" 2>/dev/null || echo "dump file missing")"
fi
# Negative control: the NON-authorized pane (orchestrator, not in
# visible_to_roles) gets nothing -- same run, same stub, so a pass here
# cannot mean "feature inert" (the positive control above proves it fires).
SWT_DUMP_MASTER="$SWT_ROOT/dump-sample-vault-master.txt"
if [ -f "$SWT_DUMP_MASTER" ] && grep -q "SAMPLE_TOKEN=<unset>" "$SWT_DUMP_MASTER"; then
  pass "secrets: a non-authorized pane's spawned process never receives the secret"
else
  fail "secrets: a non-authorized pane's spawned process never receives the secret" \
    "$(cat "$SWT_DUMP_MASTER" 2>/dev/null || echo "dump file missing")"
fi
# Neither pane's own argv (as it saw it, dumped as the "ARGV:" line) contains
# the secret -- only the KEY=VALUE line (from printenv, not argv) should.
if grep "^ARGV:" "$SWT_DUMP_EXECUTOR" "$SWT_DUMP_MASTER" 2>/dev/null | grep -qF "$SWT_SECRET"; then
  fail "secrets: the value never appears in the spawned process's own argv" "leaked"
else
  pass "secrets: the value never appears in the spawned process's own argv"
fi

# The engine's own tmux client invocation must never carry the plaintext
# value either -- assert against a CAPTURED spawn command, not a racy `ps`
# snapshot (which would also catch this very test's own `grep -qF
# "$SWT_SECRET"` argv and prove nothing about the engine). A logging tmux
# wrapper records every argv it is called with; this is the same class of
# check that already exists for "adapters.sh never invokes tmux" above, just
# aimed at lifecycle.sh's respawn-pane calls this time.
SWT_TMUX_ARGV_LOG="$TMPROOT/vault-tmux-argv.log"
: > "$SWT_TMUX_ARGV_LOG"
cat > "$SWT_BIN/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SWT_TMUX_ARGV_LOG"
exec "$SWT_REAL_TMUX" -S "$SWT_SOCKET" "\$@"
EOF
chmod +x "$SWT_BIN/tmux"
swrun "$HERE/workspace-restart.sh" development --config "$SWT_CFG3" --no-attach --no-save >/dev/null 2>&1
if grep -qF "$SWT_SECRET" "$SWT_TMUX_ARGV_LOG"; then
  fail "secrets: the engine's own tmux invocations never carry the value in argv (captured spawn command)" \
    "leaked into $SWT_TMUX_ARGV_LOG"
else
  pass "secrets: the engine's own tmux invocations never carry the value in argv (captured spawn command)"
fi
# Restore the plain (non-logging) tmux wrapper.
cat > "$SWT_BIN/tmux" <<EOF
#!/usr/bin/env bash
# Isolation wrapper: pins EVERY tmux call to the test's private socket.
exec "$SWT_REAL_TMUX" -S "$SWT_SOCKET" "\$@"
EOF
chmod +x "$SWT_BIN/tmux"

SWT_ENV_PLAIN="$(SWT_TMUX show-environment -t "$SWT_VAULT_SESSION" 2>/dev/null)"
SWT_ENV_HIDDEN="$(SWT_TMUX show-environment -h -t "$SWT_VAULT_SESSION" 2>/dev/null)"
if printf '%s' "$SWT_ENV_PLAIN" | grep -qF "$SWT_SECRET"; then
  fail "secrets: the value never appears in plain show-environment" "leaked into plain session env"
else
  pass "secrets: the value never appears in plain show-environment"
fi
if printf '%s' "$SWT_ENV_HIDDEN" | grep -qF "$SWT_SECRET"; then
  fail "secrets: the value never appears in hidden show-environment either (no tmux metadata trace)" "leaked into hidden session env"
else
  pass "secrets: the value never appears in hidden show-environment either (no tmux metadata trace)"
fi
if grep -qF "$SWT_SECRET" "$SWT_VAULT_LOG"; then
  fail "secrets: the value never appears in workspace-start output" "leaked into start stdout/stderr"
else
  pass "secrets: the value never appears in workspace-start output"
fi
SWT_HISTORY_HITS=0
while IFS= read -r swt_pid; do
  [ -n "$swt_pid" ] || continue
  SWT_TMUX capture-pane -p -S - -t "$swt_pid" 2>/dev/null | grep -qF "$SWT_SECRET" && SWT_HISTORY_HITS=$((SWT_HISTORY_HITS + 1))
done < <(SWT_TMUX list-panes -t "$SWT_VAULT_SESSION" -F '#{pane_id}' 2>/dev/null)
if [ "$SWT_HISTORY_HITS" -eq 0 ]; then
  pass "secrets: the value never reaches pane scrollback (proves no send-keys delivery)"
else
  fail "secrets: the value never reaches pane scrollback (proves no send-keys delivery)" "found in $SWT_HISTORY_HITS pane(s)"
fi
# No state file (plan output, layout cache, etc.) under the state dir
# carries the secret either.
if grep -rqF "$SWT_SECRET" "$SWT_STATE" 2>/dev/null; then
  fail "secrets: the value never appears in any state file" "leaked into $SWT_STATE"
else
  pass "secrets: the value never appears in any state file"
fi

# Restore the plain inert stubs for the remaining lifecycle tests below.
for swt_prog in claude codex; do
  printf '#!/usr/bin/env bash\nexec sleep 3600\n' > "$SWT_BIN/$swt_prog"
  chmod +x "$SWT_BIN/$swt_prog"
done
rm -f "$SWT_ROOT"/dump-*.txt
swrun "$HERE/workspace-stop.sh" --config "$SWT_CFG3" --confirmed --all >/dev/null 2>&1

# --- 10c. defect 2: secrets.on_missing: "fail" must actually abort start ---
# workspace.local.env exists (0600, git-ignored -- passes config validation
# on its own), but does NOT contain SAMPLE_TOKEN. Before the fix, adapters.sh
# reported this to stderr but lifecycle.sh discarded the exit status, so
# workspace-start printed one warning and exited 0 regardless of on_missing.
( umask 077; printf 'UNRELATED_KEY=x\n' > "$SWT_PROJ3/workspace.local.env" )
chmod 600 "$SWT_PROJ3/workspace.local.env"
jq '.secrets.on_missing = "fail"' "$SWT_CFG3" > "$TMPROOT/vault-fail.json" && mv "$TMPROOT/vault-fail.json" "$SWT_CFG3"
SWT_FAIL_OUT="$(swrun "$HERE/workspace-start.sh" --config "$SWT_CFG3" --no-attach 2>&1)"
SWT_FAIL_STATUS=$?
if [ "$SWT_FAIL_STATUS" -ne 0 ] && printf '%s' "$SWT_FAIL_OUT" | grep -qi "secret"; then
  pass "defect 2: secrets.on_missing=fail with a missing key aborts workspace-start (non-zero, clear error)"
else
  fail "defect 2: secrets.on_missing=fail with a missing key aborts workspace-start (non-zero, clear error)" \
    "status=$SWT_FAIL_STATUS out=$SWT_FAIL_OUT"
fi

# --- 10c-2. a pane whose launch FAILED must never be reported healthy ------
# The markers are what make a pane "managed", and a managed live pane is
# reported healthy. When they were written BEFORE the launch, the failure above
# was permanent and invisible: this second run said "kept (already healthy)"
# with exit 0 while no agent existed anywhere, and no later start or reconcile
# would ever retry it. The launch is attempted first now, so a failed launch
# leaves the pane unmarked -- reported failed, and retried.
SWT_FAIL_OUT2="$(swrun "$HERE/workspace-start.sh" --config "$SWT_CFG3" --no-attach 2>&1)"
SWT_FAIL_STATUS2=$?
# Only the executor's launch fails here (it is the sole role in
# secrets.visible_to_roles), so the orchestrator pane legitimately stays
# healthy: the assertion is specifically that the FAILED pane is not the one
# being called healthy.
SWT_FAIL_MARKED="$(SWT_TMUX list-panes -t '=sample-vault-development:0' -F '#{@session_workspace_pane}' 2>/dev/null | grep -c '^sample-vault-executor$')"
if [ "$SWT_FAIL_STATUS2" -ne 0 ] &&
   ! printf '%s' "$SWT_FAIL_OUT2" | grep -q '\[kept\] sample-vault-development / sample-vault-executor' &&
   printf '%s' "$SWT_FAIL_OUT2" | grep -q '\[failed\] sample-vault-development / sample-vault-executor' &&
   printf '%s' "$SWT_FAIL_OUT2" | grep -q "failed: 1" &&
   [ "$SWT_FAIL_MARKED" = "0" ]; then
  pass "a pane whose launch failed is NOT reported healthy on the next start — it is retried"
else
  fail "a pane whose launch failed is NOT reported healthy on the next start — it is retried" \
    "status=$SWT_FAIL_STATUS2 marked_panes=$SWT_FAIL_MARKED out=$SWT_FAIL_OUT2"
fi
swrun "$HERE/workspace-stop.sh" --config "$SWT_CFG3" --confirmed --all >/dev/null 2>&1

jq '.secrets.on_missing = "warn"' "$SWT_CFG3" > "$TMPROOT/vault-warn.json" && mv "$TMPROOT/vault-warn.json" "$SWT_CFG3"
SWT_WARN_OUT="$(swrun "$HERE/workspace-start.sh" --config "$SWT_CFG3" --no-attach 2>&1)"
SWT_WARN_STATUS=$?
if [ "$SWT_WARN_STATUS" -eq 0 ]; then
  pass "defect 2: secrets.on_missing=warn with the same missing key still proceeds (exit 0)"
else
  fail "defect 2: secrets.on_missing=warn with the same missing key still proceeds (exit 0)" \
    "status=$SWT_WARN_STATUS out=$SWT_WARN_OUT"
fi
swrun "$HERE/workspace-stop.sh" --config "$SWT_CFG3" --confirmed --all >/dev/null 2>&1

# --- 10d. env.groups.*.pin_to_session is EXECUTED, not just declared -------
# The field used to be accepted by validation and displayed by workspace-plan
# while the engine never called `tmux set-environment` at all, so a pane the
# user created by hand inherited nothing. These tests fail outright without
# the mirroring code in lifecycle.sh's _sw_pin_session_env.
SWT_PIN_SECRET="PINNED-SECRET-9f3ab6c410"
SWT_PIN_VALUE="pinned-marker-7c2d5e"
SWT_PROJ4="$SWT_ROOT/sample-pinned"
mkdir -p "$SWT_PROJ4/.agent-workspace"
( cd "$SWT_PROJ4" && git init -q . )
cat > "$SWT_PROJ4/.agent-workspace/workspace.json" <<EOF
{"schema_version":1,"project":{"id":"sample-pinned","root":"."},
"runtimes":{"claude":{"program":"claude"},"codex":{"program":"codex"}},
"roles":{"orchestrator":{"runtime":"claude","grants":[],"env_group":"dev"},
         "executor":{"runtime":"codex","grants":[],"env_group":"dev"},
         "service":{"runtime":"shell","grants":[],"env_group":"none"}},
"stores":{"base":".tmp","pin":["messages","scheduler","contexts"]},
"env":{"groups":{
         "dev":{"values":{"AGENT_PLUGINS_TIME_ZONE":"Asia/Kolkata","SAMPLE_PIN_MARKER":"$SWT_PIN_VALUE"},"pin_to_session":true},
         "none":{"values":{"SAMPLE_UNPINNED_MARKER":"never-mirrored"},"pin_to_session":false}},
       "pane_name_aliases":["SAMPLE_PINNED_CODEX_PANE_NAME"]},
"secrets":{"env_file":"workspace.local.env","allow":["SAMPLE_PIN_TOKEN"],
           "visible_to_roles":["executor"],"on_missing":"warn"},
"sessions":[
 {"id":"development","name":"sample-pinned-development","panes":[
   {"name":"sample-pinned-master","role":"orchestrator","cwd":"."},
   {"name":"sample-pinned-executor","role":"executor","cwd":"."}]},
 {"id":"services","name":"sample-pinned-services","panes":[
   {"name":"sample-pinned-shell","role":"service","cwd":"."}]}]}
EOF
( umask 077; printf 'SAMPLE_PIN_TOKEN=%s\n' "$SWT_PIN_SECRET" > "$SWT_PROJ4/workspace.local.env" )
chmod 600 "$SWT_PROJ4/workspace.local.env"
printf 'workspace.local.env\n' > "$SWT_PROJ4/.gitignore"
SWT_CFG4="$SWT_PROJ4/.agent-workspace/workspace.json"
SWT_PIN_DEV='=sample-pinned-development'
SWT_PIN_SVC='=sample-pinned-services'
SWT_PIN_ROOT="$(cd "$SWT_PROJ4" && pwd -P)"

# Dump stubs again: they record the pinned vars AND the secret as the spawned
# PROCESS actually sees them, which is what "session env == pane env" and the
# secret positive control are checked against.
rm -f "$SWT_ROOT"/pindump-*.txt
cat > "$SWT_BIN/claude" <<EOF
#!/usr/bin/env bash
{ printf 'SAMPLE_PIN_MARKER=%s\n' "\${SAMPLE_PIN_MARKER:-<unset>}"
  printf 'AGENT_PLUGINS_TIME_ZONE=%s\n' "\${AGENT_PLUGINS_TIME_ZONE:-<unset>}"
  printf 'SESSION_SCHEDULER_HOME=%s\n' "\${SESSION_SCHEDULER_HOME:-<unset>}"
  printf 'SESSION_CHAT_TARGET_MESSAGES_DIR=%s\n' "\${SESSION_CHAT_TARGET_MESSAGES_DIR:-<unset>}"
  printf 'SESSION_CONTEXT_HOME=%s\n' "\${SESSION_CONTEXT_HOME:-<unset>}"
  printf 'SAMPLE_PIN_TOKEN=%s\n' "\${SAMPLE_PIN_TOKEN:-<unset>}"
} > "$SWT_ROOT/pindump-\${KNOWLEDGE_PANE_NAME:-unknown}.txt" 2>&1
exec sleep 3600
EOF
cp "$SWT_BIN/claude" "$SWT_BIN/codex"
chmod +x "$SWT_BIN/claude" "$SWT_BIN/codex"

swrun "$HERE/workspace-start.sh" --config "$SWT_CFG4" --no-attach >"$TMPROOT/pin-start.log" 2>&1
sleep 1

swt_sess_env() { SWT_TMUX show-environment -t "$1" 2>/dev/null; }
swt_sess_env_value() {
  SWT_TMUX show-environment -t "$1" 2>/dev/null | grep "^$2=" | head -1 | cut -d'=' -f2-
}
SWT_PIN_ENV="$(swt_sess_env "$SWT_PIN_DEV")"

# 1. the session environment carries the pinned group values AND the
#    stores.pin coordination vars, with the right values.
SWT_PIN_BAD=""
for swt_pair in \
  "SAMPLE_PIN_MARKER=$SWT_PIN_VALUE" \
  "AGENT_PLUGINS_TIME_ZONE=Asia/Kolkata" \
  "SESSION_CHAT_TARGET_MESSAGES_DIR=$SWT_PIN_ROOT/.tmp/messages" \
  "SESSION_SCHEDULER_HOME=$SWT_PIN_ROOT/.tmp/scheduler" \
  "SESSION_CONTEXT_HOME=$SWT_PIN_ROOT/.tmp/contexts"
do
  printf '%s\n' "$SWT_PIN_ENV" | grep -qxF "$swt_pair" || SWT_PIN_BAD="$SWT_PIN_BAD [$swt_pair]"
done
if [ -z "$SWT_PIN_BAD" ]; then
  pass "pin_to_session: the tmux session environment carries every pinned var with the expected value"
else
  fail "pin_to_session: the tmux session environment carries every pinned var with the expected value" \
    "missing:$SWT_PIN_BAD env=$(printf '%s' "$SWT_PIN_ENV" | tr '\n' ' ')"
fi

# 2. THE POINT OF THE FEATURE: a pane created afterwards BY HAND (never by
#    this engine, never marked) inherits the pinned env.
SWT_MANUAL_OUT="$SWT_ROOT/manual-pane-env.txt"
rm -f "$SWT_MANUAL_OUT"
SWT_MANUAL_PANE="$(SWT_TMUX split-window -d -t "$SWT_PIN_DEV:0" -P -F '#{pane_id}' \
  "sh -c 'env > \"$SWT_MANUAL_OUT\"; sleep 3600'" 2>/dev/null)"
sleep 1
if [ -f "$SWT_MANUAL_OUT" ] &&
   grep -qxF "SAMPLE_PIN_MARKER=$SWT_PIN_VALUE" "$SWT_MANUAL_OUT" &&
   grep -qxF "SESSION_SCHEDULER_HOME=$SWT_PIN_ROOT/.tmp/scheduler" "$SWT_MANUAL_OUT"; then
  pass "pin_to_session: a MANUALLY created pane (not spawned by the engine) inherits the pinned env"
else
  fail "pin_to_session: a MANUALLY created pane (not spawned by the engine) inherits the pinned env" \
    "pane=$SWT_MANUAL_PANE dump=$(grep -E '^(SAMPLE_PIN_MARKER|SESSION_SCHEDULER_HOME)=' "$SWT_MANUAL_OUT" 2>/dev/null | tr '\n' ' ')"
fi
# 2b. ...and that hand-made pane still never sees the secret.
if [ -f "$SWT_MANUAL_OUT" ] && grep -qF "$SWT_PIN_SECRET" "$SWT_MANUAL_OUT"; then
  fail "pin_to_session: a manually created pane never inherits a secret" "leaked into a hand-made pane"
else
  pass "pin_to_session: a manually created pane never inherits a secret"
fi
[ -n "$SWT_MANUAL_PANE" ] && SWT_TMUX kill-pane -t "$SWT_MANUAL_PANE" >/dev/null 2>&1

# 3. pin_to_session: false mirrors NOTHING (the services session's role uses
#    the "none" group).
SWT_PIN_SVC_ENV="$(swt_sess_env "$SWT_PIN_SVC")"
if printf '%s' "$SWT_PIN_SVC_ENV" | grep -qE '^(SAMPLE_UNPINNED_MARKER|SESSION_SCHEDULER_HOME|SESSION_CONTEXT_HOME|SESSION_CHAT_TARGET_MESSAGES_DIR|AGENT_PLUGINS_TIME_ZONE)='; then
  fail "pin_to_session: false mirrors nothing into that session's environment" \
    "env=$(printf '%s' "$SWT_PIN_SVC_ENV" | tr '\n' ' ')"
else
  pass "pin_to_session: false mirrors nothing into that session's environment"
fi

# 4. NO secret value anywhere in the session environment -- plain or hidden --
#    with a positive control proving the secret was genuinely configured and
#    delivered to its authorized pane in this very run.
SWT_PIN_DUMP_EXEC="$SWT_ROOT/pindump-sample-pinned-executor.txt"
if [ -f "$SWT_PIN_DUMP_EXEC" ] && grep -qxF "SAMPLE_PIN_TOKEN=$SWT_PIN_SECRET" "$SWT_PIN_DUMP_EXEC"; then
  pass "pin_to_session (positive control): the secret WAS delivered to its authorized pane's process"
else
  fail "pin_to_session (positive control): the secret WAS delivered to its authorized pane's process" \
    "$(cat "$SWT_PIN_DUMP_EXEC" 2>/dev/null || echo 'dump file missing')"
fi
if SWT_TMUX show-environment -t "$SWT_PIN_DEV" 2>/dev/null | grep -qF "$SWT_PIN_SECRET" ||
   SWT_TMUX show-environment -h -t "$SWT_PIN_DEV" 2>/dev/null | grep -qF "$SWT_PIN_SECRET"; then
  fail "pin_to_session: no secret value is ever mirrored into the session environment" "leaked"
else
  pass "pin_to_session: no secret value is ever mirrored into the session environment"
fi

# 5. per-pane identity is NEVER session-scoped. A session-wide
#    KNOWLEDGE_PANE_NAME would mis-identify every pane but one -- and it is an
#    authorization boundary for the memory store.
SWT_PIN_IDENT_BAD=""
for swt_ident in TMUX_PANE SESSION_CHAT_PANE_NAME KNOWLEDGE_PANE_NAME SAMPLE_PINNED_CODEX_PANE_NAME; do
  printf '%s\n' "$SWT_PIN_ENV" | grep -qE "^$swt_ident=" && SWT_PIN_IDENT_BAD="$SWT_PIN_IDENT_BAD $swt_ident"
done
if [ -z "$SWT_PIN_IDENT_BAD" ]; then
  pass "pin_to_session: per-pane identity vars (and pane_name_aliases) are never mirrored into the session env"
else
  fail "pin_to_session: per-pane identity vars (and pane_name_aliases) are never mirrored into the session env" \
    "found:$SWT_PIN_IDENT_BAD"
fi

# 6. session env values are BYTE-IDENTICAL to what the pane's own process
#    received -- the two delivery paths cannot silently diverge.
SWT_PIN_DIVERGED=""
for swt_name in SAMPLE_PIN_MARKER AGENT_PLUGINS_TIME_ZONE SESSION_SCHEDULER_HOME SESSION_CHAT_TARGET_MESSAGES_DIR SESSION_CONTEXT_HOME; do
  swt_sess_v="$(swt_sess_env_value "$SWT_PIN_DEV" "$swt_name")"
  swt_pane_v="$(grep "^$swt_name=" "$SWT_PIN_DUMP_EXEC" 2>/dev/null | head -1 | cut -d'=' -f2-)"
  [ "$swt_sess_v" = "$swt_pane_v" ] && [ -n "$swt_sess_v" ] || \
    SWT_PIN_DIVERGED="$SWT_PIN_DIVERGED [$swt_name session=$swt_sess_v pane=$swt_pane_v]"
done
if [ -z "$SWT_PIN_DIVERGED" ]; then
  pass "pin_to_session: every session env value equals the pane process env value for the same name"
else
  fail "pin_to_session: every session env value equals the pane process env value for the same name" \
    "$SWT_PIN_DIVERGED"
fi

# 7. workspace-plan's displayed pinned set is EXACTLY what the engine mirrored
#    -- the display/behaviour disagreement this gap was.
SWT_PIN_PLANNED="$(swrun "$HERE/workspace-plan.sh" development --config "$SWT_CFG4" --json 2>/dev/null \
  | jq -r '.sessions[0].pinned_session_env[]' | sort | tr '\n' ' ')"
SWT_PIN_ACTUAL="$(printf '%s\n' "$SWT_PIN_ENV" | grep -E '^(SAMPLE_PIN_MARKER|AGENT_PLUGINS_TIME_ZONE|SESSION_SCHEDULER_HOME|SESSION_CONTEXT_HOME|SESSION_CHAT_TARGET_MESSAGES_DIR)=' \
  | cut -d'=' -f1 | sort | tr '\n' ' ')"
if [ -n "$SWT_PIN_PLANNED" ] && [ "$SWT_PIN_PLANNED" = "$SWT_PIN_ACTUAL" ]; then
  pass "pin_to_session: workspace-plan's pinned_session_env matches what the engine actually mirrored"
else
  fail "pin_to_session: workspace-plan's pinned_session_env matches what the engine actually mirrored" \
    "planned=[$SWT_PIN_PLANNED] actual=[$SWT_PIN_ACTUAL]"
fi
if swrun "$HERE/workspace-plan.sh" development --config "$SWT_CFG4" 2>/dev/null \
   | grep -q "session env pinned (names only): AGENT_PLUGINS_TIME_ZONE, SAMPLE_PIN_MARKER, SESSION_CHAT_TARGET_MESSAGES_DIR, SESSION_CONTEXT_HOME, SESSION_SCHEDULER_HOME"; then
  pass "pin_to_session: the human-readable plan reports the pinned session env names"
else
  fail "pin_to_session: the human-readable plan reports the pinned session env names" \
    "$(swrun "$HERE/workspace-plan.sh" development --config "$SWT_CFG4" 2>&1 | grep -i 'session env' || echo '(no line)')"
fi

# 8. idempotent: a second start leaves the session env correct, with each
#    pinned name appearing exactly once.
swrun "$HERE/workspace-start.sh" --config "$SWT_CFG4" --no-attach >/dev/null 2>&1
SWT_PIN_ENV2="$(swt_sess_env "$SWT_PIN_DEV")"
SWT_PIN_DUPES="$(printf '%s\n' "$SWT_PIN_ENV2" | grep -cE '^SAMPLE_PIN_MARKER=' | tr -d ' ')"
if [ "$SWT_PIN_DUPES" = "1" ] &&
   printf '%s\n' "$SWT_PIN_ENV2" | grep -qxF "SAMPLE_PIN_MARKER=$SWT_PIN_VALUE" &&
   printf '%s\n' "$SWT_PIN_ENV2" | grep -qxF "SESSION_CONTEXT_HOME=$SWT_PIN_ROOT/.tmp/contexts"; then
  pass "pin_to_session: a second start leaves the session env correct and un-duplicated"
else
  fail "pin_to_session: a second start leaves the session env correct and un-duplicated" \
    "occurrences=$SWT_PIN_DUPES env=$(printf '%s' "$SWT_PIN_ENV2" | tr '\n' ' ')"
fi

# Restore the plain inert stubs and clean up this sub-test's sessions.
for swt_prog in claude codex; do
  printf '#!/usr/bin/env bash\nexec sleep 3600\n' > "$SWT_BIN/$swt_prog"
  chmod +x "$SWT_BIN/$swt_prog"
done
rm -f "$SWT_ROOT"/pindump-*.txt
swrun "$HERE/workspace-stop.sh" --config "$SWT_CFG4" --confirmed --all >/dev/null 2>&1

# --- 10e. --no-agents must not be a one-way door ---------------------------
# A pane claimed while agent launches were suppressed carries the managed
# markers but NOT @session_workspace_launched. That is a repairable state, so a
# later plain start finishes the job. Before the fix the pane was "managed and
# alive" and therefore reported "kept (already healthy)" forever -- the agent
# could never be launched into it at all.
SWT_PROJ_NA="$SWT_ROOT/sample-noagents"
mkdir -p "$SWT_PROJ_NA/.agent-workspace"
cat > "$SWT_PROJ_NA/.agent-workspace/workspace.json" <<'EOF'
{"schema_version":1,"project":{"id":"sample-noagents","root":"."},
"runtimes":{"claude":{"program":"claude"}},
"roles":{"orchestrator":{"runtime":"claude","grants":[],"env_group":"dev"}},
"stores":{"pin":[]},
"env":{"groups":{"dev":{"values":{}}}},
"sessions":[{"id":"development","name":"sample-noagents-development","panes":[
  {"name":"sample-noagents-master","role":"orchestrator","cwd":"."}
]}]}
EOF
SWT_CFG_NA="$SWT_PROJ_NA/.agent-workspace/workspace.json"
SWT_NA_WIN='=sample-noagents-development:0'

# swt_wait_cmd PANE EXPECTED — wait (bounded) for a pane's foreground command,
# since a launched pane execs through bash before reaching its runtime.
swt_wait_cmd() {
  local pane="$1" want="$2" i=0
  while [ "$i" -lt 40 ]; do
    [ "$(swt_pane_field "$pane" '#{pane_current_command}')" = "$want" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

SWT_OUT="$(swrun "$HERE/workspace-start.sh" --config "$SWT_CFG_NA" --no-attach --no-agents 2>&1)"
SWT_STATUS=$?
SWT_NA_PANE="$(SWT_TMUX list-panes -t "$SWT_NA_WIN" -F "#{pane_id}	#{@session_workspace_pane}" 2>/dev/null | awk -F'\t' '$2 == "sample-noagents-master" {print $1}')"
if [ "$SWT_STATUS" -eq 0 ] &&
   printf '%s' "$SWT_OUT" | grep -q '\[claimed\] sample-noagents-development / sample-noagents-master' &&
   [ -n "$SWT_NA_PANE" ] &&
   [ -z "$(swt_pane_field "$SWT_NA_PANE" '#{@session_workspace_launched}')" ]; then
  pass "start --no-agents: the pane is claimed but explicitly NOT marked launched"
else
  fail "start --no-agents: the pane is claimed but explicitly NOT marked launched" \
    "status=$SWT_STATUS pane=$SWT_NA_PANE launched=$(swt_pane_field "$SWT_NA_PANE" '#{@session_workspace_launched}') output=$SWT_OUT"
fi

SWT_OUT="$(swrun "$HERE/workspace-start.sh" --config "$SWT_CFG_NA" --no-attach --no-agents 2>&1)"
if printf '%s' "$SWT_OUT" | grep -q '\[skipped\] sample-noagents-development / sample-noagents-master' &&
   ! printf '%s' "$SWT_OUT" | grep -q '\[kept\]'; then
  pass "start --no-agents (again): the un-launched pane is reported skipped, never healthy"
else
  fail "start --no-agents (again): the un-launched pane is reported skipped, never healthy" "$SWT_OUT"
fi

SWT_OUT="$(swrun "$HERE/workspace-start.sh" --config "$SWT_CFG_NA" --no-attach 2>&1)"
SWT_STATUS=$?
SWT_NA_PANE2="$(SWT_TMUX list-panes -t "$SWT_NA_WIN" -F "#{pane_id}	#{@session_workspace_pane}" 2>/dev/null | awk -F'\t' '$2 == "sample-noagents-master" {print $1}')"
if [ "$SWT_STATUS" -eq 0 ] &&
   printf '%s' "$SWT_OUT" | grep -q 'relaunched — managed pane had no runtime running' &&
   [ "$(swt_pane_field "$SWT_NA_PANE2" '#{@session_workspace_launched}')" = "claude" ] &&
   swt_wait_cmd "$SWT_NA_PANE2" "sleep"; then
  pass "--no-agents then a later plain start DOES launch the agent (not a one-way door)"
else
  fail "--no-agents then a later plain start DOES launch the agent (not a one-way door)" \
    "status=$SWT_STATUS launched=$(swt_pane_field "$SWT_NA_PANE2" '#{@session_workspace_launched}') cmd=$(swt_pane_field "$SWT_NA_PANE2" '#{pane_current_command}') output=$SWT_OUT"
fi

SWT_OUT="$(swrun "$HERE/workspace-start.sh" --config "$SWT_CFG_NA" --no-attach 2>&1)"
SWT_STATUS=$?
if [ "$SWT_STATUS" -eq 0 ] && printf '%s' "$SWT_OUT" | grep -q "started/adopted: 0  kept (already healthy): 1  failed: 0"; then
  pass "start after the repair is idempotent again (the launched pane is kept)"
else
  fail "start after the repair is idempotent again (the launched pane is kept)" "status=$SWT_STATUS output=$SWT_OUT"
fi

# --- 10f. behavior.attach / --no-attach ------------------------------------
# behavior.attach used to be dead config: start's attach path was a literal
# ":" no-op and --no-attach suppressed nothing. Every branch reports its
# decision on stdout, so the policy is assertable without a terminal;
# SESSION_WORKSPACE_ATTACH_DRY_RUN resolves the attach without performing it.
SWT_OUT="$(swrun "$HERE/workspace-start.sh" --config "$SWT_CFG_NA" 2>&1)"
if printf '%s' "$SWT_OUT" | grep -q 'attach: skipped (not a terminal)'; then
  pass "attach: a non-terminal run attaches nothing, and says so"
else
  fail "attach: a non-terminal run attaches nothing, and says so" "$SWT_OUT"
fi

SWT_OUT="$(env -u TMUX TMUX_TMPDIR="$SWT_TMPDIR" PATH="$SWT_BIN:$PATH" XDG_STATE_HOME="$SWT_STATE" \
  SESSION_WORKSPACE_ATTACH_DRY_RUN=1 bash "$HERE/workspace-start.sh" --config "$SWT_CFG_NA" 2>&1)"
if printf '%s' "$SWT_OUT" | grep -q 'attach: would attach to "sample-noagents-development"'; then
  pass "attach: behavior.attach defaults to attaching, and resolves the started session"
else
  fail "attach: behavior.attach defaults to attaching, and resolves the started session" "$SWT_OUT"
fi

SWT_OUT="$(env -u TMUX TMUX_TMPDIR="$SWT_TMPDIR" PATH="$SWT_BIN:$PATH" XDG_STATE_HOME="$SWT_STATE" \
  SESSION_WORKSPACE_ATTACH_DRY_RUN=1 bash "$HERE/workspace-start.sh" --config "$SWT_CFG_NA" --no-attach 2>&1)"
if printf '%s' "$SWT_OUT" | grep -q 'attach: suppressed by --no-attach' &&
   ! printf '%s' "$SWT_OUT" | grep -q 'would attach'; then
  pass "attach: --no-attach really suppresses it"
else
  fail "attach: --no-attach really suppresses it" "$SWT_OUT"
fi

jq '.behavior = {"attach": "never"}' "$SWT_CFG_NA" > "$TMPROOT/na-never.json" && mv "$TMPROOT/na-never.json" "$SWT_CFG_NA"
SWT_OUT="$(env -u TMUX TMUX_TMPDIR="$SWT_TMPDIR" PATH="$SWT_BIN:$PATH" XDG_STATE_HOME="$SWT_STATE" \
  SESSION_WORKSPACE_ATTACH_DRY_RUN=1 bash "$HERE/workspace-start.sh" --config "$SWT_CFG_NA" 2>&1)"
if printf '%s' "$SWT_OUT" | grep -q 'attach: disabled by behavior.attach=never' &&
   ! printf '%s' "$SWT_OUT" | grep -q 'would attach'; then
  pass "attach: behavior.attach=never suppresses it from the config alone"
else
  fail "attach: behavior.attach=never suppresses it from the config alone" "$SWT_OUT"
fi

# behavior.default_start_target is the TARGET of a bare `start`, so it must be
# a real session id (or "all") -- validation rejects anything else rather than
# letting it surface as "unknown session target" at launch time.
jq '.behavior = {"default_start_target": "development"}' "$SWT_CFG_NA" > "$TMPROOT/na-dst.json" && mv "$TMPROOT/na-dst.json" "$SWT_CFG_NA"
SWT_OUT="$(swrun "$HERE/workspace-start.sh" --config "$SWT_CFG_NA" --no-attach 2>&1)"
SWT_STATUS=$?
if [ "$SWT_STATUS" -eq 0 ] && printf '%s' "$SWT_OUT" | grep -q "kept (already healthy): 1"; then
  pass "behavior.default_start_target: a bare start targets the configured session"
else
  fail "behavior.default_start_target: a bare start targets the configured session" "status=$SWT_STATUS output=$SWT_OUT"
fi
jq '.behavior = {"default_start_target": "no-such-session"}' "$SWT_CFG_NA" > "$TMPROOT/na-bad.json" && mv "$TMPROOT/na-bad.json" "$SWT_CFG_NA"
SWT_OUT="$(swrun "$HERE/validate-config.sh" --config "$SWT_CFG_NA" 2>&1)"
SWT_STATUS=$?
if [ "$SWT_STATUS" -ne 0 ] && printf '%s' "$SWT_OUT" | grep -q 'behavior.default_start_target must be "all" or one of sessions\[\].id'; then
  pass "behavior.default_start_target: a value naming no session fails validation"
else
  fail "behavior.default_start_target: a value naming no session fails validation" "status=$SWT_STATUS output=$SWT_OUT"
fi
swrun "$HERE/workspace-stop.sh" --config "$SWT_CFG_NA" --confirmed --all >/dev/null 2>&1

# --- 10g. behavior.session_chat_helper.on_missing: "fail" gates start ------
# doctor has always reported "on_missing=fail, so start WILL fail" for an
# unresolvable helper; nothing in start read the field, so that verdict was
# false. HOME and the source-tree override both point at empty dirs here, so
# the helper is unresolvable no matter what the developer has installed.
SWT_PROJ_SCH="$SWT_ROOT/sample-helper"
mkdir -p "$SWT_PROJ_SCH/.agent-workspace" "$SWT_ROOT/empty-home" "$SWT_ROOT/empty-src"
cat > "$SWT_PROJ_SCH/.agent-workspace/workspace.json" <<'EOF'
{"schema_version":1,"project":{"id":"sample-helper","root":"."},
"runtimes":{"claude":{"program":"claude"}},
"roles":{"orchestrator":{"runtime":"claude","grants":[],"env_group":"dev"}},
"stores":{"pin":[]},
"env":{"groups":{"dev":{"values":{}}}},
"behavior":{"session_chat_helper":{"resolve":"always","on_missing":"fail"}},
"sessions":[{"id":"development","name":"sample-helper-development","panes":[
  {"name":"sample-helper-master","role":"orchestrator","cwd":"."}
]}]}
EOF
SWT_CFG_SCH="$SWT_PROJ_SCH/.agent-workspace/workspace.json"
swrun_no_helper() {
  env -u TMUX TMUX_TMPDIR="$SWT_TMPDIR" PATH="$SWT_BIN:$PATH" XDG_STATE_HOME="$SWT_STATE" \
    HOME="$SWT_ROOT/empty-home" SESSION_WORKSPACE_SOURCE_TREE_DIR="$SWT_ROOT/empty-src" \
    bash "$@"
}
SWT_OUT="$(swrun_no_helper "$HERE/workspace-start.sh" --config "$SWT_CFG_SCH" --no-attach 2>&1)"
SWT_STATUS=$?
if [ "$SWT_STATUS" -ne 0 ] &&
   printf '%s' "$SWT_OUT" | grep -q 'session-chat helper does not resolve' &&
   ! SWT_TMUX has-session -t '=sample-helper-development' 2>/dev/null; then
  pass "session_chat_helper.on_missing=fail with an unresolvable helper aborts start before any tmux change"
else
  fail "session_chat_helper.on_missing=fail with an unresolvable helper aborts start before any tmux change" \
    "status=$SWT_STATUS output=$SWT_OUT"
fi
jq '.behavior.session_chat_helper.on_missing = "warn"' "$SWT_CFG_SCH" > "$TMPROOT/sch-warn.json" && mv "$TMPROOT/sch-warn.json" "$SWT_CFG_SCH"
SWT_OUT="$(swrun_no_helper "$HERE/workspace-start.sh" --config "$SWT_CFG_SCH" --no-attach 2>&1)"
SWT_STATUS=$?
if [ "$SWT_STATUS" -eq 0 ] && printf '%s' "$SWT_OUT" | grep -q "WARNING: the session-chat helper does not resolve"; then
  pass "session_chat_helper.on_missing=warn with the same helper starts anyway, with a warning"
else
  fail "session_chat_helper.on_missing=warn with the same helper starts anyway, with a warning" \
    "status=$SWT_STATUS output=$SWT_OUT"
fi
swrun_no_helper "$HERE/workspace-stop.sh" --config "$SWT_CFG_SCH" --confirmed --all >/dev/null 2>&1

# --- 10h. SESSION-level adoption -------------------------------------------
# Every tmux session predating this plugin is unmarked, so the first start in a
# migrated project hit "exists and is not managed" -- and the remedy the error
# named could not work, because --adopt was consulted only in the per-pane
# loop. Session adoption is gated exactly like the pane-level kind.
SWT_PROJ_AD="$SWT_ROOT/sample-adopt"
mkdir -p "$SWT_PROJ_AD/.agent-workspace"
cat > "$SWT_PROJ_AD/.agent-workspace/workspace.json" <<'EOF'
{"schema_version":1,"project":{"id":"sample-adopt","root":"."},
"runtimes":{"claude":{"program":"claude"}},
"roles":{"orchestrator":{"runtime":"claude","grants":[],"env_group":"dev"}},
"stores":{"pin":[]},
"env":{"groups":{"dev":{"values":{}}}},
"sessions":[{"id":"development","name":"sample-adopt-development","panes":[
  {"name":"sample-adopt-master","role":"orchestrator","cwd":"."},
  {"name":"sample-adopt-worker","role":"orchestrator","cwd":"."}
]}]}
EOF
SWT_CFG_AD="$SWT_PROJ_AD/.agent-workspace/workspace.json"
SWT_AD_WIN='=sample-adopt-development:0'
# A pre-existing, completely unmarked session of exactly the configured name.
SWT_TMUX new-session -d -s "sample-adopt-development" 'sleep 3600' >/dev/null 2>&1
SWT_TMUX split-window -t "$SWT_AD_WIN" -h -l 50% 'sleep 3600' >/dev/null 2>&1

SWT_OUT="$(swrun "$HERE/workspace-start.sh" --config "$SWT_CFG_AD" --no-attach 2>&1)"
SWT_STATUS=$?
# The remedy must be a command that actually adopts a SESSION. The old message
# named "workspace-reconcile --adopt --confirmed", which failed identically.
if [ "$SWT_STATUS" -ne 0 ] &&
   printf '%s' "$SWT_OUT" | grep -q 'is not managed by session-workspace' &&
   printf '%s' "$SWT_OUT" | grep -q -- 'workspace-reconcile development --apply --adopt --confirmed' &&
   [ -z "$(SWT_TMUX show-options -t '=sample-adopt-development:' -v @session_workspace_project 2>/dev/null)" ]; then
  pass "start: an unmanaged same-named session is refused, naming the remedy that actually works"
else
  fail "start: an unmanaged same-named session is refused, naming the remedy that actually works" \
    "status=$SWT_STATUS output=$SWT_OUT"
fi

SWT_OUT="$(swrun "$HERE/workspace-reconcile.sh" development --config "$SWT_CFG_AD" --adopt --confirmed 2>&1)"
SWT_STATUS=$?
SWT_AD_PLAN_LINE="$(printf '%s\n' "$SWT_OUT" | grep -n -- "-- session adoption candidate --" | head -n1 | cut -d: -f1)"
SWT_AD_WOULD_LINE="$(printf '%s\n' "$SWT_OUT" | grep -n -- "\[would-adopt-session\]" | head -n1 | cut -d: -f1)"
if [ "$SWT_STATUS" -eq 0 ] && [ -n "$SWT_AD_PLAN_LINE" ] && [ -n "$SWT_AD_WOULD_LINE" ] &&
   [ "$SWT_AD_PLAN_LINE" -lt "$SWT_AD_WOULD_LINE" ] &&
   printf '%s' "$SWT_OUT" | grep -q "existing panes: 2" &&
   printf '%s' "$SWT_OUT" | grep -q "dry run — nothing was changed"; then
  pass "reconcile --adopt --confirmed (no --apply): previews the SESSION adoption plan first"
else
  fail "reconcile --adopt --confirmed (no --apply): previews the SESSION adoption plan first" \
    "status=$SWT_STATUS output=$SWT_OUT"
fi
if [ -z "$(SWT_TMUX show-options -t '=sample-adopt-development:' -v @session_workspace_project 2>/dev/null)" ] &&
   [ -z "$(SWT_TMUX list-panes -t "$SWT_AD_WIN" -F '#{@session_workspace_pane}' 2>/dev/null | tr -d '\n')" ]; then
  pass "reconcile --adopt --confirmed (no --apply): the dry run adopted nothing at all"
else
  fail "reconcile --adopt --confirmed (no --apply): the dry run adopted nothing at all" \
    "session_marker=$(SWT_TMUX show-options -t '=sample-adopt-development:' -v @session_workspace_project 2>/dev/null) pane_markers=$(SWT_TMUX list-panes -t "$SWT_AD_WIN" -F '#{@session_workspace_pane}' 2>/dev/null | tr '\n' ' ')"
fi

SWT_OUT="$(swrun "$HERE/workspace-reconcile.sh" development --config "$SWT_CFG_AD" --apply --adopt --confirmed 2>&1)"
SWT_STATUS=$?
SWT_AD_PLAN_LINE="$(printf '%s\n' "$SWT_OUT" | grep -n -- "-- session adoption candidate --" | head -n1 | cut -d: -f1)"
SWT_AD_DONE_LINE="$(printf '%s\n' "$SWT_OUT" | grep -n -- "\[adopted-session\]" | head -n1 | cut -d: -f1)"
SWT_AD_NAMES="$(swt_names_in_window "$SWT_AD_WIN")"
if [ "$SWT_STATUS" -eq 0 ] && [ -n "$SWT_AD_PLAN_LINE" ] && [ -n "$SWT_AD_DONE_LINE" ] &&
   [ "$SWT_AD_PLAN_LINE" -lt "$SWT_AD_DONE_LINE" ] &&
   [ "$(SWT_TMUX show-options -t '=sample-adopt-development:' -v @session_workspace_project 2>/dev/null)" = "sample-adopt" ] &&
   [ "$SWT_AD_NAMES" = "sample-adopt-master sample-adopt-worker " ]; then
  pass "reconcile --apply --adopt --confirmed: adopts the session after its plan, then fills its panes"
else
  fail "reconcile --apply --adopt --confirmed: adopts the session after its plan, then fills its panes" \
    "status=$SWT_STATUS marker=$(SWT_TMUX show-options -t '=sample-adopt-development:' -v @session_workspace_project 2>/dev/null) names=[$SWT_AD_NAMES] output=$SWT_OUT"
fi

SWT_OUT="$(swrun "$HERE/workspace-start.sh" --config "$SWT_CFG_AD" --no-attach 2>&1)"
SWT_STATUS=$?
if [ "$SWT_STATUS" -eq 0 ] && printf '%s' "$SWT_OUT" | grep -q "started/adopted: 0  kept (already healthy): 2  failed: 0"; then
  pass "start after session adoption: the once-foreign session is now managed and idempotent"
else
  fail "start after session adoption: the once-foreign session is now managed and idempotent" "status=$SWT_STATUS output=$SWT_OUT"
fi
swrun "$HERE/workspace-stop.sh" --config "$SWT_CFG_AD" --confirmed --all >/dev/null 2>&1

# --- 10i. harness identity reaches the pane PROCESS env, never the session env
# The six SESSION_WORKSPACE_* variables are engine-always per-pane identity:
# the policy hook keys every decision on them, so they must land in the
# launched process's own environment (proved with an env-dumping stub, like
# the secrets test above) and must never be mirrored session-wide (a
# session-scoped identity would let a hand-made pane impersonate a role).
SWT_PROJ_H="$SWT_ROOT/sample-harness"
mkdir -p "$SWT_PROJ_H/.agent-workspace" "$SWT_PROJ_H/component-a"
jq '.project.id = "sample-harness"' "$HERE/fixtures/valid/harness-v2.json" > "$SWT_PROJ_H/.agent-workspace/workspace.json"
SWT_CFG_H="$SWT_PROJ_H/.agent-workspace/workspace.json"
SWT_PROJ_H_ABS="$(cd "$SWT_PROJ_H" && pwd -P)"
rm -f "$SWT_ROOT"/hdump-*.txt
cat > "$SWT_BIN/codex" <<EOF
#!/usr/bin/env bash
{ for v in SESSION_WORKSPACE_CONFIG SESSION_WORKSPACE_PROJECT_ROOT SESSION_WORKSPACE_PANE_NAME SESSION_WORKSPACE_ROLE SESSION_WORKSPACE_PANE_CWD SESSION_WORKSPACE_HARNESS_MODE; do
    printf '%s=%s\n' "\$v" "\${!v:-<unset>}"
  done; } > "$SWT_ROOT/hdump-\${KNOWLEDGE_PANE_NAME:-unknown}.txt" 2>&1
exec sleep 3600
EOF
chmod +x "$SWT_BIN/codex"
SWT_H_OUT="$(swrun "$HERE/workspace-start.sh" --config "$SWT_CFG_H" --no-attach 2>&1)"
SWT_H_STATUS=$?
sleep 1
SWT_HDUMP_EXEC="$SWT_ROOT/hdump-sample-harness-component-executor.txt"
SWT_HDUMP_MASTER="$SWT_ROOT/hdump-sample-harness-master.txt"
if [ "$SWT_H_STATUS" -eq 0 ] && [ -f "$SWT_HDUMP_EXEC" ] &&
   grep -qxF "SESSION_WORKSPACE_CONFIG=$SWT_PROJ_H_ABS/.agent-workspace/workspace.json" "$SWT_HDUMP_EXEC" &&
   grep -qxF "SESSION_WORKSPACE_PROJECT_ROOT=$SWT_PROJ_H_ABS" "$SWT_HDUMP_EXEC" &&
   grep -qxF "SESSION_WORKSPACE_PANE_NAME=sample-harness-component-executor" "$SWT_HDUMP_EXEC" &&
   grep -qxF "SESSION_WORKSPACE_ROLE=executor" "$SWT_HDUMP_EXEC" &&
   grep -qxF "SESSION_WORKSPACE_PANE_CWD=$SWT_PROJ_H_ABS/component-a" "$SWT_HDUMP_EXEC" &&
   grep -qxF "SESSION_WORKSPACE_HARNESS_MODE=enforce" "$SWT_HDUMP_EXEC"; then
  pass "harness identity: the executor pane's spawned PROCESS receives all six engine-owned variables with the planned values"
else
  fail "harness identity: the executor pane's spawned PROCESS receives all six engine-owned variables with the planned values" \
    "status=$SWT_H_STATUS dump=$(cat "$SWT_HDUMP_EXEC" 2>/dev/null || echo missing) out=$SWT_H_OUT"
fi
if [ -f "$SWT_HDUMP_MASTER" ] && grep -qxF "SESSION_WORKSPACE_ROLE=master" "$SWT_HDUMP_MASTER" &&
   grep -qxF "SESSION_WORKSPACE_PANE_CWD=$SWT_PROJ_H_ABS" "$SWT_HDUMP_MASTER" &&
   grep -qxF "SESSION_WORKSPACE_HARNESS_MODE=enforce" "$SWT_HDUMP_MASTER"; then
  pass "harness identity: the orchestrator pane receives its own distinct role/cwd identity"
else
  fail "harness identity: the orchestrator pane receives its own distinct role/cwd identity" "$(cat "$SWT_HDUMP_MASTER" 2>/dev/null || echo missing)"
fi
SWT_H_SESS_ENV="$(SWT_TMUX show-environment -t '=sample-harness-development' 2>/dev/null; SWT_TMUX show-environment -h -t '=sample-harness-development' 2>/dev/null)"
if printf '%s' "$SWT_H_SESS_ENV" | grep -q 'SESSION_WORKSPACE_'; then
  fail "harness identity: no SESSION_WORKSPACE_* variable is ever mirrored into the tmux session env" "$SWT_H_SESS_ENV"
else
  pass "harness identity: no SESSION_WORKSPACE_* variable is ever mirrored into the tmux session env"
fi
# A live-status probe from INSIDE the launched pane's identity must MATCH.
SWT_H_STATUS_JSON="$(env -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME SESSION_WORKSPACE_CONFIG="$SWT_PROJ_H_ABS/.agent-workspace/workspace.json" SESSION_WORKSPACE_PROJECT_ROOT="$SWT_PROJ_H_ABS" \
  SESSION_WORKSPACE_PANE_NAME=sample-harness-component-executor SESSION_WORKSPACE_ROLE=executor \
  SESSION_WORKSPACE_PANE_CWD="$SWT_PROJ_H_ABS/component-a" SESSION_WORKSPACE_HARNESS_MODE=enforce \
  bash "$HERE/harness-status.sh" --config "$SWT_CFG_H" --json 2>&1)"
if printf '%s' "$SWT_H_STATUS_JSON" | jq -e '.identity.matches == true' >/dev/null 2>&1; then
  pass "harness identity: the exact launched identity reports MATCH in harness-status"
else
  fail "harness identity: the exact launched identity reports MATCH in harness-status" "$SWT_H_STATUS_JSON"
fi
printf '#!/usr/bin/env bash\nexec sleep 3600\n' > "$SWT_BIN/codex"
chmod +x "$SWT_BIN/codex"
rm -f "$SWT_ROOT"/hdump-*.txt
swrun "$HERE/workspace-stop.sh" --config "$SWT_CFG_H" --confirmed --all >/dev/null 2>&1

# --- 11. stop -------------------------------------------------------------
SWT_OUT="$(swrun "$HERE/workspace-stop.sh" development --config "$SWT_CFG" 2>&1)"
SWT_STATUS=$?
if [ "$SWT_STATUS" -ne 0 ] && printf '%s' "$SWT_OUT" | grep -q -- "refuses to run without --confirmed"; then
  pass "stop: refuses to run without --confirmed"
else
  fail "stop: refuses to run without --confirmed" "status=$SWT_STATUS output=$SWT_OUT"
fi
if SWT_TMUX has-session -t '=sample-project-development' 2>/dev/null; then
  pass "stop: the refused run killed nothing"
else
  fail "stop: the refused run killed nothing" "session is gone"
fi

SWT_OUT="$(swrun "$HERE/workspace-stop.sh" development --config "$SWT_CFG" --confirmed 2>&1)"
if printf '%s' "$SWT_OUT" | grep -q "killed: 1"; then
  pass "stop --confirmed: kills the selected managed session only"
else
  fail "stop --confirmed: kills the selected managed session only" "$SWT_OUT"
fi
if ! SWT_TMUX has-session -t '=sample-project-development' 2>/dev/null &&
   SWT_TMUX has-session -t '=sample-project-services' 2>/dev/null &&
   SWT_TMUX has-session -t '=unrelated-bystander' 2>/dev/null; then
  pass "stop --confirmed: the other managed session and the foreign session both survive"
else
  fail "stop --confirmed: the other managed session and the foreign session both survive" \
    "sessions=$(SWT_TMUX list-sessions -F '#{session_name}' 2>&1 | tr '\n' ' ')"
fi

# The critical one: a session with the SAME configured name that this engine
# does not own must never be killed.
SWT_TMUX new-session -d -s "sample-project-development" 'sleep 3600' >/dev/null 2>&1
SWT_OUT="$(swrun "$HERE/workspace-stop.sh" development --config "$SWT_CFG" --confirmed 2>&1)"
if printf '%s' "$SWT_OUT" | grep -q "exists but is NOT managed by this project; left untouched" &&
   printf '%s' "$SWT_OUT" | grep -q "killed: 0" &&
   SWT_TMUX has-session -t '=sample-project-development' 2>/dev/null; then
  pass "stop --confirmed: a same-named UNMANAGED session is skipped, never killed"
else
  fail "stop --confirmed: a same-named UNMANAGED session is skipped, never killed" "$SWT_OUT"
fi

# --- 12. restart ----------------------------------------------------------
SWT_OUT="$(swrun "$HERE/workspace-restart.sh" services --config "$SWT_CFG" --no-attach --no-save 2>&1)"
SWT_STATUS=$?
SWT_SVC_NAMES="$(swt_names_in_window "$SWT_SVC")"
if [ "$SWT_STATUS" -eq 0 ] && [ "$SWT_SVC_NAMES" = "$SWT_EXPECT_SVC" ]; then
  pass "restart: accepts --no-save and rebuilds the session to the planned topology"
else
  fail "restart: accepts --no-save and rebuilds the session to the planned topology" "status=$SWT_STATUS names=[$SWT_SVC_NAMES] output=$SWT_OUT"
fi

# --- 12z. browser.pane_name in a shared services session -------------------
# Chrome lives in ONE selected pane of a multi-pane session. Lifecycle must:
#   * under --no-services create the pane but neither launch Chrome, claim
#     the DevTools port, nor wait for readiness;
#   * on a plain start launch Chrome into the selected pane only, claim the
#     port, and wait for /json/version -- a stub "Chrome" answers that
#     endpoint over real HTTP so readiness is observed, not simulated;
#   * report readiness for the selected pane alone (siblings stay "n/a");
#   * release the port claim when the shared session is stopped.
SWT_PROJ_BR="$SWT_ROOT/sample-browser"
SWT_BR_PORT=47331
SWT_BR_CACHE="$SWT_ROOT/browser-cache"
mkdir -p "$SWT_PROJ_BR/.agent-workspace" "$SWT_BR_CACHE"
cat > "$SWT_BIN/chrome-stub" <<'EOF'
#!/usr/bin/env bash
# Stand-in for Chrome: serves a DevTools-shaped /json/version on the
# --remote-debugging-port it is handed and stays in the foreground.
port=""
for a in "$@"; do
  case "$a" in --remote-debugging-port=*) port="${a#--remote-debugging-port=}" ;; esac
done
[ -n "$port" ] || { echo "chrome-stub: no --remote-debugging-port" >&2; exit 1; }
root="$(dirname "$0")/chrome-stub-root"
mkdir -p "$root/json"
printf '{"Browser":"chrome-stub/1.0","webSocketDebuggerUrl":"ws://127.0.0.1:%s/devtools/browser/stub"}\n' "$port" > "$root/json/version"
cd "$root" || exit 1
exec python3 -m http.server "$port" --bind 127.0.0.1
EOF
chmod +x "$SWT_BIN/chrome-stub"
cat > "$SWT_PROJ_BR/.agent-workspace/workspace.json" <<EOF
{"schema_version":1,"project":{"id":"sample-browser","root":"."},
"runtimes":{},
"roles":{"service":{"runtime":"shell","env_group":"none"}},
"stores":{"pin":[]},
"behavior":{"default_start_target":"all","attach":"never","stop_scope":"selected","session_chat_helper":{"resolve":"never"}},
"browser":{"session_id":"services","pane_name":"sample-browser-chrome","port":$SWT_BR_PORT,"chrome_program":"$SWT_BIN/chrome-stub","mcp_package":"chrome-devtools-mcp@1.2.3"},
"sessions":[{"id":"services","name":"sample-browser-services","layout":{"kind":"standard","name":"tiled"},"panes":[
  {"name":"sample-browser-shell","role":"service","cwd":"."},
  {"name":"sample-browser-chrome","role":"service","cwd":"."},
  {"name":"sample-browser-sidecar","role":"service","cwd":".","command":["sleep","3600"],"port":8010}
]}]}
EOF
SWT_CFG_BR="$SWT_PROJ_BR/.agent-workspace/workspace.json"
SWT_BR_WIN='=sample-browser-services:0'
SWT_BR_OWNER="$SWT_STATE/session-workspace/browser-ports/$SWT_BR_PORT"
# Same sandbox as swrun, plus a private XDG_CACHE_HOME so the derived Chrome
# profile directory never lands in the developer's real ~/.cache.
swrun_br() {
  env -u TMUX TMUX_TMPDIR="$SWT_TMPDIR" PATH="$SWT_BIN:$PATH" XDG_STATE_HOME="$SWT_STATE" \
    XDG_CACHE_HOME="$SWT_BR_CACHE" SESSION_WORKSPACE_STOP_GRACE_SECONDS=0 \
    bash "$@"
}
swt_br_pane() {
  SWT_TMUX list-panes -t "$SWT_BR_WIN" -F "#{pane_id}	#{@session_workspace_pane}" 2>/dev/null | awk -F'\t' -v n="$1" '$2 == n {print $1}'
}

SWT_OUT="$(swrun_br "$HERE/workspace-start.sh" --config "$SWT_CFG_BR" --no-attach --no-services 2>&1)"
SWT_STATUS=$?
SWT_BR_COUNT="$(SWT_TMUX list-panes -t "$SWT_BR_WIN" -F '#{pane_id}' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$SWT_STATUS" -eq 0 ] && [ "$SWT_BR_COUNT" = "3" ] &&
   ! printf '%s' "$SWT_OUT" | grep -q 'browser DevTools endpoint' &&
   [ ! -e "$SWT_BR_OWNER" ]; then
  pass "browser --no-services: the selected pane is created but Chrome is neither launched, port-claimed, nor awaited"
else
  fail "browser --no-services: the selected pane is created but Chrome is neither launched, port-claimed, nor awaited" \
    "status=$SWT_STATUS panes=$SWT_BR_COUNT owner=$(cat "$SWT_BR_OWNER" 2>/dev/null) output=$SWT_OUT"
fi

SWT_BR_STATUS="$(swrun_br "$HERE/workspace-status.sh" --config "$SWT_CFG_BR" --json 2>&1)"
if printf '%s' "$SWT_BR_STATUS" | jq -e --argjson port "$SWT_BR_PORT" '
  ([.[] | select(.pane == "sample-browser-chrome")] | length) == 1 and
  (.[] | select(.pane == "sample-browser-chrome") | (.readiness == "not-ready" or .readiness == "unknown-curl-missing") and .port == $port) and
  all(.[] | select(.pane != "sample-browser-chrome"); .readiness == "n/a") and
  (.[] | select(.pane == "sample-browser-sidecar") | .port == 8010)
' >/dev/null 2>&1; then
  pass "browser status: only the selected pane carries DevTools readiness (not-ready before launch); siblings stay n/a"
else
  fail "browser status: only the selected pane carries DevTools readiness (not-ready before launch); siblings stay n/a" "$SWT_BR_STATUS"
fi

SWT_OUT="$(swrun_br "$HERE/workspace-start.sh" --config "$SWT_CFG_BR" --no-attach 2>&1)"
SWT_STATUS=$?
if [ "$SWT_STATUS" -eq 0 ] &&
   printf '%s' "$SWT_OUT" | grep -Fq "[ready]  browser DevTools endpoint http://127.0.0.1:$SWT_BR_PORT" &&
   [ "$(sed -n '1p' "$SWT_BR_OWNER" 2>/dev/null)" = "sample-browser" ]; then
  pass "browser start: a plain services start launches Chrome into the selected pane, claims the port, and waits for /json/version"
else
  fail "browser start: a plain services start launches Chrome into the selected pane, claims the port, and waits for /json/version" \
    "status=$SWT_STATUS owner=$(cat "$SWT_BR_OWNER" 2>/dev/null) output=$SWT_OUT"
fi

SWT_BR_SIDECAR="$(swt_br_pane sample-browser-sidecar)"
[ -n "$SWT_BR_SIDECAR" ] && swt_wait_cmd "$SWT_BR_SIDECAR" "sleep"
SWT_BR_STATUS="$(swrun_br "$HERE/workspace-status.sh" --config "$SWT_CFG_BR" --json 2>&1)"
if printf '%s' "$SWT_BR_STATUS" | jq -e '
  ([.[] | select(.health == "healthy")] | length) == 3 and
  (.[] | select(.pane == "sample-browser-chrome") | .readiness == "ready") and
  all(.[] | select(.pane != "sample-browser-chrome"); .readiness == "n/a") and
  (.[] | select(.pane == "sample-browser-sidecar") | .process == "sleep" and .port == 8010)
' >/dev/null 2>&1; then
  pass "browser status: the selected pane reports ready while the sibling service keeps its own command and port"
else
  fail "browser status: the selected pane reports ready while the sibling service keeps its own command and port" "$SWT_BR_STATUS"
fi

swrun_br "$HERE/workspace-stop.sh" services --config "$SWT_CFG_BR" --confirmed >/dev/null 2>&1
if [ ! -e "$SWT_BR_OWNER" ] && ! SWT_TMUX has-session -t '=sample-browser-services' 2>/dev/null; then
  pass "browser stop: stopping the shared services session releases the DevTools port claim"
else
  fail "browser stop: stopping the shared services session releases the DevTools port claim" \
    "owner=$(cat "$SWT_BR_OWNER" 2>/dev/null) sessions=$(SWT_TMUX list-sessions -F '#{session_name}' 2>/dev/null | tr '\n' ' ')"
fi

# --- 13. teardown + leak check -------------------------------------------
swrun "$HERE/workspace-stop.sh" --config "$SWT_CFG" --confirmed --all >/dev/null 2>&1
swrun "$HERE/workspace-stop.sh" --config "$SWT_CFG2" --confirmed --all >/dev/null 2>&1
SWT_LEFT="$(SWT_TMUX list-sessions -F "#{session_name}	#{@session_workspace_project}" 2>/dev/null | awk -F'\t' '$2 == "sample-project" || $2 == "sample-solo" {print $1}' | tr '\n' ' ')"
if [ -z "$SWT_LEFT" ]; then
  pass "stop --all: no session carrying this project's marker is left behind"
else
  fail "stop --all: no session carrying this project's marker is left behind" "left=[$SWT_LEFT]"
fi

sw_tmux_teardown
SWT_SOCKET=""
trap 'rm -rf "$TMPROOT"' EXIT

fi  # end tmux-available guard

# ===========================================================================
# Phase E: bootstrap shim (templates/workspace.sh) — plugin-root resolution
#
# The shim contains zero project logic; these tests fake plugin-cache trees
# under a temp $HOME (never the real ~/.codex or ~/.claude) and drive it with
# stub `scripts/workspace.sh` executables that answer --contract and
# otherwise report which candidate ran and with what argv, so precedence,
# sort -V correctness, contract-gating, and argv/path quoting can all be
# asserted end to end without touching a real plugin install.
# ===========================================================================
echo
echo "== machine-wide dispatcher install/refresh =="
SW_INSTALL_TARGET="$TMPROOT/install-bin/workspace"
mkdir -p "$(dirname "$SW_INSTALL_TARGET")"
cp "$HERE/../templates/workspace-dispatcher.sh" "$SW_INSTALL_TARGET"
chmod 0644 "$SW_INSTALL_TARGET"
SW_INSTALL_REPAIR="$(SESSION_WORKSPACE_PLUGIN_ROOT="$HERE/.." bash "$HERE/workspace-install.sh" --target "$SW_INSTALL_TARGET" 2>&1)"
SW_INSTALL_MODE="$(stat -c '%a' "$SW_INSTALL_TARGET" 2>/dev/null || stat -f '%Lp' "$SW_INSTALL_TARGET" 2>/dev/null)"
if [ "$SW_INSTALL_MODE" = "755" ] &&
   printf '%s' "$SW_INSTALL_REPAIR" | grep -qF '[repaired] content was current; restored executable mode' &&
   [ ! -e "$SW_INSTALL_TARGET.bak" ]; then
  pass "install: repairs executable mode on byte-identical dispatcher without a backup"
else
  fail "install: repairs executable mode on byte-identical dispatcher without a backup" \
    "mode=$SW_INSTALL_MODE backup=$([ -e "$SW_INSTALL_TARGET.bak" ] && echo yes || echo no) output=$SW_INSTALL_REPAIR"
fi
SW_INSTALL_CURRENT="$(SESSION_WORKSPACE_PLUGIN_ROOT="$HERE/.." bash "$HERE/workspace-install.sh" --target "$SW_INSTALL_TARGET" 2>&1)"
if printf '%s' "$SW_INSTALL_CURRENT" | grep -qF '[ok] already current — nothing to do'; then
  pass "install: executable byte-identical dispatcher remains an idempotent no-op"
else
  fail "install: executable byte-identical dispatcher remains an idempotent no-op" "$SW_INSTALL_CURRENT"
fi

echo "== Phase E: bootstrap shim (templates/workspace.sh) =="

SWE_SHIM="$HERE/../templates/workspace.sh"
SWE_CONTRACT="session-workspace-cli 1"

if bash -n "$SWE_SHIM" 2>"$HERE"/.syntax-err.tmp; then
  pass "syntax: templates/workspace.sh"
else
  fail "syntax: templates/workspace.sh" "$(cat "$HERE"/.syntax-err.tmp)"
fi
rm -f "$HERE"/.syntax-err.tmp

# Writes a fake installed-plugin CLI at <root>/scripts/workspace.sh. It
# answers --contract with $2 (default: the real contract string) and
# otherwise prints TAG:<tag> ARGS:<argv...> CONFIG:<$SESSION_WORKSPACE_CONFIG>
# so a test can tell which candidate the shim chose, with what arguments,
# and what config path it exported — without any real agent ever launching.
swe_make_stub() {
  local root="$1" tag="$2" contract_out="${3:-$SWE_CONTRACT}"
  mkdir -p "$root/scripts"
  cat > "$root/scripts/workspace.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--contract" ]; then
  printf '%s\n' "$contract_out"
  exit 0
fi
printf 'TAG:%s ARGS:%s CONFIG:%s\n' "$tag" "\$*" "\$SESSION_WORKSPACE_CONFIG"
EOF
  chmod +x "$root/scripts/workspace.sh"
}

# A stub with NO --contract branch at all, simulating an ancient/foreign
# install that doesn't speak the handshake — its --contract call falls
# through to the default branch and prints something that is not the
# contract string, which must be treated the same as an explicit mismatch.
swe_make_stub_no_contract() {
  local root="$1" tag="$2"
  mkdir -p "$root/scripts"
  cat > "$root/scripts/workspace.sh" <<EOF
#!/usr/bin/env bash
printf 'TAG:%s ARGS:%s\n' "$tag" "\$*"
EOF
  chmod +x "$root/scripts/workspace.sh"
}

SWE_HOME="$TMPROOT/shim-e-home"

# --- E1: SESSION_WORKSPACE_PLUGIN_ROOT takes precedence over everything ---
rm -rf "$SWE_HOME"
mkdir -p "$SWE_HOME/.codex/plugins/cache/mkt/session-workspace/9.9.9"
swe_make_stub "$SWE_HOME/.codex/plugins/cache/mkt/session-workspace/9.9.9" "codex-9.9.9"
SWE_OVERRIDE="$TMPROOT/shim-e-override"
rm -rf "$SWE_OVERRIDE"
# Deliberately gives the override a WRONG contract answer: true precedence
# means the shim uses it without even checking, unlike every cache candidate.
swe_make_stub "$SWE_OVERRIDE" "override" "wrong-contract"
SWE_OUT="$(env HOME="$SWE_HOME" SESSION_WORKSPACE_PLUGIN_ROOT="$SWE_OVERRIDE" bash "$SWE_SHIM" ping 2>&1)"
if printf '%s' "$SWE_OUT" | grep -q "TAG:override ARGS:ping"; then
  pass "shim: SESSION_WORKSPACE_PLUGIN_ROOT takes precedence over everything"
else
  fail "shim: SESSION_WORKSPACE_PLUGIN_ROOT takes precedence over everything" "$SWE_OUT"
fi

# --- E2: newest version wins via sort -V (lexical sort would pick wrong) --
rm -rf "$SWE_HOME"
mkdir -p "$SWE_HOME/.codex/plugins/cache/mkt/session-workspace/0.9.0"
mkdir -p "$SWE_HOME/.codex/plugins/cache/mkt/session-workspace/0.10.0"
swe_make_stub "$SWE_HOME/.codex/plugins/cache/mkt/session-workspace/0.9.0" "codex-0.9.0"
swe_make_stub "$SWE_HOME/.codex/plugins/cache/mkt/session-workspace/0.10.0" "codex-0.10.0"
SWE_OUT="$(env -u SESSION_WORKSPACE_PLUGIN_ROOT HOME="$SWE_HOME" bash "$SWE_SHIM" v 2>&1)"
if printf '%s' "$SWE_OUT" | grep -q "TAG:codex-0.10.0"; then
  pass "shim: newest version selected via sort -V (0.10.0 beats 0.9.0, not lexical)"
else
  fail "shim: newest version selected via sort -V (0.10.0 beats 0.9.0, not lexical)" "$SWE_OUT"
fi

# --- E3: Codex cache preferred over Claude cache when both compatible -----
rm -rf "$SWE_HOME"
mkdir -p "$SWE_HOME/.codex/plugins/cache/mkt/session-workspace/0.10.0"
mkdir -p "$SWE_HOME/.claude/plugins/cache/mkt/session-workspace/0.10.0"
swe_make_stub "$SWE_HOME/.codex/plugins/cache/mkt/session-workspace/0.10.0" "codex-0.10.0"
swe_make_stub "$SWE_HOME/.claude/plugins/cache/mkt/session-workspace/0.10.0" "claude-0.10.0"
SWE_OUT="$(env -u SESSION_WORKSPACE_PLUGIN_ROOT HOME="$SWE_HOME" bash "$SWE_SHIM" p 2>&1)"
if printf '%s' "$SWE_OUT" | grep -q "TAG:codex-0.10.0"; then
  pass "shim: Codex cache preferred over Claude cache when both are compatible"
else
  fail "shim: Codex cache preferred over Claude cache when both are compatible" "$SWE_OUT"
fi

# --- E4: a candidate with wrong/missing --contract is skipped -------------
rm -rf "$SWE_HOME"
mkdir -p "$SWE_HOME/.codex/plugins/cache/mkt/session-workspace/0.9.0"
mkdir -p "$SWE_HOME/.codex/plugins/cache/mkt/session-workspace/0.10.0"
swe_make_stub "$SWE_HOME/.codex/plugins/cache/mkt/session-workspace/0.9.0" "codex-0.9.0"
swe_make_stub_no_contract "$SWE_HOME/.codex/plugins/cache/mkt/session-workspace/0.10.0" "codex-0.10.0-bad"
SWE_OUT="$(env -u SESSION_WORKSPACE_PLUGIN_ROOT HOME="$SWE_HOME" bash "$SWE_SHIM" q 2>&1)"
if printf '%s' "$SWE_OUT" | grep -q "TAG:codex-0.9.0"; then
  pass "shim: a candidate whose --contract output is wrong/missing is skipped for the next compatible one"
else
  fail "shim: a candidate whose --contract output is wrong/missing is skipped for the next compatible one" "$SWE_OUT"
fi

# --- E5: no compatible candidate anywhere -> non-zero, guidance names both
rm -rf "$SWE_HOME"
mkdir -p "$SWE_HOME/.codex/plugins/cache/mkt/session-workspace/0.10.0"
mkdir -p "$SWE_HOME/.claude/plugins/cache/mkt/session-workspace/0.10.0"
swe_make_stub_no_contract "$SWE_HOME/.codex/plugins/cache/mkt/session-workspace/0.10.0" "codex-bad"
swe_make_stub_no_contract "$SWE_HOME/.claude/plugins/cache/mkt/session-workspace/0.10.0" "claude-bad"
SWE_OUT="$(env -u SESSION_WORKSPACE_PLUGIN_ROOT HOME="$SWE_HOME" bash "$SWE_SHIM" r 2>&1)"
SWE_STATUS=$?
if [ "$SWE_STATUS" -ne 0 ] &&
   printf '%s' "$SWE_OUT" | grep -qi "codex" &&
   printf '%s' "$SWE_OUT" | grep -qi "claude"; then
  pass "shim: no compatible candidate exits non-zero with guidance naming both providers"
else
  fail "shim: no compatible candidate exits non-zero with guidance naming both providers" "status=$SWE_STATUS output=$SWE_OUT"
fi

# --- E6: project path containing a space AND an apostrophe, end to end ----
rm -rf "$SWE_HOME"
mkdir -p "$SWE_HOME/.codex/plugins/cache/mkt/session-workspace/0.10.0"
swe_make_stub "$SWE_HOME/.codex/plugins/cache/mkt/session-workspace/0.10.0" "codex-0.10.0"
SWE_PROJECT="$TMPROOT/sample project's dir"
mkdir -p "$SWE_PROJECT/.agent-workspace"
cp "$SWE_SHIM" "$SWE_PROJECT/workspace.sh"
SWE_OUT="$(env -u SESSION_WORKSPACE_PLUGIN_ROOT HOME="$SWE_HOME" bash "$SWE_PROJECT/workspace.sh" s 2>&1)"
# The shim resolves PROJECT_DIR with `pwd -P`, which canonicalizes symlinks
# (e.g. macOS's /tmp -> /private/tmp) — compute the expectation the same way
# instead of asserting against the possibly-symlinked $SWE_PROJECT.
SWE_EXPECT_CFG="$(cd "$SWE_PROJECT" && pwd -P)/.agent-workspace/workspace.json"
if printf '%s' "$SWE_OUT" | grep -q "TAG:codex-0.10.0" &&
   printf '%s' "$SWE_OUT" | grep -qF "CONFIG:$SWE_EXPECT_CFG"; then
  pass "shim: a project path containing a space and an apostrophe resolves correctly end to end"
else
  fail "shim: a project path containing a space and an apostrophe resolves correctly end to end" "$SWE_OUT"
fi

# --- E7: arguments are forwarded verbatim, including one with spaces ------
SWE_OUT="$(env -u SESSION_WORKSPACE_PLUGIN_ROOT HOME="$SWE_HOME" bash "$SWE_PROJECT/workspace.sh" plan "an arg with spaces" --flag 2>&1)"
if printf '%s' "$SWE_OUT" | grep -qF "ARGS:plan an arg with spaces --flag"; then
  pass "shim: arguments are forwarded verbatim, including one containing spaces"
else
  fail "shim: arguments are forwarded verbatim, including one containing spaces" "$SWE_OUT"
fi

# ===========================================================================
# Phase F — workspace-doctor.sh
#
# Every scenario below runs the doctor against a self-contained fixture with
# a fake $HOME (plugin caches), a fake source tree (drift comparison), a
# private $XDG_STATE_HOME, and a sanitized PATH — never the developer's real
# installs, and never a real tmux server (no tmux command is ever issued by
# the doctor; it only reads `tmux -V`).
# ===========================================================================
echo "== Phase F: workspace-doctor =="

SWF="$TMPROOT/doctor"
SWF_HOME="$SWF/home"
SWF_SRC="$SWF/src"
SWF_STATE="$SWF/state"
SWF_BIN="$SWF/bin"
SWF_PROJECT="$SWF/sample-project"
SWF_SECRET="placeholder-secret-value-9f3a"

# --- fake plugin caches + source tree ---------------------------------------
swf_make_cache() {
  local ver_dir="$1"
  mkdir -p "$ver_dir/scripts"
  printf '#!/usr/bin/env bash\n:\n' > "$ver_dir/scripts/lib.sh"
}
swf_make_source() {
  local dir="$1" ver="$2"
  mkdir -p "$dir/.claude-plugin"
  printf '{"name":"x","version":"%s"}\n' "$ver" > "$dir/.claude-plugin/plugin.json"
}
swf_reset_deps() {
  local k_ver="$1" c_ver="$2" s_ver="$3"
  rm -rf "$SWF_HOME" "$SWF_SRC"
  swf_make_cache "$SWF_HOME/.claude/plugins/cache/mkt/knowledge/$k_ver"
  swf_make_cache "$SWF_HOME/.claude/plugins/cache/mkt/session-chat/$c_ver"
  swf_make_cache "$SWF_HOME/.claude/plugins/cache/mkt/session-scheduler/$s_ver"
  swf_make_source "$SWF_SRC/knowledge" "$k_ver"
  swf_make_source "$SWF_SRC/session-chat" "$c_ver"
  swf_make_source "$SWF_SRC/session-scheduler" "$s_ver"
}
swf_reset_deps 0.3.2 0.17.0 0.5.0

# --- sanitized PATH ---------------------------------------------------------
# swf_make_bin DEST [TOOL_TO_OMIT...] — a bin dir holding symlinks to the
# real external tools the doctor uses, minus the omitted ones, plus stub
# claude/codex runtimes. Setting PATH to just this dir is how a "missing
# tool" is simulated without touching the machine's real installs.
swf_make_bin() {
  local dest="$1"
  shift
  local omit=" $* " t p
  rm -rf "$dest"
  mkdir -p "$dest"
  for t in bash sh env jq git tmux stat id find wc tr grep sort head basename dirname cat sed awk ls uname; do
    case "$omit" in
      *" $t "*) continue ;;
    esac
    p="$(command -v "$t" 2>/dev/null)" || continue
    [ -n "$p" ] && ln -sf "$p" "$dest/$t"
  done
  for t in claude codex; do
    printf '#!/usr/bin/env bash\necho "%s-stub 1.0.0"\n' "$t" > "$dest/$t"
    chmod +x "$dest/$t"
  done
}
swf_make_bin "$SWF_BIN"

# --- healthy fixture project ------------------------------------------------
swf_write_project() {
  rm -rf "$SWF_PROJECT"
  mkdir -p "$SWF_PROJECT/.agent-workspace" "$SWF_PROJECT/component-a"
  (cd "$SWF_PROJECT" && git init -q . && git config user.email t@example.invalid && git config user.name t)
  printf 'workspace.local.env\n.tmp/\ntmp/\n' > "$SWF_PROJECT/.gitignore"
  printf 'SAMPLE_TOKEN=%s\n' "$SWF_SECRET" > "$SWF_PROJECT/workspace.local.env"
  chmod 600 "$SWF_PROJECT/workspace.local.env"
  cat > "$SWF_PROJECT/.agent-workspace/workspace.json" <<'EOF'
{
  "schema_version": 1,
  "project": { "id": "sample-project", "display_name": "Sample Project", "root": "." },
  "runtimes": {
    "claude": { "program": "claude", "args": [] },
    "codex": { "program": "codex", "args": [] }
  },
  "roles": {
    "orchestrator": { "runtime": "claude", "grants": [], "env_group": "dev" },
    "executor": { "runtime": "codex", "grants": ["messages"], "env_group": "dev" }
  },
  "stores": {
    "base": ".tmp",
    "pin": ["messages", "scheduler", "contexts"],
    "memory": { "mode": "shared", "root": ".agents/memory" }
  },
  "env": {
    "groups": {
      "dev": { "values": { "AGENT_PLUGINS_TIME_ZONE": "Asia/Kolkata" }, "pin_to_session": true }
    }
  },
  "secrets": {
    "env_file": "workspace.local.env",
    "allow": ["SAMPLE_TOKEN"],
    "visible_to_roles": ["executor"],
    "on_missing": "warn"
  },
  "sessions": [
    {
      "id": "development",
      "name": "${PROJECT_ID}-development",
      "window_index": 0,
      "layout": { "kind": "standard", "name": "tiled" },
      "retain_layout": true,
      "panes": [
        { "name": "${PROJECT_ID}-master", "role": "orchestrator", "cwd": "." },
        { "name": "${PROJECT_ID}-web-executor", "role": "executor", "cwd": "component-a" }
      ]
    }
  ],
  "behavior": {
    "default_start_target": "all",
    "attach": "if_terminal",
    "stop_scope": "selected",
    "save_before_stop": true,
    "session_chat_helper": { "resolve": "always", "on_missing": "fail" }
  }
}
EOF
}
swf_write_project
SWF_CONFIG="$SWF_PROJECT/.agent-workspace/workspace.json"

# swf_doctor [ARGS...] — run the doctor in the fixture's sealed environment.
# PATH is $SWF_BIN ONLY: no real claude/codex/tmux install can leak in.
swf_doctor_config() {
  local config="$1"
  shift
  env -u TMUX -u SESSION_WORKSPACE_CONFIG \
    HOME="$SWF_HOME" \
    XDG_STATE_HOME="$SWF_STATE" \
    SESSION_WORKSPACE_SOURCE_TREE_DIR="$SWF_SRC" \
    PATH="$SWF_BIN" \
    bash "$HERE/workspace-doctor.sh" --config "$config" "$@" 2>&1
}
swf_doctor() {
  swf_doctor_config "$SWF_CONFIG" "$@"
}
# swf_status JSON CHECK_ID
swf_status() {
  printf '%s' "$1" | jq -r --arg id "$2" '.checks[] | select(.id == $id) | .status'
}

mkdir -p "$SWF_STATE"

# --- F1: healthy fixture — every check reports OK/INFO, exit 0 --------------
SWF_JSON="$(swf_doctor --json)"
SWF_JSON_STATUS=$?
if [ "$SWF_JSON_STATUS" -eq 0 ]; then
  pass "doctor: healthy fixture exits 0"
else
  fail "doctor: healthy fixture exits 0" "status=$SWF_JSON_STATUS output=$SWF_JSON"
fi
if printf '%s' "$SWF_JSON" | jq -e '.' >/dev/null 2>&1; then
  pass "doctor: --json emits valid JSON"
else
  fail "doctor: --json emits valid JSON" "$SWF_JSON"
fi
SWF_V1_HUMAN="$(swf_doctor)"
if printf '%s' "$SWF_V1_HUMAN" | grep -Eq '^\[OK[[:space:]]*\][[:space:]]+config\.validation[[:space:]]+.*\(schema_version 1\)$'; then
  pass "doctor: schema-v1 human config.validation line reports schema_version 1"
else
  fail "doctor: schema-v1 human config.validation line reports schema_version 1" "$SWF_V1_HUMAN"
fi
if printf '%s' "$SWF_JSON" | jq -e '([.checks[] | select(.id == "config.validation") | .message] | length) == 1 and ([.checks[] | select(.id == "config.validation") | .message][0] | endswith("(schema_version 1)"))' >/dev/null 2>&1; then
  pass "doctor: schema-v1 JSON config.validation message reports schema_version 1"
else
  fail "doctor: schema-v1 JSON config.validation message reports schema_version 1" "$SWF_JSON"
fi
SWF_V2_HUMAN="$(swf_doctor_config "$HARNESS_BASE")"
if printf '%s' "$SWF_V2_HUMAN" | grep -Eq '^\[OK[[:space:]]*\][[:space:]]+config\.validation[[:space:]]+.*\(schema_version 2\)$'; then
  pass "doctor: schema-v2 human config.validation line reports schema_version 2"
else
  fail "doctor: schema-v2 human config.validation line reports schema_version 2" "$SWF_V2_HUMAN"
fi
SWF_V2_JSON="$(swf_doctor_config "$HARNESS_BASE" --json)"
if printf '%s' "$SWF_V2_JSON" | jq -e '([.checks[] | select(.id == "config.validation") | .message] | length) == 1 and ([.checks[] | select(.id == "config.validation") | .message][0] | endswith("(schema_version 2)"))' >/dev/null 2>&1; then
  pass "doctor: schema-v2 JSON config.validation message reports schema_version 2"
else
  fail "doctor: schema-v2 JSON config.validation message reports schema_version 2" "$SWF_V2_JSON"
fi
SWF_V4_COMPAT="$SWF_PROJECT/.agent-workspace/workspace-v4.json"
jq '.schema_version = 4' "$SWF_CONFIG" > "$SWF_V4_COMPAT"
SWF_V4_HUMAN="$(swf_doctor_config "$SWF_V4_COMPAT")"
if printf '%s' "$SWF_V4_HUMAN" | grep -Eq '^\[OK[[:space:]]*\][[:space:]]+config\.validation[[:space:]]+.*\(schema_version 4\)$'; then
  pass "doctor: schema-v4 human config.validation line reports schema_version 4"
else
  fail "doctor: schema-v4 human config.validation line reports schema_version 4" "$SWF_V4_HUMAN"
fi
SWF_V4_JSON="$(swf_doctor_config "$SWF_V4_COMPAT" --json)"
if printf '%s' "$SWF_V4_JSON" | jq -e '([.checks[] | select(.id == "config.validation") | .message] | length) == 1 and ([.checks[] | select(.id == "config.validation") | .message][0] | endswith("(schema_version 4)"))' >/dev/null 2>&1; then
  pass "doctor: schema-v4 JSON config.validation message reports schema_version 4"
else
  fail "doctor: schema-v4 JSON config.validation message reports schema_version 4" "$SWF_V4_JSON"
fi
SWF_BAD="$(printf '%s' "$SWF_JSON" | jq -r '[.checks[] | select(.status == "ERROR" or .status == "WARN") | .id] | join(",")' 2>/dev/null)"
if [ -z "$SWF_BAD" ]; then
  pass "doctor: healthy fixture reports no ERROR/WARN check"
else
  fail "doctor: healthy fixture reports no ERROR/WARN check" "$SWF_BAD :: $SWF_JSON"
fi
for swf_id in tooling.tmux tooling.jq tooling.git config.discovery config.validation \
              plugins.knowledge plugins.session-chat plugins.session-scheduler \
              panes.cwd secrets.env_file runtime.claude runtime.codex \
              stores.drift integrations.session_chat_helper; do
  if [ "$(swf_status "$SWF_JSON" "$swf_id")" = "OK" ]; then
    pass "doctor: $swf_id is OK on a healthy fixture"
  else
    fail "doctor: $swf_id is OK on a healthy fixture" "got: $(swf_status "$SWF_JSON" "$swf_id")"
  fi
done
if [ "$(swf_status "$SWF_JSON" "state.dir")" = "INFO" ]; then
  pass "doctor: state.dir is INFO (not yet created) on a healthy fixture"
else
  fail "doctor: state.dir is INFO (not yet created) on a healthy fixture" "got: $(swf_status "$SWF_JSON" "state.dir")"
fi

# --- F2: human output agrees with --json -----------------------------------
SWF_HUMAN="$(swf_doctor)"
if printf '%s' "$SWF_HUMAN" | grep -q "0 error(s), 0 warning(s)"; then
  pass "doctor: human report summarizes the same 0 errors / 0 warnings"
else
  fail "doctor: human report summarizes the same 0 errors / 0 warnings" "$SWF_HUMAN"
fi

# --- F3: never prints a secret value (with a positive control) --------------
if grep -q "$SWF_SECRET" "$SWF_PROJECT/workspace.local.env"; then
  pass "doctor: positive control — the planted secret IS readable in the env file"
else
  fail "doctor: positive control — the planted secret IS readable in the env file" "grep found nothing"
fi
if printf '%s\n%s' "$SWF_HUMAN" "$SWF_JSON" | grep -q "$SWF_SECRET"; then
  fail "doctor: never prints a secret value" "the planted secret leaked into doctor output"
else
  pass "doctor: never prints a secret value"
fi

# --- F4: strictly read-only -------------------------------------------------
# One warm-up run first, so any one-time side effect of the tools the doctor
# shells out to (e.g. git populating its own caches) is already settled and
# the diff isolates the doctor's own behaviour.
swf_doctor >/dev/null 2>&1
swf_snapshot() {
  local dir="$1"
  [ -d "$dir" ] || { printf 'ABSENT\n'; return 0; }
  (cd "$dir" && find . -print | sort && find . -type f -exec cksum {} \; | sort)
}
SWF_TREE_BEFORE="$(swf_snapshot "$SWF_PROJECT")"
SWF_STATE_BEFORE="$(swf_snapshot "$SWF_STATE")"
swf_doctor >/dev/null 2>&1
swf_doctor --json >/dev/null 2>&1
SWF_TREE_AFTER="$(swf_snapshot "$SWF_PROJECT")"
SWF_STATE_AFTER="$(swf_snapshot "$SWF_STATE")"
if [ "$SWF_TREE_BEFORE" = "$SWF_TREE_AFTER" ]; then
  pass "doctor: read-only — the project tree is byte-identical before/after"
else
  fail "doctor: read-only — the project tree is byte-identical before/after" \
    "$(diff <(printf '%s' "$SWF_TREE_BEFORE") <(printf '%s' "$SWF_TREE_AFTER") | head -20)"
fi
if [ "$SWF_STATE_BEFORE" = "$SWF_STATE_AFTER" ]; then
  pass "doctor: read-only — \$XDG_STATE_HOME is byte-identical before/after"
else
  fail "doctor: read-only — \$XDG_STATE_HOME is byte-identical before/after" \
    "$(diff <(printf '%s' "$SWF_STATE_BEFORE") <(printf '%s' "$SWF_STATE_AFTER") | head -20)"
fi
if [ -d "$SWF_STATE/session-workspace/sample-project" ]; then
  fail "doctor: read-only — never creates the project state dir" "state dir was created"
else
  pass "doctor: read-only — never creates the project state dir"
fi

# --- F5: tooling — missing tmux, too-old tmux, missing jq, missing git ------
SWF_BIN_NOTMUX="$SWF/bin-no-tmux"
swf_make_bin "$SWF_BIN_NOTMUX" tmux
SWF_BIN_SAVED="$SWF_BIN"
SWF_BIN="$SWF_BIN_NOTMUX"
SWF_OUT="$(swf_doctor --json)"
SWF_RC=$?
if [ "$(swf_status "$SWF_OUT" "tooling.tmux")" = "ERROR" ] && [ "$SWF_RC" -ne 0 ]; then
  pass "doctor: a missing tmux is an ERROR and fails the exit code"
else
  fail "doctor: a missing tmux is an ERROR and fails the exit code" "rc=$SWF_RC status=$(swf_status "$SWF_OUT" "tooling.tmux")"
fi

SWF_BIN_OLDTMUX="$SWF/bin-old-tmux"
swf_make_bin "$SWF_BIN_OLDTMUX" tmux
printf '#!/usr/bin/env bash\necho "tmux 2.8"\n' > "$SWF_BIN_OLDTMUX/tmux"
chmod +x "$SWF_BIN_OLDTMUX/tmux"
SWF_BIN="$SWF_BIN_OLDTMUX"
SWF_OUT="$(swf_doctor --json)"
if [ "$(swf_status "$SWF_OUT" "tooling.tmux")" = "ERROR" ] &&
   printf '%s' "$SWF_OUT" | grep -q "below the required >= 3.2"; then
  pass "doctor: tmux below 3.2 is an ERROR (hidden secret delivery needs it)"
else
  fail "doctor: tmux below 3.2 is an ERROR" "$(swf_status "$SWF_OUT" "tooling.tmux")"
fi

SWF_BIN_NOJQ="$SWF/bin-no-jq"
swf_make_bin "$SWF_BIN_NOJQ" jq
SWF_BIN="$SWF_BIN_NOJQ"
SWF_OUT="$(swf_doctor)"
SWF_RC=$?
if [ "$SWF_RC" -ne 0 ] && printf '%s' "$SWF_OUT" | grep -q "jq is not on PATH"; then
  pass "doctor: a missing jq is an ERROR"
else
  fail "doctor: a missing jq is an ERROR" "rc=$SWF_RC $SWF_OUT"
fi
SWF_OUT="$(swf_doctor --json)"
if printf '%s' "$SWF_OUT" | "$SWF_BIN_SAVED/jq" -e '.checks[0].id == "tooling.jq"' >/dev/null 2>&1; then
  pass "doctor: --json still emits valid JSON when jq itself is missing"
else
  fail "doctor: --json still emits valid JSON when jq itself is missing" "$SWF_OUT"
fi

SWF_BIN_NOGIT="$SWF/bin-no-git"
swf_make_bin "$SWF_BIN_NOGIT" git
SWF_BIN="$SWF_BIN_NOGIT"
SWF_OUT="$(swf_doctor --json)"
SWF_RC=$?
if [ "$(swf_status "$SWF_OUT" "tooling.git")" = "WARN" ]; then
  pass "doctor: a missing git is a WARN, not an ERROR"
else
  fail "doctor: a missing git is a WARN, not an ERROR" "$(swf_status "$SWF_OUT" "tooling.git")"
fi
SWF_BIN="$SWF_BIN_SAVED"

# --- F6: plugin dependency versions ----------------------------------------
swf_reset_deps 0.3.1 0.17.0 0.5.0
SWF_OUT="$(swf_doctor --json)"
SWF_RC=$?
if [ "$(swf_status "$SWF_OUT" "plugins.knowledge")" = "ERROR" ] && [ "$SWF_RC" -ne 0 ]; then
  pass "doctor: a plugin below its required version is an ERROR"
else
  fail "doctor: a plugin below its required version is an ERROR" "$(swf_status "$SWF_OUT" "plugins.knowledge")"
fi
swf_reset_deps 0.3.2 0.17.0 0.5.0
rm -rf "$SWF_HOME/.claude/plugins/cache/mkt/session-scheduler" "$SWF_SRC/session-scheduler"
SWF_OUT="$(swf_doctor --json)"
if [ "$(swf_status "$SWF_OUT" "plugins.session-scheduler")" = "ERROR" ]; then
  pass "doctor: an entirely missing plugin dependency is an ERROR"
else
  fail "doctor: an entirely missing plugin dependency is an ERROR" "$(swf_status "$SWF_OUT" "plugins.session-scheduler")"
fi
swf_reset_deps 0.3.2 0.17.0 0.5.0
swf_make_source "$SWF_SRC/knowledge" "0.3.9"
SWF_OUT="$(swf_doctor --json)"
SWF_RC=$?
if [ "$(swf_status "$SWF_OUT" "plugins.knowledge")" = "WARN" ] && [ "$SWF_RC" -eq 0 ] &&
   printf '%s' "$SWF_OUT" | grep -q "drifts from source tree"; then
  pass "doctor: installed-cache vs source-tree drift is a WARN and does NOT fail the exit code"
else
  fail "doctor: installed-cache vs source-tree drift is a WARN and does NOT fail the exit code" \
    "rc=$SWF_RC status=$(swf_status "$SWF_OUT" "plugins.knowledge")"
fi
if printf '%s' "$SWF_OUT" | jq -e '[.checks[].id] | index("plugins.session-context") == null' >/dev/null 2>&1; then
  pass "doctor: session-context is NOT checked (absorbed into knowledge)"
else
  fail "doctor: session-context is NOT checked (absorbed into knowledge)" "$SWF_OUT"
fi
swf_reset_deps 0.3.2 0.17.0 0.5.0

# --- F7: pane cwds ----------------------------------------------------------
SWF_CFG_BACKUP="$TMPROOT/doctor-config-backup.json"
cp "$SWF_CONFIG" "$SWF_CFG_BACKUP"
jq '.sessions[0].panes[1].cwd = "component-missing"' "$SWF_CFG_BACKUP" > "$SWF_CONFIG"
SWF_OUT="$(swf_doctor --json)"
SWF_RC=$?
# A required pane's missing cwd is ALSO a validate-config.sh error (the same
# _resolve_cwd_within_root), so config.validation itself is ERROR here — and
# per the "skip all post-config checks when config validation failed" fix,
# the doctor-side panes.cwd check (and every other post-config check) does
# NOT additionally run against an already-invalid config.
if [ "$(swf_status "$SWF_OUT" "config.validation")" = "ERROR" ] && [ "$SWF_RC" -ne 0 ] &&
   [ -z "$(swf_status "$SWF_OUT" "panes.cwd")" ]; then
  pass "doctor: a required pane whose cwd is missing fails config.validation, and panes.cwd is skipped"
else
  fail "doctor: a required pane whose cwd is missing fails config.validation, and panes.cwd is skipped" \
    "rc=$SWF_RC config.validation=$(swf_status "$SWF_OUT" "config.validation") panes.cwd=$(swf_status "$SWF_OUT" "panes.cwd")"
fi
jq '.sessions[0].panes[1].cwd = "component-missing" | .sessions[0].panes[1].optional = true' \
  "$SWF_CFG_BACKUP" > "$SWF_CONFIG"
SWF_OUT="$(swf_doctor --json)"
SWF_RC=$?
if [ "$(swf_status "$SWF_OUT" "panes.cwd")" = "INFO" ] && [ "$SWF_RC" -eq 0 ]; then
  pass "doctor: an optional pane whose cwd is missing is INFO/skip, not an ERROR"
else
  fail "doctor: an optional pane whose cwd is missing is INFO/skip, not an ERROR" \
    "rc=$SWF_RC status=$(swf_status "$SWF_OUT" "panes.cwd")"
fi
cp "$SWF_CFG_BACKUP" "$SWF_CONFIG"

# --- F8: secrets gates -------------------------------------------------------
# Every one of these is ALSO checked by validate-config.sh's
# _validate_secrets_file (same mode/git-ignore/symlink gates), so
# config.validation itself fails here too -- and per "skip all post-config
# checks when config validation failed", the doctor-side secrets.env_file
# check does not additionally run. The security property that matters (the
# secret VALUE never leaks into doctor output) is unaffected either way.
chmod 644 "$SWF_PROJECT/workspace.local.env"
SWF_OUT="$(swf_doctor --json)"
SWF_RC=$?
if [ "$(swf_status "$SWF_OUT" "config.validation")" = "ERROR" ] && [ "$SWF_RC" -ne 0 ] &&
   [ -z "$(swf_status "$SWF_OUT" "secrets.env_file")" ] &&
   printf '%s' "$SWF_OUT" | grep -q "must be mode 0600"; then
  pass "doctor: a secrets file that is not 0600 fails config.validation, and secrets.env_file is skipped"
else
  fail "doctor: a secrets file that is not 0600 fails config.validation, and secrets.env_file is skipped" \
    "rc=$SWF_RC config.validation=$(swf_status "$SWF_OUT" "config.validation") secrets.env_file=$(swf_status "$SWF_OUT" "secrets.env_file")"
fi
if printf '%s' "$SWF_OUT" | grep -q "$SWF_SECRET"; then
  fail "doctor: a failing secrets gate still never prints the secret value" "leaked"
else
  pass "doctor: a failing secrets gate still never prints the secret value"
fi
chmod 600 "$SWF_PROJECT/workspace.local.env"
printf 'tmp/\n.tmp/\n' > "$SWF_PROJECT/.gitignore"
SWF_OUT="$(swf_doctor --json)"
if [ "$(swf_status "$SWF_OUT" "config.validation")" = "ERROR" ] &&
   [ -z "$(swf_status "$SWF_OUT" "secrets.env_file")" ] &&
   printf '%s' "$SWF_OUT" | grep -q "must be git-ignored"; then
  pass "doctor: a secrets file that is not git-ignored fails config.validation, and secrets.env_file is skipped"
else
  fail "doctor: a secrets file that is not git-ignored fails config.validation, and secrets.env_file is skipped" \
    "config.validation=$(swf_status "$SWF_OUT" "config.validation") secrets.env_file=$(swf_status "$SWF_OUT" "secrets.env_file")"
fi
printf 'workspace.local.env\n.tmp/\ntmp/\n' > "$SWF_PROJECT/.gitignore"
mv "$SWF_PROJECT/workspace.local.env" "$SWF_PROJECT/.real-env"
ln -s "$SWF_PROJECT/.real-env" "$SWF_PROJECT/workspace.local.env"
SWF_OUT="$(swf_doctor --json)"
if [ "$(swf_status "$SWF_OUT" "config.validation")" = "ERROR" ] &&
   [ -z "$(swf_status "$SWF_OUT" "secrets.env_file")" ] &&
   printf '%s' "$SWF_OUT" | grep -q "must not be a symlink"; then
  pass "doctor: a symlinked secrets file fails config.validation, and secrets.env_file is skipped"
else
  fail "doctor: a symlinked secrets file fails config.validation, and secrets.env_file is skipped" \
    "config.validation=$(swf_status "$SWF_OUT" "config.validation") secrets.env_file=$(swf_status "$SWF_OUT" "secrets.env_file")"
fi
rm -f "$SWF_PROJECT/workspace.local.env"
mv "$SWF_PROJECT/.real-env" "$SWF_PROJECT/workspace.local.env"
chmod 600 "$SWF_PROJECT/workspace.local.env"

# The doctor now deliberately opens a metadata-gated secrets file and uses
# the same literal parser as adapters.sh. Exercise the live failure shapes:
# shell export syntax, a shell default expansion, a missing line, matching
# outer quotes, and an inner quote. Command-substitution-looking values remain
# literal parser output and must never execute. Only key NAMES may be reported.
SWF_BARE_VALUE="bare-secret-sentinel-7841"
SWF_EXPORT_VALUE="export-secret-sentinel-7842"
SWF_DEFAULT_VALUE="default-secret-sentinel-7843"
SWF_DOUBLE_QUOTED_VALUE="double-quoted-secret-sentinel-7844"
SWF_SINGLE_QUOTED_VALUE="single-quoted-secret-sentinel-7845"
SWF_INNER_QUOTE_VALUE='inner"quote-secret-sentinel-7846'
SWF_INERT_MARKER="$SWF/inert-secret-value-executed"
rm -f "$SWF_INERT_MARKER"
{
  printf '%s\n' "BARE_TOKEN=$SWF_BARE_VALUE"
  printf '%s\n' "export EXPORT_TOKEN=$SWF_EXPORT_VALUE"
  printf '%s\n' 'DEFAULT_TOKEN="${DEFAULT_TOKEN:-default-secret-sentinel-7843}"'
  printf '%s\n' "DOUBLE_QUOTED_TOKEN=\"$SWF_DOUBLE_QUOTED_VALUE\""
  printf "SINGLE_QUOTED_TOKEN='%s'\n" "$SWF_SINGLE_QUOTED_VALUE"
  printf '%s\n' "INNER_QUOTE_TOKEN=$SWF_INNER_QUOTE_VALUE"
  printf 'INERT_TOKEN=$(touch %s)\n' "$SWF_INERT_MARKER"
} > "$SWF_PROJECT/workspace.local.env"
chmod 600 "$SWF_PROJECT/workspace.local.env"
jq '.secrets.allow = ["BARE_TOKEN", "EXPORT_TOKEN", "DEFAULT_TOKEN", "DOUBLE_QUOTED_TOKEN", "SINGLE_QUOTED_TOKEN", "INNER_QUOTE_TOKEN", "MISSING_TOKEN", "INERT_TOKEN"] |
    .secrets.on_missing = "fail"' "$SWF_CFG_BACKUP" > "$SWF_CONFIG"

if grep -q "$SWF_BARE_VALUE" "$SWF_PROJECT/workspace.local.env" &&
   grep -q "$SWF_EXPORT_VALUE" "$SWF_PROJECT/workspace.local.env" &&
   grep -q "$SWF_DEFAULT_VALUE" "$SWF_PROJECT/workspace.local.env" &&
   grep -q "$SWF_DOUBLE_QUOTED_VALUE" "$SWF_PROJECT/workspace.local.env" &&
   grep -q "$SWF_SINGLE_QUOTED_VALUE" "$SWF_PROJECT/workspace.local.env" &&
   grep -q "$SWF_INNER_QUOTE_VALUE" "$SWF_PROJECT/workspace.local.env"; then
  pass "doctor secrets resolution control: all planted values are readable in the gated file"
else
  fail "doctor secrets resolution control: all planted values are readable in the gated file" "fixture is incomplete"
fi

SWF_SECRETS_FAIL_OUT="$(swf_doctor --json)"
SWF_SECRETS_FAIL_RC=$?
if [ "$(swf_status "$SWF_SECRETS_FAIL_OUT" "secrets.env_file")" = "ERROR" ] &&
   [ "$SWF_SECRETS_FAIL_RC" -ne 0 ] &&
   printf '%s' "$SWF_SECRETS_FAIL_OUT" | jq -e '.checks[] | select(.id == "secrets.env_file") |
     .message | contains("3 allowed key(s) do not resolve (secrets.on_missing: fail)")' >/dev/null 2>&1; then
  pass "doctor secrets resolution: on_missing=fail makes unresolved keys an ERROR with non-zero exit"
else
  fail "doctor secrets resolution: on_missing=fail makes unresolved keys an ERROR with non-zero exit" \
    "rc=$SWF_SECRETS_FAIL_RC output=$SWF_SECRETS_FAIL_OUT"
fi

SWF_FAIL_UNRESOLVED="$(printf '%s' "$SWF_SECRETS_FAIL_OUT" | jq -r '.checks[] |
  select(.id == "secrets.env_file") | .details[] | select(startswith("ERROR unresolvable allowed key: ")) |
  sub("ERROR unresolvable allowed key: "; "")' | sort | tr '\n' ',')"
if [ "$SWF_FAIL_UNRESOLVED" = "DEFAULT_TOKEN,EXPORT_TOKEN,MISSING_TOKEN," ]; then
  pass "doctor secrets resolution: export/default/missing shapes report exactly their key names"
else
  fail "doctor secrets resolution: export/default/missing shapes report exactly their key names" "$SWF_FAIL_UNRESOLVED"
fi

SWF_SECRETS_REMEDIATION="$(printf '%s' "$SWF_SECRETS_FAIL_OUT" | jq -r '.checks[] |
  select(.id == "secrets.env_file") | .remediation')"
if printf '%s' "$SWF_SECRETS_REMEDIATION" | grep -Fq 'bare KEY=value' &&
   printf '%s' "$SWF_SECRETS_REMEDIATION" | grep -Fq 'no export prefix' &&
   printf '%s' "$SWF_SECRETS_REMEDIATION" | grep -Fq 'no ${VAR:-default} expansion' &&
   printf '%s' "$SWF_SECRETS_REMEDIATION" | grep -Fq 'no surrounding quotes'; then
  pass "doctor secrets resolution: remediation names the required literal file shape"
else
  fail "doctor secrets resolution: remediation names the required literal file shape" "$SWF_SECRETS_REMEDIATION"
fi

jq '.secrets.on_missing = "warn"' "$SWF_CONFIG" > "$SWF_CONFIG.tmp"
mv "$SWF_CONFIG.tmp" "$SWF_CONFIG"
SWF_SECRETS_WARN_OUT="$(swf_doctor --json)"
SWF_SECRETS_WARN_RC=$?
SWF_WARN_UNRESOLVED="$(printf '%s' "$SWF_SECRETS_WARN_OUT" | jq -r '.checks[] |
  select(.id == "secrets.env_file") | .details[] | select(startswith("WARN unresolvable allowed key: ")) |
  sub("WARN unresolvable allowed key: "; "")' | sort | tr '\n' ',')"
if [ "$(swf_status "$SWF_SECRETS_WARN_OUT" "secrets.env_file")" = "WARN" ] &&
   [ "$SWF_SECRETS_WARN_RC" -eq 0 ] &&
   [ "$SWF_WARN_UNRESOLVED" = "DEFAULT_TOKEN,EXPORT_TOKEN,MISSING_TOKEN," ]; then
  pass "doctor secrets resolution: on_missing=warn reports the same names as WARN with zero exit"
else
  fail "doctor secrets resolution: on_missing=warn reports the same names as WARN with zero exit" \
    "rc=$SWF_SECRETS_WARN_RC names=$SWF_WARN_UNRESOLVED output=$SWF_SECRETS_WARN_OUT"
fi

##############################################################################
# Quote-wrapped values are a WARN even under on_missing=fail: the line is
# legal literal data, but the adapter will deliver the matching quote bytes.
##############################################################################
jq '.secrets.allow = ["DOUBLE_QUOTED_TOKEN", "SINGLE_QUOTED_TOKEN"] |
    .secrets.on_missing = "fail"' "$SWF_CFG_BACKUP" > "$SWF_CONFIG"
SWF_QUOTES_OUT="$(swf_doctor --json)"
SWF_QUOTES_RC=$?
SWF_QUOTE_WARN_NAMES="$(printf '%s' "$SWF_QUOTES_OUT" | jq -r '.checks[] |
  select(.id == "secrets.env_file") | .details[] | select(startswith("WARN quote-wrapped allowed key: ")) |
  sub("WARN quote-wrapped allowed key: "; "")' | sort | tr '\n' ',')"
if [ "$(swf_status "$SWF_QUOTES_OUT" "secrets.env_file")" = "WARN" ] &&
   [ "$SWF_QUOTES_RC" -eq 0 ] &&
   [ "$SWF_QUOTE_WARN_NAMES" = "DOUBLE_QUOTED_TOKEN,SINGLE_QUOTED_TOKEN," ] &&
   printf '%s' "$SWF_QUOTES_OUT" | jq -e '.checks[] | select(.id == "secrets.env_file") |
     .message | contains("2 allowed key(s) are quote-wrapped and will be delivered with quote characters")' >/dev/null 2>&1; then
  pass "doctor secrets resolution: matching outer single/double quotes are named as WARN even under on_missing=fail"
else
  fail "doctor secrets resolution: matching outer single/double quotes are named as WARN even under on_missing=fail" \
    "rc=$SWF_QUOTES_RC names=$SWF_QUOTE_WARN_NAMES output=$SWF_QUOTES_OUT"
fi

SWF_SECRET_OUTPUTS="$(printf '%s\n%s\n%s' "$SWF_SECRETS_FAIL_OUT" "$SWF_SECRETS_WARN_OUT" "$SWF_QUOTES_OUT")"
SWF_VALUE_LEAK=""
for swf_secret_value in "$SWF_BARE_VALUE" "$SWF_EXPORT_VALUE" "$SWF_DEFAULT_VALUE" \
                        "$SWF_DOUBLE_QUOTED_VALUE" "$SWF_SINGLE_QUOTED_VALUE" "$SWF_INNER_QUOTE_VALUE"; do
  if printf '%s' "$SWF_SECRET_OUTPUTS" | grep -Fq "$swf_secret_value"; then
    SWF_VALUE_LEAK="$swf_secret_value"
  fi
done
if [ -z "$SWF_VALUE_LEAK" ]; then
  pass "doctor secrets resolution: active key-resolution output emits no secret value"
else
  fail "doctor secrets resolution: active key-resolution output emits no secret value" "leaked a planted value"
fi

jq '.secrets.allow = ["BARE_TOKEN", "INNER_QUOTE_TOKEN", "INERT_TOKEN"] |
    .secrets.on_missing = "fail"' "$SWF_CFG_BACKUP" > "$SWF_CONFIG"
SWF_SECRETS_VALID_OUT="$(swf_doctor --json)"
SWF_SECRETS_VALID_RC=$?
SWF_INNER_QUOTE_PARSED="$( (source "$HERE/lib.sh"; _parse_env_file_value "$SWF_PROJECT/workspace.local.env" "INNER_QUOTE_TOKEN") )"
SWF_INERT_PARSED="$( (source "$HERE/lib.sh"; _parse_env_file_value "$SWF_PROJECT/workspace.local.env" "INERT_TOKEN") )"
SWF_INERT_EXPECTED='$(touch '"$SWF_INERT_MARKER"')'
if [ "$(swf_status "$SWF_SECRETS_VALID_OUT" "secrets.env_file")" = "OK" ] &&
   [ "$SWF_SECRETS_VALID_RC" -eq 0 ] &&
   [ "$SWF_INERT_PARSED" = "$SWF_INERT_EXPECTED" ] &&
   [ ! -e "$SWF_INERT_MARKER" ]; then
  pass "doctor secrets resolution: bare/inner-quote/inert values resolve and command substitution stays inert"
else
  fail "doctor secrets resolution: bare/inner-quote/inert values resolve and command substitution stays inert" \
    "rc=$SWF_SECRETS_VALID_RC status=$(swf_status "$SWF_SECRETS_VALID_OUT" "secrets.env_file") marker=$([ -e "$SWF_INERT_MARKER" ] && echo yes || echo no)"
fi
SWF_INNER_QUOTE_WARN="$(printf '%s' "$SWF_SECRETS_VALID_OUT" | jq -r '.checks[] |
  select(.id == "secrets.env_file") | .details[] | select(contains("INNER_QUOTE_TOKEN"))')"
if [ "$SWF_INNER_QUOTE_PARSED" = "$SWF_INNER_QUOTE_VALUE" ] &&
   [ -z "$SWF_INNER_QUOTE_WARN" ] &&
   [ "$(swf_status "$SWF_SECRETS_VALID_OUT" "secrets.env_file")" = "OK" ]; then
  pass "doctor secrets resolution: an inner quote is preserved literally without triggering the outer-quote WARN"
else
  fail "doctor secrets resolution: an inner quote is preserved literally without triggering the outer-quote WARN" \
    "status=$(swf_status "$SWF_SECRETS_VALID_OUT" "secrets.env_file") detail=$SWF_INNER_QUOTE_WARN"
fi

printf 'SAMPLE_TOKEN=%s\n' "$SWF_SECRET" > "$SWF_PROJECT/workspace.local.env"
chmod 600 "$SWF_PROJECT/workspace.local.env"
cp "$SWF_CFG_BACKUP" "$SWF_CONFIG"

# --- F9: state dir ----------------------------------------------------------
mkdir -p "$SWF_STATE/session-workspace/sample-project"
chmod 500 "$SWF_STATE/session-workspace/sample-project"
SWF_OUT="$(swf_doctor --json)"
SWF_RC=$?
if [ "$(swf_status "$SWF_OUT" "state.dir")" = "ERROR" ] && [ "$SWF_RC" -ne 0 ]; then
  pass "doctor: an unwritable state dir is an ERROR"
else
  fail "doctor: an unwritable state dir is an ERROR" "rc=$SWF_RC status=$(swf_status "$SWF_OUT" "state.dir")"
fi
chmod 755 "$SWF_STATE/session-workspace/sample-project"
SWF_OUT="$(swf_doctor --json)"
SWF_RC=$?
if [ "$(swf_status "$SWF_OUT" "state.dir")" = "WARN" ] && [ "$SWF_RC" -eq 0 ]; then
  pass "doctor: a state dir that is not 0700 is a WARN that does not fail the exit code"
else
  fail "doctor: a state dir that is not 0700 is a WARN that does not fail the exit code" \
    "rc=$SWF_RC status=$(swf_status "$SWF_OUT" "state.dir")"
fi
chmod 700 "$SWF_STATE/session-workspace/sample-project"
SWF_OUT="$(swf_doctor --json)"
if [ "$(swf_status "$SWF_OUT" "state.dir")" = "OK" ]; then
  pass "doctor: a 0700 state dir is OK"
else
  fail "doctor: a 0700 state dir is OK" "$(swf_status "$SWF_OUT" "state.dir")"
fi
rm -rf "$SWF_STATE/session-workspace"

# --- F10: runtime capability ------------------------------------------------
jq '.runtimes.codex.program = "definitely-not-installed-runtime"' "$SWF_CFG_BACKUP" > "$SWF_CONFIG"
SWF_OUT="$(swf_doctor --json)"
SWF_RC=$?
if [ "$(swf_status "$SWF_OUT" "runtime.codex")" = "ERROR" ] && [ "$SWF_RC" -ne 0 ]; then
  pass "doctor: a runtime program that is not on PATH is an ERROR"
else
  fail "doctor: a runtime program that is not on PATH is an ERROR" "$(swf_status "$SWF_OUT" "runtime.codex")"
fi
cp "$SWF_CFG_BACKUP" "$SWF_CONFIG"

# Defect 3: workspace-doctor.sh header/comments claimed "STRICTLY READ-ONLY"
# and that an arbitrary runtime key "never causes its program to be
# executed here", but check_runtimes ran "$program" --version -- fully
# config-controlled and ungated (only the runtime *key* is a case-matched
# literal). Prove the fix: point runtimes.claude.program at a script that
# creates a marker file if executed, run doctor, and assert the marker was
# NOT created.
SWF_RUNTIME_MARKER="$SWF/runtime-marker-executed"
rm -f "$SWF_RUNTIME_MARKER"
cat > "$SWF_BIN/marker-runtime" <<EOF
#!/usr/bin/env bash
touch "$SWF_RUNTIME_MARKER"
echo "marker-runtime-stub 1.0.0"
EOF
chmod +x "$SWF_BIN/marker-runtime"
jq '.runtimes.claude.program = "marker-runtime"' "$SWF_CFG_BACKUP" > "$SWF_CONFIG"
SWF_OUT="$(swf_doctor --json)"
SWF_RC=$?
if [ ! -e "$SWF_RUNTIME_MARKER" ] && [ "$(swf_status "$SWF_OUT" "runtime.claude")" = "OK" ] &&
   [ "$SWF_RC" -eq 0 ] &&
   ! printf '%s' "$SWF_OUT" | jq -e '.checks[] | select(.id == "runtime.claude") | .message | test("stub")' >/dev/null 2>&1; then
  pass "doctor: a runtime program is resolved via command -v only, never executed (no marker file, no version)"
else
  fail "doctor: a runtime program is resolved via command -v only, never executed (no marker file, no version)" \
    "marker_exists=$([ -e "$SWF_RUNTIME_MARKER" ] && echo yes || echo no) status=$(swf_status "$SWF_OUT" "runtime.claude") rc=$SWF_RC out=$SWF_OUT"
fi
rm -f "$SWF_RUNTIME_MARKER" "$SWF_BIN/marker-runtime"
cp "$SWF_CFG_BACKUP" "$SWF_CONFIG"

# --- F10b: every post-config check is skipped when validation fails --------
# A config-validity failure unrelated to any single post-config check (a
# duplicate pane name), to prove the gating is general -- not merely a
# side-effect of the same root cause tripping two checks at once.
jq '.sessions[0].panes[1].name = .sessions[0].panes[0].name' "$SWF_CFG_BACKUP" > "$SWF_CONFIG"
SWF_OUT="$(swf_doctor --json)"
SWF_RC=$?
SWF_GATE_OK=1
if [ "$(swf_status "$SWF_OUT" "config.validation")" != "ERROR" ] || [ "$SWF_RC" -eq 0 ]; then
  SWF_GATE_OK=0
fi
for swf_gated_id in panes.cwd secrets.env_file state.dir runtime.claude runtime.codex \
                    stores.drift integrations.session_chat_helper; do
  if [ -n "$(swf_status "$SWF_OUT" "$swf_gated_id")" ]; then
    SWF_GATE_OK=0
  fi
done
if [ "$SWF_GATE_OK" -eq 1 ]; then
  pass "doctor: every post-config check is skipped when config.validation fails"
else
  fail "doctor: every post-config check is skipped when config.validation fails" "$SWF_OUT"
fi
cp "$SWF_CFG_BACKUP" "$SWF_CONFIG"

# --- F11: coordination-base drift ------------------------------------------
mkdir -p "$SWF_PROJECT/tmp/scheduler" "$SWF_PROJECT/tmp/messages"
printf '{}\n' > "$SWF_PROJECT/tmp/scheduler/task-0001.json"
printf '{}\n' > "$SWF_PROJECT/tmp/messages/msg-0001.json"
SWF_OUT="$(swf_doctor --json)"
SWF_RC=$?
if [ "$(swf_status "$SWF_OUT" "stores.drift")" = "WARN" ] && [ "$SWF_RC" -eq 0 ] &&
   printf '%s' "$SWF_OUT" | grep -q "tmp/scheduler"; then
  pass "doctor: ledger files under a non-configured coordination base are a WARN (exit still 0)"
else
  fail "doctor: ledger files under a non-configured coordination base are a WARN (exit still 0)" \
    "rc=$SWF_RC status=$(swf_status "$SWF_OUT" "stores.drift")"
fi
# The same files under the CONFIGURED base are not drift.
rm -rf "$SWF_PROJECT/tmp"
mkdir -p "$SWF_PROJECT/.tmp/scheduler"
printf '{}\n' > "$SWF_PROJECT/.tmp/scheduler/task-0001.json"
SWF_OUT="$(swf_doctor --json)"
if [ "$(swf_status "$SWF_OUT" "stores.drift")" = "OK" ]; then
  pass "doctor: ledger files under the CONFIGURED coordination base are not drift"
else
  fail "doctor: ledger files under the CONFIGURED coordination base are not drift" "$(swf_status "$SWF_OUT" "stores.drift")"
fi
rm -rf "$SWF_PROJECT/.tmp"

# A lone .gitkeep (or .DS_Store) under a non-configured base is not
# "ledger-shaped" -- it must not trigger a WARN (the header/message both
# claim "ledger-shaped" filtering; the un-filtered `find -type f` used to
# count it anyway, producing a permanent false WARN for a committed
# .gitkeep).
mkdir -p "$SWF_PROJECT/tmp/scheduler"
: > "$SWF_PROJECT/tmp/scheduler/.gitkeep"
SWF_OUT="$(swf_doctor --json)"
if [ "$(swf_status "$SWF_OUT" "stores.drift")" = "OK" ]; then
  pass "doctor: a lone .gitkeep under a non-configured base does not trigger drift WARN"
else
  fail "doctor: a lone .gitkeep under a non-configured base does not trigger drift WARN" \
    "$(swf_status "$SWF_OUT" "stores.drift")"
fi
rm -rf "$SWF_PROJECT/tmp"

# stores.base="./.tmp" must normalize the same as ".tmp" -- a real ledger
# file under .tmp/ must NOT false-positive as drift just because the
# configured value carries a "./" prefix.
jq '.stores.base = "./.tmp"' "$SWF_CFG_BACKUP" > "$SWF_CONFIG"
mkdir -p "$SWF_PROJECT/.tmp/scheduler"
printf '{}\n' > "$SWF_PROJECT/.tmp/scheduler/task-0001.json"
SWF_OUT="$(swf_doctor --json)"
if [ "$(swf_status "$SWF_OUT" "stores.drift")" = "OK" ]; then
  pass "doctor: stores.base \"./.tmp\" normalizes the same as \".tmp\" (no false-positive drift)"
else
  fail "doctor: stores.base \"./.tmp\" normalizes the same as \".tmp\" (no false-positive drift)" \
    "$(swf_status "$SWF_OUT" "stores.drift")"
fi
rm -rf "$SWF_PROJECT/.tmp"
cp "$SWF_CFG_BACKUP" "$SWF_CONFIG"

# A store whose stores.overrides entry already points AT the candidate base
# is not drift either -- it is exactly where the project deliberately
# pointed it.
jq '.stores.overrides = {"scheduler": "tmp/scheduler"}' "$SWF_CFG_BACKUP" > "$SWF_CONFIG"
mkdir -p "$SWF_PROJECT/tmp/scheduler"
printf '{}\n' > "$SWF_PROJECT/tmp/scheduler/task-0001.json"
SWF_OUT="$(swf_doctor --json)"
if [ "$(swf_status "$SWF_OUT" "stores.drift")" = "OK" ]; then
  pass "doctor: a store overridden to point at the candidate base is not drift"
else
  fail "doctor: a store overridden to point at the candidate base is not drift" \
    "$(swf_status "$SWF_OUT" "stores.drift")"
fi
rm -rf "$SWF_PROJECT/tmp"
cp "$SWF_CFG_BACKUP" "$SWF_CONFIG"

# --- F12: session-chat helper resolution ------------------------------------
rm -rf "$SWF_HOME/.claude/plugins/cache/mkt/session-chat" "$SWF_SRC/session-chat"
SWF_OUT="$(swf_doctor --json)"
SWF_RC=$?
if [ "$(swf_status "$SWF_OUT" "integrations.session_chat_helper")" = "ERROR" ] && [ "$SWF_RC" -ne 0 ]; then
  pass "doctor: an unresolvable session-chat helper with on_missing=fail is an ERROR"
else
  fail "doctor: an unresolvable session-chat helper with on_missing=fail is an ERROR" \
    "$(swf_status "$SWF_OUT" "integrations.session_chat_helper")"
fi
jq '.behavior.session_chat_helper.on_missing = "warn"' "$SWF_CFG_BACKUP" > "$SWF_CONFIG"
SWF_OUT="$(swf_doctor --json)"
if [ "$(swf_status "$SWF_OUT" "integrations.session_chat_helper")" = "WARN" ]; then
  pass "doctor: an unresolvable session-chat helper with on_missing=warn is a WARN"
else
  fail "doctor: an unresolvable session-chat helper with on_missing=warn is a WARN" \
    "$(swf_status "$SWF_OUT" "integrations.session_chat_helper")"
fi
cp "$SWF_CFG_BACKUP" "$SWF_CONFIG"
swf_reset_deps 0.3.2 0.17.0 0.5.0

# --- F13: config discovery + validation failures ---------------------------
printf '{ this is not json' > "$SWF_CONFIG"
SWF_OUT="$(swf_doctor --json)"
SWF_RC=$?
if [ "$SWF_RC" -ne 0 ] && [ "$(swf_status "$SWF_OUT" "config.validation")" = "ERROR" ]; then
  pass "doctor: an unparseable config is a config.validation ERROR"
else
  fail "doctor: an unparseable config is a config.validation ERROR" "rc=$SWF_RC $SWF_OUT"
fi
jq '.sessions[0].panes[1].name = .sessions[0].panes[0].name' "$SWF_CFG_BACKUP" > "$SWF_CONFIG"
SWF_OUT="$(swf_doctor --json)"
SWF_RC=$?
if [ "$SWF_RC" -ne 0 ] && [ "$(swf_status "$SWF_OUT" "config.validation")" = "ERROR" ] &&
   printf '%s' "$SWF_OUT" | jq -e '[.checks[] | select(.id == "config.validation") | .details[]] | length > 0' >/dev/null 2>&1; then
  pass "doctor: every validate-config.sh error is surfaced in the report details"
else
  fail "doctor: every validate-config.sh error is surfaced in the report details" "$SWF_OUT"
fi
cp "$SWF_CFG_BACKUP" "$SWF_CONFIG"
SWF_OUT="$(env -u TMUX -u SESSION_WORKSPACE_CONFIG HOME="$SWF_HOME" XDG_STATE_HOME="$SWF_STATE" \
  SESSION_WORKSPACE_SOURCE_TREE_DIR="$SWF_SRC" PATH="$SWF_BIN" \
  bash "$HERE/workspace-doctor.sh" --config "$SWF/nope.json" --json 2>&1)"
SWF_RC=$?
if [ "$SWF_RC" -ne 0 ] && [ "$(swf_status "$SWF_OUT" "config.discovery")" = "ERROR" ]; then
  pass "doctor: a --config path that does not exist is a config.discovery ERROR"
else
  fail "doctor: a --config path that does not exist is a config.discovery ERROR" "rc=$SWF_RC $SWF_OUT"
fi

# --- F14: dispatcher parity -------------------------------------------------
SWF_DISPATCH="$(env -u TMUX -u SESSION_WORKSPACE_CONFIG HOME="$SWF_HOME" XDG_STATE_HOME="$SWF_STATE" \
  SESSION_WORKSPACE_SOURCE_TREE_DIR="$SWF_SRC" PATH="$SWF_BIN" \
  bash "$HERE/workspace.sh" doctor --config "$SWF_CONFIG" --json 2>&1)"
SWF_DIRECT="$(swf_doctor --json)"
if [ "$SWF_DISPATCH" = "$SWF_DIRECT" ]; then
  pass "doctor: 'workspace.sh doctor' and workspace-doctor.sh agree exactly"
else
  fail "doctor: 'workspace.sh doctor' and workspace-doctor.sh agree exactly" "outputs differ"
fi

# --- F15: no tmux server is ever contacted ---------------------------------
# The doctor must only ever run `tmux -V`. A stub tmux logs every invocation;
# anything beyond `-V` would mean the doctor could touch a live server.
SWF_BIN_LOGTMUX="$SWF/bin-log-tmux"
swf_make_bin "$SWF_BIN_LOGTMUX" tmux
SWF_TMUX_LOG="$SWF/tmux-calls.log"
: > "$SWF_TMUX_LOG"
cat > "$SWF_BIN_LOGTMUX/tmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SWF_TMUX_LOG"
echo "tmux 3.6b"
EOF
chmod +x "$SWF_BIN_LOGTMUX/tmux"
SWF_BIN="$SWF_BIN_LOGTMUX"
swf_doctor >/dev/null 2>&1
SWF_BIN="$SWF_BIN_SAVED"
if [ "$(sort -u "$SWF_TMUX_LOG" | tr -d '[:space:]')" = "-V" ]; then
  pass "doctor: the only tmux call it ever makes is 'tmux -V'"
else
  fail "doctor: the only tmux call it ever makes is 'tmux -V'" "$(cat "$SWF_TMUX_LOG")"
fi

echo "== browser integration =="
BROWSER_PLAN="$(HOME="$TMPROOT/browser-home" bash "$HERE/workspace-plan.sh" --config "$HERE/fixtures/valid/browser.json" --json 2>&1)"
if printf '%s' "$BROWSER_PLAN" | jq -e '
  .browser.port == 9324 and
  .browser.profile_dir == "'"$TMPROOT"'/browser-home/.cache/session-workspace/chrome/sample-browser" and
  (.sessions[0].panes[0].command == ["true","--remote-debugging-address=127.0.0.1","--remote-debugging-port=9324","--user-data-dir='"$TMPROOT"'/browser-home/.cache/session-workspace/chrome/sample-browser","--no-first-run","--no-default-browser-check"])
' >/dev/null 2>&1; then
  pass "browser: plan derives loopback Chrome argv, port, and isolated profile"
else
  fail "browser: plan derives loopback Chrome argv, port, and isolated profile" "$BROWSER_PLAN"
fi

# 0.5.1 backward compatibility: a one-pane browser session that omits
# browser.pane_name still binds its sole pane, and the plan now echoes the
# concrete (interpolated) selection so every consumer keys on one identity.
if printf '%s' "$BROWSER_PLAN" | jq -e '
  .browser.pane_name == "sample-browser-chrome-devtools" and
  .sessions[0].panes[0].browser == true and
  .sessions[0].panes[0].port == 9324
' >/dev/null 2>&1; then
  pass "browser: legacy one-pane config (no pane_name) resolves browser.pane_name to its sole pane"
else
  fail "browser: legacy one-pane config (no pane_name) resolves browser.pane_name to its sole pane" "$BROWSER_PLAN"
fi

# Shared session: only the pane named by browser.pane_name receives the
# derived Chrome argv / browser.port / browser=true. Siblings keep their own
# command and port untouched and are never marked as the browser.
BROWSER_MULTI_PLAN="$(HOME="$TMPROOT/browser-home" bash "$HERE/workspace-plan.sh" --config "$HERE/fixtures/valid/browser-multipane.json" --json 2>&1)"
if printf '%s' "$BROWSER_MULTI_PLAN" | jq -e '
  .browser.session_id == "services" and
  .browser.pane_name == "sample-browser-multi-browser" and
  .browser.port == 9325 and
  (.sessions[0].panes | length) == 3 and
  .sessions[0].panes[1].name == "sample-browser-multi-browser" and
  .sessions[0].panes[1].browser == true and
  .sessions[0].panes[1].port == 9325 and
  (.sessions[0].panes[1].command == ["true","--remote-debugging-address=127.0.0.1","--remote-debugging-port=9325","--user-data-dir='"$TMPROOT"'/browser-home/.cache/session-workspace/chrome/sample-browser-multi","--no-first-run","--no-default-browser-check"]) and
  .sessions[0].panes[0].browser == false and
  .sessions[0].panes[0].command == null and
  .sessions[0].panes[0].port == null and
  .sessions[0].panes[2].browser == false and
  (.sessions[0].panes[2].command == ["true","--sibling"]) and
  .sessions[0].panes[2].port == 3001 and
  ([.sessions[0].panes[] | select(.browser == true)] | length) == 1
' >/dev/null 2>&1; then
  pass "browser: multi-pane session binds Chrome argv/port/browser=true to browser.pane_name only; siblings keep command/port"
else
  fail "browser: multi-pane session binds Chrome argv/port/browser=true to browser.pane_name only; siblings keep command/port" "$BROWSER_MULTI_PLAN"
fi

BROWSER_BAD="$(bash "$HERE/workspace-plan.sh" --config "$HERE/fixtures/invalid/browser-latest-package.json" --json 2>&1)"
BROWSER_BAD_RC=$?
if [ "$BROWSER_BAD_RC" -ne 0 ] && printf '%s' "$BROWSER_BAD" | grep -Fq 'must pin an exact version'; then
  pass "browser: floating chrome-devtools-mcp@latest is rejected"
else
  fail "browser: floating chrome-devtools-mcp@latest is rejected" "rc=$BROWSER_BAD_RC $BROWSER_BAD"
fi

BROWSER_PROJECT="$TMPROOT/browser-project"
mkdir -p "$BROWSER_PROJECT/.agent-workspace"
cp "$HERE/fixtures/valid/browser.json" "$BROWSER_PROJECT/.agent-workspace/workspace.json"
BROWSER_RENDER="$(bash "$HERE/workspace-browser-config.sh" --config "$BROWSER_PROJECT/.agent-workspace/workspace.json" --json 2>&1)"
if printf '%s' "$BROWSER_RENDER" | jq -e '
  .codex.block | contains("chrome-devtools-mcp@1.2.3") and contains("--browser-url=http://127.0.0.1:9324")
' >/dev/null 2>&1; then
  pass "browser-config: dry run renders pinned Codex and Claude MCP entries"
else
  fail "browser-config: dry run renders pinned Codex and Claude MCP entries" "$BROWSER_RENDER"
fi

BROWSER_APPLY="$(bash "$HERE/workspace.sh" browser-config --config "$BROWSER_PROJECT/.agent-workspace/workspace.json" --apply 2>&1)"
BROWSER_APPLY_RC=$?
if [ "$BROWSER_APPLY_RC" -eq 0 ] &&
   grep -Fq '[mcp_servers.chrome-devtools]' "$BROWSER_PROJECT/.codex/config.toml" &&
   jq -e '.mcpServers["chrome-devtools"].args[2] == "--browser-url=http://127.0.0.1:9324"' "$BROWSER_PROJECT/.mcp.json" >/dev/null 2>&1; then
  pass "browser-config: explicit apply writes both project MCP configurations"
else
  fail "browser-config: explicit apply writes both project MCP configurations" "rc=$BROWSER_APPLY_RC $BROWSER_APPLY"
fi

BROWSER_BEFORE="$(cksum "$BROWSER_PROJECT/.codex/config.toml" "$BROWSER_PROJECT/.mcp.json")"
bash "$HERE/workspace-browser-config.sh" --config "$BROWSER_PROJECT/.agent-workspace/workspace.json" --apply >/dev/null 2>&1
BROWSER_AFTER="$(cksum "$BROWSER_PROJECT/.codex/config.toml" "$BROWSER_PROJECT/.mcp.json")"
if [ "$BROWSER_BEFORE" = "$BROWSER_AFTER" ]; then
  pass "browser-config: repeated apply is content-idempotent"
else
  fail "browser-config: repeated apply is content-idempotent" "before=$BROWSER_BEFORE after=$BROWSER_AFTER"
fi

jq '.mcpServers["chrome-devtools"].args[1] = "different-package@9.9.9"' \
  "$BROWSER_PROJECT/.mcp.json" >"$BROWSER_PROJECT/.mcp.json.changed"
mv "$BROWSER_PROJECT/.mcp.json.changed" "$BROWSER_PROJECT/.mcp.json"
BROWSER_CODEX_BEFORE="$(cksum "$BROWSER_PROJECT/.codex/config.toml")"
BROWSER_CONFLICT="$(bash "$HERE/workspace-browser-config.sh" --config "$BROWSER_PROJECT/.agent-workspace/workspace.json" --apply 2>&1)"
BROWSER_CONFLICT_RC=$?
BROWSER_CODEX_AFTER="$(cksum "$BROWSER_PROJECT/.codex/config.toml")"
if [ "$BROWSER_CONFLICT_RC" -ne 0 ] && [ "$BROWSER_CODEX_BEFORE" = "$BROWSER_CODEX_AFTER" ] &&
   printf '%s' "$BROWSER_CONFLICT" | grep -Fq 'different unmanaged'; then
  pass "browser-config: all-provider apply preflights conflicts and makes no partial Codex write"
else
  fail "browser-config: all-provider apply preflights conflicts and makes no partial Codex write" "rc=$BROWSER_CONFLICT_RC $BROWSER_CONFLICT"
fi

echo
echo "-----------------------------------------------"
echo "session-workspace tests: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  echo
  echo "Failures:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
exit 0
