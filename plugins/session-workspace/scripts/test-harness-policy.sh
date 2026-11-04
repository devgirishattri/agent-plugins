#!/usr/bin/env bash
# test-harness-policy.sh — focused strict-v1 policy tests for harness-policy.py.
# Synthetic only: a temp project, fake provider homes (never the real
# ~/.claude or ~/.codex), no tmux, no adopter repo. Every decision is read
# through --decision-json so both provider trees can assert the identical
# normalized object.
#
# Covered contract (see harness-policy.py's header for the decision shape):
#   - inactive no-op: no env, schema v1, v2 enabled=false, unreadable config
#     with no launcher mode
#   - identity fail-closed: forged role, unknown pane, cwd/root mismatch,
#     missing identity, alias disagreement, config/mode drift, invalid config
#   - tool classification by NAME: Read/Grep/unknown tools allowed for every
#     role; edit tools gated; argv-list (Codex-shaped) shell commands
#   - all three roles: reviewer read-only + coordination exception, executor
#     cwd containment (path + symlink escape), orchestrator child-root floor
#   - trusted helpers: exact selected provenance on BOTH provider caches,
#     literal argv grammar, stale/unselected version, symlink, traversal,
#     wrapper/prefix/composition/expansion rejection, unknown basename
#   - child routing: recipient must be the orchestrator; direct tmux
#     transport and copied/relative outbound helpers are denied
#   - audit vs enforce, hook exit codes, and a byte-stable decision object
#
# Usage: bash test-harness-policy.sh
#   HARNESS_TEST_PYTHON=/usr/bin/python3 runs the suite under another interpreter.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
POLICY="${HARNESS_TEST_POLICY:-$HERE/harness-policy.py}"
PY="${HARNESS_TEST_PYTHON:-python3}"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/session-workspace-harness-test.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT
TMPROOT="$(cd "$TMPROOT" && pwd -P)"

PASS=0
FAIL=0
FAILURES=()
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1: $2"); printf '  FAIL  %s — %s\n' "$1" "$2"; }

# --- project fixture ---------------------------------------------------------
ROOT="$TMPROOT/project"
mkdir -p "$ROOT/.agent-workspace" "$ROOT/component-a/src" "$ROOT/component-b" "$ROOT/.agents/memory"
CONFIG="$ROOT/.agent-workspace/workspace.json"
cp "$HERE/fixtures/valid/harness-v2.json" "$CONFIG"
AUDIT_CONFIG="$ROOT/.agent-workspace/audit.json"
jq '.harness.mode = "audit"' "$CONFIG" > "$AUDIT_CONFIG"
OFF_CONFIG="$ROOT/.agent-workspace/off.json"
jq '.harness = {"enabled":false}' "$CONFIG" > "$OFF_CONFIG"
V1_CONFIG="$ROOT/.agent-workspace/v1.json"
jq 'del(.harness) | .schema_version = 1' "$CONFIG" > "$V1_CONFIG"
INVALID_CONFIG="$ROOT/.agent-workspace/invalid.json"
jq '.harness.roles.reviewer = "missing"' "$CONFIG" > "$INVALID_CONFIG"
BROKEN_CONFIG="$ROOT/.agent-workspace/broken.json"
printf '{not json' > "$BROKEN_CONFIG"
V3_CONFIG="$ROOT/.agent-workspace/v3.json"
jq '.schema_version = 3 | .harness.guards = {
  protected_files:{profile:"credentials-lockfiles-v1",extra_basenames:["custom-secret.json"]},
  orchestrator:{deny_child_chdir:true}
}' "$CONFIG" > "$V3_CONFIG"
V3_GUARDS="$(jq -cS '.harness.guards' "$V3_CONFIG")"
V3_COMPAT_CONFIG="$ROOT/.agent-workspace/v3-compat.json"
jq '.schema_version = 3' "$CONFIG" > "$V3_COMPAT_CONFIG"
V4_COMPAT_CONFIG="$ROOT/.agent-workspace/v4-compat.json"
jq '.schema_version = 4' "$CONFIG" > "$V4_COMPAT_CONFIG"
printf 'hello\n' > "$ROOT/component-a/README.md"
printf 'root\n' > "$ROOT/AGENTS.md"
ln -s "$ROOT/component-b" "$ROOT/component-a/escape-link"

MASTER_PANE=harness-sample-master
EXEC_PANE=harness-sample-component-executor
REVIEW_PANE=harness-sample-component-reviewer
CHILD="$ROOT/component-a"

# --- fake provider homes -----------------------------------------------------
FAKE_CLAUDE="$TMPROOT/claude-home"
FAKE_CODEX="$TMPROOT/codex-home"
mkdir -p "$FAKE_CLAUDE/plugins/cache/girishattri-plugins" "$FAKE_CLAUDE/messages" \
  "$FAKE_CODEX/plugins/cache/girishattri-plugins" "$FAKE_CODEX/messages" \
  "$FAKE_CODEX/.tmp/marketplaces/girishattri-plugins/codex/plugins"

make_helper_tree() {
  # make_helper_tree HOME plugin version script...
  local home="$1" plugin="$2" version="$3" dir
  shift 3
  dir="$home/plugins/cache/girishattri-plugins/$plugin/$version/scripts"
  mkdir -p "$dir"
  local helper
  for helper in "$@"; do
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/$helper"
    chmod 644 "$dir/$helper"
  done
}
CHAT_HELPERS="send-message.sh dispatch-to-session.sh check-replies.sh list-panes.sh pane-health.sh get-my-name.sh messages-list.sh message-search.sh broadcast-message.sh"
SCHED_HELPERS="task-status.sh task-board.sh task-review.sh task-done.sh task-block.sh task-new.sh task-assign.sh tasks-clean.sh scheduler-doctor.sh task-contract.sh"
KNOW_HELPERS="save-context.sh load-context.sh list-contexts.sh share-context.sh search-contexts.sh memory-search.sh memory-remember.sh docs-write.sh doctor.sh memory-lint.sh memory-backlinks.sh memory-write.sh memory-index.sh init.sh remove-context.sh memory-auto-capture.sh validate-links.sh check-todos.sh check-freshness.sh"
WS_HELPERS="workspace.sh workspace-plan.sh workspace-status.sh harness-status.sh workspace-start.sh workspace-stop.sh workspace-restart.sh workspace-reconcile.sh workspace-install.sh workspace-browser-config.sh"
SM_HELPERS="list-sessions.sh search-sessions.sh session-stats.sh delete-session.sh delete-all-sessions.sh find-or-skip.sh"
# shellcheck disable=SC2086
make_helper_tree "$FAKE_CLAUDE" session-chat 1.2.3 $CHAT_HELPERS
# shellcheck disable=SC2086
make_helper_tree "$FAKE_CLAUDE" session-chat 0.9.0 $CHAT_HELPERS
# shellcheck disable=SC2086
make_helper_tree "$FAKE_CLAUDE" session-scheduler 4.5.6 $SCHED_HELPERS
# shellcheck disable=SC2086
make_helper_tree "$FAKE_CLAUDE" knowledge 7.8.9 $KNOW_HELPERS
# shellcheck disable=SC2086
make_helper_tree "$FAKE_CLAUDE" session-workspace 3.0.0 $WS_HELPERS
# shellcheck disable=SC2086
make_helper_tree "$FAKE_CLAUDE" session-manager 2.2.2 $SM_HELPERS
# shellcheck disable=SC2086
make_helper_tree "$FAKE_CLAUDE" unlisted-plugin 1.0.0 mystery.sh
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$FAKE_CLAUDE/plugins/cache/girishattri-plugins/session-chat/1.2.3/scripts/rogue.sh"
# shellcheck disable=SC2086
make_helper_tree "$FAKE_CODEX" session-chat 2.0.0 $CHAT_HELPERS
# shellcheck disable=SC2086
make_helper_tree "$FAKE_CODEX" session-chat 1.0.0 $CHAT_HELPERS
# Symlinked version dir and symlinked script inside the Claude cache.
ln -s "$FAKE_CLAUDE/plugins/cache/girishattri-plugins/session-chat/1.2.3" "$FAKE_CLAUDE/plugins/cache/girishattri-plugins/session-chat/link"
ln -s "$FAKE_CLAUDE/plugins/cache/girishattri-plugins/session-chat/1.2.3/scripts/send-message.sh" "$FAKE_CLAUDE/plugins/cache/girishattri-plugins/session-chat/1.2.3/scripts/send-link.sh"
printf 'dispatch body\n' > "$FAKE_CLAUDE/messages/task.md"
printf 'candidate\n' > "$TMPROOT/candidate.md"

CLAUDE_CACHE="$FAKE_CLAUDE/plugins/cache/girishattri-plugins"
CODEX_CACHE="$FAKE_CODEX/plugins/cache/girishattri-plugins"
jq -n --arg cache "$CLAUDE_CACHE" --arg other "$TMPROOT/other-project" '{
  version: 2,
  plugins: {
    "session-chat@girishattri-plugins": [
      {scope: "user", projectPath: null, installPath: ($cache + "/session-chat/1.2.3"), version: "1.2.3"}
    ],
    "session-scheduler@girishattri-plugins": [
      {scope: "user", projectPath: null, installPath: ($cache + "/session-scheduler/4.5.6"), version: "4.5.6"}
    ],
    "knowledge@girishattri-plugins": [
      {scope: "user", projectPath: null, installPath: ($cache + "/knowledge/7.8.9"), version: "7.8.9"}
    ],
    "session-workspace@girishattri-plugins": [
      {scope: "user", projectPath: null, installPath: ($cache + "/session-workspace/3.0.0"), version: "3.0.0"}
    ],
    "session-manager@girishattri-plugins": [
      {scope: "user", projectPath: null, installPath: ($cache + "/session-manager/2.2.2"), version: "2.2.2"}
    ],
    "unlisted-plugin@girishattri-plugins": [
      {scope: "local", projectPath: $other, installPath: ($cache + "/unlisted-plugin/1.0.0"), version: "1.0.0"}
    ]
  }
}' > "$FAKE_CLAUDE/plugins/installed_plugins.json"
printf '%s\n' '[plugins."session-chat@girishattri-plugins"]' 'enabled = true' > "$FAKE_CODEX/config.toml"
mkdir -p "$FAKE_CODEX/.tmp/marketplaces/girishattri-plugins/codex/plugins/session-chat/.codex-plugin"
printf '%s\n' '{"name":"session-chat","version":"2.0.0"}' > \
  "$FAKE_CODEX/.tmp/marketplaces/girishattri-plugins/codex/plugins/session-chat/.codex-plugin/plugin.json"

SEND="$CLAUDE_CACHE/session-chat/1.2.3/scripts/send-message.sh"
DISPATCH="$CLAUDE_CACHE/session-chat/1.2.3/scripts/dispatch-to-session.sh"
STALE_SEND="$CLAUDE_CACHE/session-chat/0.9.0/scripts/send-message.sh"
SCHED="$CLAUDE_CACHE/session-scheduler/4.5.6/scripts"
KNOW="$CLAUDE_CACHE/knowledge/7.8.9/scripts"
WS="$CLAUDE_CACHE/session-workspace/3.0.0/scripts"
SM="$CLAUDE_CACHE/session-manager/2.2.2/scripts"
CODEX_SEND="$CODEX_CACHE/session-chat/2.0.0/scripts/send-message.sh"
CODEX_STALE_SEND="$CODEX_CACHE/session-chat/1.0.0/scripts/send-message.sh"

# --- runner --------------------------------------------------------------------
# run_policy ROLE PANE CWD CONFIG MODE PAYLOAD [extra env assignments...]
run_policy() {
  local role="$1" pane="$2" cwd="$3" config="$4" mode="$5" payload="$6"
  shift 6
  printf '%s' "$payload" | env \
    -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME \
    -u SESSION_CHAT_TARGET_MESSAGES_DIR -u SESSION_SCHEDULER_HOME -u SESSION_CONTEXT_HOME \
    SESSION_WORKSPACE_CONFIG="$config" \
    SESSION_WORKSPACE_PROJECT_ROOT="$ROOT" \
    SESSION_WORKSPACE_PANE_NAME="$pane" \
    SESSION_WORKSPACE_ROLE="$role" \
    SESSION_WORKSPACE_PANE_CWD="$cwd" \
    SESSION_WORKSPACE_HARNESS_MODE="$mode" \
    CLAUDE_HOME="$FAKE_CLAUDE" \
    CODEX_HOME="$FAKE_CODEX" \
    "$@" \
    "$PY" "$POLICY" --decision-json
}

# Same normalized decision path with the Codex rendering flag present. The
# flag may only affect hook-mode presentation, never the Decision object.
run_policy_codex_decision() {
  local role="$1" pane="$2" cwd="$3" config="$4" mode="$5" payload="$6"
  printf '%s' "$payload" | env \
    -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME \
    -u SESSION_CHAT_TARGET_MESSAGES_DIR -u SESSION_SCHEDULER_HOME -u SESSION_CONTEXT_HOME \
    SESSION_WORKSPACE_CONFIG="$config" \
    SESSION_WORKSPACE_PROJECT_ROOT="$ROOT" \
    SESSION_WORKSPACE_PANE_NAME="$pane" \
    SESSION_WORKSPACE_ROLE="$role" \
    SESSION_WORKSPACE_PANE_CWD="$cwd" \
    SESSION_WORKSPACE_HARNESS_MODE="$mode" \
    CLAUDE_HOME="$FAKE_CLAUDE" \
    CODEX_HOME="$FAKE_CODEX" \
    "$PY" "$POLICY" --codex-hook-output --decision-json
}

bash_payload() { jq -cn --arg command "$1" '{tool_name:"Bash",tool_input:{command:$command}}'; }
codex_bash_payload() {
  jq -cn --arg command "$1" --arg cwd "$CHILD" '{
    session_id:"00000000-0000-0000-0000-000000000000",
    turn_id:"turn-canary",
    cwd:$cwd,
    hook_event_name:"PreToolUse",
    model:"gpt-test",
    permission_mode:"workspace-write",
    tool_name:"Bash",
    tool_input:{command:$command},
    tool_use_id:"call-canary"
  }'
}
edit_payload() { jq -cn --arg path "$1" '{tool_name:"Edit",tool_input:{file_path:$path,old_string:"a",new_string:"b"}}'; }

# expect LABEL ROLE PANE CWD CONFIG MODE PAYLOAD JQ_EXPR [extra env...]
expect() {
  local label="$1" role="$2" pane="$3" cwd="$4" config="$5" mode="$6" payload="$7" expression="$8"
  shift 8
  local out
  out="$(run_policy "$role" "$pane" "$cwd" "$config" "$mode" "$payload" "$@" 2>&1)"
  if printf '%s' "$out" | jq -e "$expression" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label" "$out"
  fi
}
# Convenience wrappers per role in enforce mode against the golden config.
as_exec()   { expect "$1" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$2" "$3"; }
as_review() { expect "$1" reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$2" "$3"; }
as_master() { expect "$1" master "$MASTER_PANE" "$ROOT" "$CONFIG" enforce "$2" "$3"; }
as_master_v3() { expect "$1" master "$MASTER_PANE" "$ROOT" "$V3_CONFIG" enforce "$2" "$3" SESSION_WORKSPACE_GUARDS_JSON="$V3_GUARDS"; }
as_exec_v3() { expect "$1" executor "$EXEC_PANE" "$CHILD" "$V3_CONFIG" enforce "$2" "$3" SESSION_WORKSPACE_GUARDS_JSON="$V3_GUARDS"; }

echo "== decision object shape =="
OUT="$(run_policy reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(edit_payload src/file.ts)")"
if printf '%s' "$OUT" | jq -e 'keys == ["active","decision","diagnostic","mode","pane","profile","reason","role","rule","tool"]' >/dev/null 2>&1; then
  pass "decision JSON has exactly the fixed sorted key set"
else
  fail "decision JSON has exactly the fixed sorted key set" "$OUT"
fi
EXPECT_JSON="$(jq -cn --arg pane "$REVIEW_PANE" '{active:true,decision:"deny",mode:"enforce",pane:$pane,profile:"strict-v1",reason:"reviewer panes cannot edit, write, patch, move, or delete files",role:"reviewer",rule:"reviewer.readonly",tool:"Edit"}')"
if [ "$(printf '%s' "$OUT" | jq -cS 'del(.diagnostic)')" = "$EXPECT_JSON" ] && printf '%s' "$OUT" | jq -e '.diagnostic.schema == "diag/1" and .diagnostic.reason == "hook.reviewer.readonly"' >/dev/null 2>&1; then
  pass "decision JSON is byte-stable (compact, sorted keys)"
else
  fail "decision JSON is byte-stable (compact, sorted keys)" "got=$OUT want=$EXPECT_JSON"
fi
OUT2="$(run_policy reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(edit_payload src/file.ts)")"
if [ "$OUT" = "$OUT2" ]; then
  pass "decision JSON is deterministic across runs"
else
  fail "decision JSON is deterministic across runs" "$OUT vs $OUT2"
fi
V3_COMPAT_DECISION="$(run_policy executor "$EXEC_PANE" "$CHILD" "$V3_COMPAT_CONFIG" enforce "$(bash_payload 'git status')")"
V4_COMPAT_DECISION="$(run_policy executor "$EXEC_PANE" "$CHILD" "$V4_COMPAT_CONFIG" enforce "$(bash_payload 'git status')")"
if [ "$V3_COMPAT_DECISION" = "$V4_COMPAT_DECISION" ]; then
  pass "schema v4 without orchestration produces byte-identical policy decision to v3"
else
  fail "schema v4 without orchestration produces byte-identical policy decision to v3" "v3=$V3_COMPAT_DECISION v4=$V4_COMPAT_DECISION"
fi

assert_rendering_decision_parity() {
  local label="$1" role="$2" pane="$3" cwd="$4" config="$5" mode="$6" payload="$7" plain codex
  plain="$(run_policy "$role" "$pane" "$cwd" "$config" "$mode" "$payload")"
  codex="$(run_policy_codex_decision "$role" "$pane" "$cwd" "$config" "$mode" "$payload")"
  if [ "$plain" = "$codex" ]; then
    pass "$label"
  else
    fail "$label" "plain=$plain codex=$codex"
  fi
}
assert_rendering_decision_parity "Codex rendering flag preserves allow decision JSON byte-for-byte" reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(bash_payload 'git status')"
assert_rendering_decision_parity "Codex rendering flag preserves audit decision JSON byte-for-byte" reviewer "$REVIEW_PANE" "$CHILD" "$AUDIT_CONFIG" audit "$(edit_payload src/file.ts)"
assert_rendering_decision_parity "Codex rendering flag preserves policy deny decision JSON byte-for-byte" reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(edit_payload src/file.ts)"
assert_rendering_decision_parity "Codex rendering flag preserves integrity deny decision JSON byte-for-byte" reviewer unknown-pane "$CHILD" "$AUDIT_CONFIG" audit "$(bash_payload 'git status')"

echo "== inactive contract (true no-op) =="
OUT="$(printf '%s' "$(bash_payload 'rm -rf /')" | env -u SESSION_WORKSPACE_CONFIG -u SESSION_WORKSPACE_HARNESS_MODE "$PY" "$POLICY" --decision-json)"
if [ "$OUT" = '{"active":false,"decision":"allow","diagnostic":null,"mode":"","pane":"","profile":"","reason":"harness is not active","role":"","rule":"inactive","tool":""}' ]; then
  pass "no SESSION_WORKSPACE_CONFIG is a true no-op with the inactive object"
else
  fail "no SESSION_WORKSPACE_CONFIG is a true no-op with the inactive object" "$OUT"
fi
expect "schema v2 enabled=false is a true no-op" orchestrator "$MASTER_PANE" "$ROOT" "$OFF_CONFIG" "" \
  "$(bash_payload 'rm -rf /')" '.active == false and .decision == "allow" and .rule == "inactive"'
expect "schema v1 config is a true no-op even with identity present" orchestrator "$MASTER_PANE" "$ROOT" "$V1_CONFIG" "" \
  "$(bash_payload 'rm -rf /')" '.active == false and .decision == "allow"'
expect "unreadable config with no launcher mode is a no-op (stale pointer must not brick a shell)" executor "$EXEC_PANE" "$CHILD" "$BROKEN_CONFIG" "" \
  "$(bash_payload 'pwd')" '.active == false and .decision == "allow"'
expect "missing config file with no launcher mode is a no-op" executor "$EXEC_PANE" "$CHILD" "$ROOT/.agent-workspace/nope.json" "" \
  "$(bash_payload 'pwd')" '.active == false and .decision == "allow"'

echo "== identity and drift fail closed (both modes) =="
expect "unreadable config with launcher mode set fails closed" executor "$EXEC_PANE" "$CHILD" "$BROKEN_CONFIG" enforce \
  "$(bash_payload 'pwd')" '.decision == "deny" and .rule == "identity.config"'
expect "invalid active config fails closed" executor "$EXEC_PANE" "$CHILD" "$INVALID_CONFIG" enforce \
  "$(bash_payload 'pwd')" '.decision == "deny" and .rule == "identity.config"'
expect "invalid active config fails closed even in audit mode" executor "$EXEC_PANE" "$CHILD" "$INVALID_CONFIG" audit \
  "$(bash_payload 'pwd')" '.decision == "deny" and .rule == "identity.config"'
expect "launcher mode set but config now disabled (drift) fails closed" executor "$EXEC_PANE" "$CHILD" "$OFF_CONFIG" enforce \
  "$(bash_payload 'pwd')" '.decision == "deny" and .rule == "identity.mode"'
expect "config enabled after launch (empty launcher mode) fails closed" executor "$EXEC_PANE" "$CHILD" "$CONFIG" "" \
  "$(bash_payload 'pwd')" '.decision == "deny" and .rule == "identity.mode"'
expect "audit/enforce mode drift fails closed" executor "$EXEC_PANE" "$CHILD" "$CONFIG" audit \
  "$(bash_payload 'pwd')" '.decision == "deny" and .rule == "identity.mode"'
expect "forged role fails closed" executor "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce \
  "$(bash_payload 'git status')" '.decision == "deny" and .rule == "identity.role"'
expect "unknown pane fails closed" executor unknown-pane "$CHILD" "$CONFIG" enforce \
  "$(bash_payload 'pwd')" '.decision == "deny" and .rule == "identity.pane"'
expect "cwd mismatch fails closed" executor "$EXEC_PANE" "$ROOT/component-b" "$CONFIG" enforce \
  "$(bash_payload 'pwd')" '.decision == "deny" and .rule == "identity.cwd"'
expect "non-harness role on a known pane fails closed" master "$EXEC_PANE" "$CHILD" "$CONFIG" enforce \
  "$(bash_payload 'pwd')" '.decision == "deny" and .rule == "identity.role"'
expect "missing identity variable fails closed" executor "" "$CHILD" "$CONFIG" enforce \
  "$(bash_payload 'pwd')" '.decision == "deny" and .rule == "identity.missing"'
expect "SESSION_CHAT_PANE_NAME disagreeing with engine identity fails closed" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce \
  "$(bash_payload 'pwd')" '.decision == "deny" and .rule == "identity.alias"' SESSION_CHAT_PANE_NAME=someone-else
OUT="$(printf '%s' "$(bash_payload 'pwd')" | env \
  SESSION_WORKSPACE_CONFIG="$CONFIG" SESSION_WORKSPACE_PROJECT_ROOT="$TMPROOT" \
  SESSION_WORKSPACE_PANE_NAME="$EXEC_PANE" SESSION_WORKSPACE_ROLE=executor \
  SESSION_WORKSPACE_PANE_CWD="$CHILD" SESSION_WORKSPACE_HARNESS_MODE=enforce \
  CLAUDE_HOME="$FAKE_CLAUDE" CODEX_HOME="$FAKE_CODEX" "$PY" "$POLICY" --decision-json)"
if printf '%s' "$OUT" | jq -e '.decision == "deny" and .rule == "identity.root"' >/dev/null; then
  pass "project root mismatch fails closed"
else
  fail "project root mismatch fails closed" "$OUT"
fi
expect "malformed active hook input fails closed" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce \
  '{bad' '.decision == "deny" and .rule == "input.json"'
expect "empty active hook input fails closed" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce \
  '' '.decision == "deny" and .rule == "input.empty"'
expect "schema-v2 launcher upgraded to guarded schema v3 fails closed until restart" master "$MASTER_PANE" "$ROOT" "$V3_CONFIG" enforce \
  "$(bash_payload 'git status')" '.decision == "deny" and .rule == "identity.config"'
expect "schema-v3 forged guard identity fails closed" master "$MASTER_PANE" "$ROOT" "$V3_CONFIG" enforce \
  "$(bash_payload 'git status')" '.decision == "deny" and .rule == "identity.config"' SESSION_WORKSPACE_GUARDS_JSON='{}'

echo "== schema v3 additive guard decisions =="
as_master_v3 "orchestrator protected .env edit is denied" "$(edit_payload '.env')" '.decision == "deny" and .rule == "orchestrator.protected_file"'
as_master_v3 "orchestrator generic firebase JSON edit is denied" "$(edit_payload 'config/app-firebase-prod.json')" '.decision == "deny" and .rule == "orchestrator.protected_file"'
as_master_v3 "orchestrator configured exact basename is denied" "$(edit_payload 'config/custom-secret.json')" '.decision == "deny" and .rule == "orchestrator.protected_file"'
as_master_v3 "orchestrator ordinary root edit remains allowed" "$(edit_payload 'README.md')" '.decision == "allow"'
as_exec_v3 "protected-file pack does not add an executor denial" "$(edit_payload '.env')" '.decision == "allow"'
as_master_v3 "orchestrator cd into child is denied by configured guard" "$(bash_payload 'cd component-a && git status')" '.decision == "deny" and .rule == "orchestrator.child_chdir"'
as_master_v3 "orchestrator env --chdir child is denied by configured guard" "$(bash_payload 'env --chdir component-a git status')" '.decision == "deny" and .rule == "orchestrator.child_chdir"'
as_master_v3 "git -C child is not classified as process chdir" "$(bash_payload 'git -C component-a status')" '.decision == "allow"'
as_exec_v3 "child-chdir guard does not alter executor decisions" "$(bash_payload 'cd src && pwd')" '.decision == "allow"'

echo "== tool classification is by name; unknown tools are allowed =="
READ_PAYLOAD="$(jq -cn --arg p "$ROOT/component-b/secret.ts" '{tool_name:"Read",tool_input:{file_path:$p}}')"
as_review "reviewer Read tool (carries file_path) is allowed, not treated as an edit" "$READ_PAYLOAD" '.decision == "allow" and .rule == "tool.unclassified" and .tool == "Read"'
as_review "reviewer Grep tool (carries path) is allowed" "$(jq -cn --arg p "$ROOT" '{tool_name:"Grep",tool_input:{pattern:"x",path:$p}}')" '.decision == "allow" and .rule == "tool.unclassified"'
as_review "reviewer Glob tool is allowed" "$(jq -cn --arg p "$ROOT" '{tool_name:"Glob",tool_input:{pattern:"**/*.ts",path:$p}}')" '.decision == "allow"'
as_review "unknown tool with no fields is allowed (no blanket allowlist)" '{"tool_name":"WebFetch","tool_input":{"url":"https://example.invalid"}}' '.decision == "allow" and .rule == "tool.unclassified"'
as_exec "executor unknown tool is allowed" '{"tool_name":"TodoWrite","tool_input":{"todos":[]}}' '.decision == "allow"'
as_review "reviewer NotebookEdit is denied (edit tool by name)" "$(jq -cn --arg p "$CHILD/nb.ipynb" '{tool_name:"NotebookEdit",tool_input:{notebook_path:$p,new_source:"x"}}')" '.decision == "deny" and .rule == "reviewer.readonly"'
as_review "reviewer Write is denied" "$(jq -cn --arg p "$CHILD/new.ts" '{tool_name:"Write",tool_input:{file_path:$p,content:"x"}}')" '.decision == "deny" and .rule == "reviewer.readonly"'
as_review "reviewer MultiEdit is denied" "$(jq -cn --arg p "$CHILD/README.md" '{tool_name:"MultiEdit",tool_input:{file_path:$p,edits:[]}}')" '.decision == "deny" and .rule == "reviewer.readonly"'
as_review "reviewer Codex apply_patch is denied" '{"tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\n*** Update File: src/a.ts\n*** End Patch"}}' '.decision == "deny" and .rule == "reviewer.readonly"'
as_review "reviewer Codex shell tool name is classified as shell" '{"tool_name":"shell","tool_input":{"command":"touch x"}}' '.decision == "deny" and .rule == "reviewer.command"'
as_review "reviewer exact Codex 0.151 Bash payload is classified without a tool_input workdir" "$(codex_bash_payload 'pwd > out')" '.decision == "deny" and .rule == "reviewer.shell" and .tool == "Bash"'
as_exec "edit tool with no extractable target fails closed" '{"tool_name":"Edit","tool_input":{"old_string":"a","new_string":"b"}}' '.decision == "deny" and .rule == "edit.path"'

echo "== executor: edit targets must resolve inside its configured cwd =="
as_exec "executor edit inside cwd (relative) is allowed" "$(edit_payload 'src/file.ts')" '.decision == "allow" and .role == "executor"'
as_exec "executor edit inside cwd (absolute) is allowed" "$(edit_payload "$CHILD/src/file.ts")" '.decision == "allow"'
as_exec "executor Write of a new nested file inside cwd is allowed" "$(jq -cn --arg p "$CHILD/new/dir/file.ts" '{tool_name:"Write",tool_input:{file_path:$p,content:"x"}}')" '.decision == "allow"'
as_exec "executor edit traversal out of cwd is denied" "$(edit_payload '../component-b/file.ts')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor absolute edit outside cwd is denied" "$(edit_payload "$ROOT/AGENTS.md")" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor edit through a symlink escaping cwd is denied" "$(edit_payload 'escape-link/file.ts')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor edit of the workspace config is denied" "$(edit_payload "$CONFIG")" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor Codex apply_patch touching another child is denied" '{"tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\n*** Update File: src/ok.ts\n*** Add File: ../component-b/new.ts\n*** End Patch"}}' '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor Codex apply_patch inside cwd is allowed" '{"tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\n*** Update File: src/ok.ts\n*** End Patch"}}' '.decision == "allow"'
as_exec "executor apply_patch Move to outside cwd is denied" '{"tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\n*** Update File: src/ok.ts\n*** Move to: /tmp/elsewhere.ts\n*** End Patch"}}' '.decision == "deny" and .rule == "executor.containment"'

echo "== executor: shell stays available; routing and escapes are gated =="
as_exec "executor arbitrary shell inside cwd is allowed" "$(bash_payload 'npm test')" '.decision == "allow"'
as_exec "executor ungranted provider-inbox transport file is denied" "$(bash_payload "cat $FAKE_CLAUDE/messages/task.md")" '.decision == "deny" and .rule == "coordination.message_read"'
as_exec "executor relative operand inside cwd is allowed" "$(bash_payload 'ls src/')" '.decision == "allow"'
as_exec "executor absolute operand inside cwd is allowed" "$(bash_payload "cat $CHILD/README.md")" '.decision == "allow"'
as_exec "executor /dev/null operand is allowed" "$(bash_payload 'cat /dev/null')" '.decision == "allow"'
as_exec "executor absolute operand outside cwd is denied" "$(bash_payload 'rm /tmp/outside')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor traversal operand out of cwd is denied" "$(bash_payload 'cat ../component-b/secret.ts')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor symlink operand escaping cwd is denied" "$(bash_payload 'ls escape-link/')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor sibling operand in a later segment is denied" "$(bash_payload "npm test && cp dist/x.js $ROOT/component-b/")" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor operand naming the workspace root is denied" "$(bash_payload "cat $ROOT/AGENTS.md")" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor inline bash -c is denied" "$(bash_payload "bash -c 'rm -rf /tmp/x'")" '.decision == "deny" and .rule == "executor.inline_code"'
as_exec "executor inline sh -lc is denied" "$(bash_payload "sh -lc 'ls'")" '.decision == "deny" and .rule == "executor.inline_code"'
as_exec "executor inline python -c is denied" "$(bash_payload "python3 -c 'import os'")" '.decision == "deny" and .rule == "executor.inline_code"'
as_exec "executor inline node -e is denied" "$(bash_payload "node -e 'process.exit()'")" '.decision == "deny" and .rule == "executor.inline_code"'
as_exec "executor eval is denied" "$(bash_payload 'eval ls')" '.decision == "deny" and .rule == "executor.inline_code"'
as_exec "executor running a script file inside its cwd is allowed" "$(bash_payload 'bash scripts/test.sh')" '.decision == "allow"'
as_exec "executor dynamic operand is denied" "$(bash_payload 'cat $HOME/.ssh/id_rsa')" '.decision == "deny"'
as_exec "executor glob operand is denied" "$(bash_payload 'rm ../*/secrets')" '.decision == "deny"'
as_exec "executor git inside its checkout is allowed" "$(bash_payload 'git add -A && git commit -m "feat: x"')" '.decision == "allow"'
as_exec "executor direct tmux send-keys is denied (transport bypass)" "$(bash_payload "tmux send-keys -t $MASTER_PANE 'hello' Enter")" '.decision == "deny" and .rule == "routing.master"'
as_exec "executor composed tmux transport is denied" "$(bash_payload "ls && tmux paste-buffer -t %3")" '.decision == "deny" and .rule == "routing.master"'
as_exec "executor copied/relative outbound helper is denied" "$(bash_payload './send-message.sh peer hi')" '.decision == "deny" and .rule == "routing.master"'
as_exec "executor mentioning an outbound helper inside a composed command is denied" "$(bash_payload "cd /tmp && bash ./dispatch-to-session.sh $REVIEW_PANE prompt.md")" '.decision == "deny"'
as_exec "executor sandbox-escape flag is denied" '{"tool_name":"Bash","tool_input":{"command":"ls","dangerouslyDisableSandbox":true}}' '.decision == "deny" and .rule == "shell.sandbox_escape"'
as_exec "executor Codex escalated-permissions request is denied" '{"tool_name":"shell","tool_input":{"command":["ls"],"with_escalated_permissions":true}}' '.decision == "deny" and .rule == "shell.sandbox_escape"'
as_master "orchestrator sandbox-escape flag is not gated by the floor" '{"tool_name":"Bash","tool_input":{"command":"ls","dangerouslyDisableSandbox":true}}' '.decision == "allow"'
as_exec "executor empty command fails closed" "$(bash_payload '   ')" '.decision == "deny" and .rule == "bash.command"'

echo "== composed commands: dot operands, cd/pushd/popd tracking, expansion, spaces, feeders =="
mkdir -p "$ROOT/.tmp/messages" "$ROOT/.tmp/scheduler" "$ROOT/.tmp/contexts" "$ROOT/component-a/sub dir" "$TMPROOT/some dir"
printf 'x\n' > "$ROOT/.tmp/messages/note.md"
printf 'x\n' > "$ROOT/component-a/sub dir/file.ts"
printf 'x\n' > "$TMPROOT/some dir/file.ts"
as_exec "executor cd .. then rm sibling is denied (cd target tracked)" "$(bash_payload 'cd .. && rm component-b/secret.ts')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor cd .. ; touch sibling is denied" "$(bash_payload 'cd ..; touch component-b/escaped')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor pushd .. then rm sibling is denied" "$(bash_payload 'pushd .. && rm component-b/secret.ts')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor chdir .. is denied" "$(bash_payload 'chdir .. && ls')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor bare .. operand is denied" "$(bash_payload 'ls ..')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor bare . operand is allowed" "$(bash_payload 'ls .')" '.decision == "allow"'
as_exec "executor cd into a subdirectory then build is allowed" "$(bash_payload 'cd src && npm test')" '.decision == "allow"'
as_exec "executor pushd sub ; popd ; ls . is allowed" "$(bash_payload 'pushd src && ls && popd && ls .')" '.decision == "allow"'
as_exec "executor cd src ; cd .. ; ls . stays inside cwd and is allowed" "$(bash_payload 'cd src && cd .. && ls .')" '.decision == "allow"'
as_exec "executor cd src ; cd .. ; cd .. escapes and is denied" "$(bash_payload 'cd src && cd .. && cd .. && ls')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor bare cd (to HOME) is denied" "$(bash_payload 'cd && ls')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor cd - is denied (dynamic target)" "$(bash_payload 'cd - && ls')" '.decision == "deny" and .rule == "path.dynamic"'
as_exec "executor pushd with no operand is denied (stack rotation)" "$(bash_payload 'pushd && rm x')" '.decision == "deny" and .rule == "path.dynamic"'
as_exec "executor popd without a tracked pushd is denied (unknown previous cwd)" "$(bash_payload 'popd && rm x')" '.decision == "deny" and .rule == "path.dynamic"'
as_exec "executor cd -L .. is denied" "$(bash_payload 'cd -L .. && ls')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor command cd .. (builtin wrapper) is denied" "$(bash_payload 'command cd .. && rm component-b/secret.ts')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor cd ~ is denied" "$(bash_payload 'cd ~ && ls')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor cd /tmp is denied" "$(bash_payload 'cd /tmp && ls')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor cd -P .. (flag then target) is denied" "$(bash_payload 'cd -P .. && ls')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor env --chdir outside cwd is denied" "$(bash_payload 'env --chdir=/tmp ls')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor make -C .. is denied" "$(bash_payload 'make -C .. build')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor git -C ../component-b status is denied" "$(bash_payload 'git -C ../component-b status')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor rm of a double-quoted variable operand is denied (unresolved expansion)" "$(bash_payload 'rm "$TARGET"')" '.decision == "deny" and .rule == "path.dynamic"'
as_exec "executor operand with \$HOME expansion is denied" "$(bash_payload 'cat "$HOME/.ssh/id_rsa"')" '.decision == "deny" and .rule == "path.dynamic"'
as_exec "executor backtick operand is denied" "$(bash_payload 'rm `cat target`')" '.decision == "deny" and .rule == "path.dynamic"'
as_exec "executor single-quoted dollar text is literal and allowed" "$(bash_payload "grep -rn 'cost \$5' src")" '.decision == "allow"'
as_exec "executor rm absolute path containing spaces outside cwd is denied" "$(bash_payload "rm \"$TMPROOT/some dir/file.ts\"")" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor absolute path containing spaces inside cwd is allowed" "$(bash_payload "cat \"$CHILD/sub dir/file.ts\"")" '.decision == "allow"'
as_exec "executor relative path containing spaces inside cwd is allowed" "$(bash_payload "cat './sub dir/file.ts'")" '.decision == "allow"'
as_exec "executor relative traversal containing spaces is denied" "$(bash_payload "cat '../some dir/file.ts'")" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor quoted free text mentioning a slash is not a path operand" "$(bash_payload "git commit -m 'fix: handle a/b edge case'")" '.decision == "allow"'
as_exec "executor xargs is denied (unresolvable operands)" "$(bash_payload 'cat list.txt | xargs rm')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor find -delete inside cwd is allowed" "$(bash_payload 'find . -name "*.tmp" -delete')" '.decision == "allow"'
as_exec "executor codex --dangerously-bypass-approvals-and-sandbox is denied" "$(bash_payload 'codex --dangerously-bypass-approvals-and-sandbox exec "ls"')" '.decision == "deny" and .rule == "shell.sandbox_escape"'
as_exec "executor claude --dangerously-skip-permissions is denied" "$(bash_payload 'claude --dangerously-skip-permissions -p hi')" '.decision == "deny" and .rule == "shell.sandbox_escape"'
as_exec "executor claude --permission-mode bypassPermissions is denied" "$(bash_payload 'claude --permission-mode bypassPermissions')" '.decision == "deny" and .rule == "shell.sandbox_escape"'
as_review "reviewer codex bypass flag is denied" "$(bash_payload 'codex --dangerously-bypass-hook-trust')" '.decision == "deny" and .rule == "shell.sandbox_escape"'
as_master "orchestrator nested agent with a bypass flag is denied (no escape hatch for any role)" "$(bash_payload 'codex --dangerously-bypass-approvals-and-sandbox exec "ls"')" '.decision == "deny" and .rule == "shell.sandbox_escape"'
as_review "reviewer ls .. is denied" "$(bash_payload 'ls ..')" '.decision == "deny" and .rule == "reviewer.path"'
as_review "reviewer ls . is allowed" "$(bash_payload 'ls .')" '.decision == "allow"'
as_review "reviewer git -C .. status is denied" "$(bash_payload 'git -C .. status')" '.decision == "deny" and .rule == "reviewer.git"'
as_review "reviewer cat absolute path containing spaces outside its roots is denied" "$(bash_payload "cat '$TMPROOT/some dir/file.ts'")" '.decision == "deny" and .rule == "reviewer.path"'
as_review "reviewer cat path containing spaces inside its checkout is allowed" "$(bash_payload "cat '$CHILD/sub dir/file.ts'")" '.decision == "allow"'
as_review "reviewer double-quoted path is outside the strict word form" "$(bash_payload "cat \"$CHILD/sub dir/file.ts\"")" '.decision == "deny" and .rule == "reviewer.shell"'
as_review "reviewer cd is not a read-only command" "$(bash_payload 'cd .. && ls')" '.decision == "deny" and .rule == "reviewer.command"'
# Reviewer staging uses its own drafts namespace, never delivered messages.
write_payload() { jq -cn --arg p "$1" '{tool_name:"Write",tool_input:{file_path:$p,content:"PLAN-REVIEW: approve\nEvidence follows."}}'; }
as_review "reviewer can stage a multiline message" "$(write_payload "$ROOT/.tmp/messages/drafts/$REVIEW_PANE/review.md")" '.decision == "allow"'
as_review "reviewer can revise staged text" "$(edit_payload "$ROOT/.tmp/messages/drafts/$REVIEW_PANE/review.txt")" '.decision == "allow"'
as_review "reviewer relative staging path" "$(write_payload "../.tmp/messages/drafts/$REVIEW_PANE/review.md")" '.decision == "allow"'
mkdir -p "$ROOT/.tmp/messages/drafts/$REVIEW_PANE"
printf 'draft\n' > "$ROOT/.tmp/messages/drafts/$REVIEW_PANE/review.md"
as_review "reviewer can dispatch staged message" "$(bash_payload "bash $DISPATCH --reply-to abcdef12 $MASTER_PANE $ROOT/.tmp/messages/drafts/$REVIEW_PANE/review.md")" '.decision == "allow"'
for forbidden in "$CHILD/review.md" "$ROOT/.tmp/contexts/review.md" "$ROOT/.tmp/scheduler/review.md" "$ROOT/.agents/memory/review.md" "$FAKE_CLAUDE/messages/review.md" "$ROOT/.tmp/messages/queue/review.md" "$ROOT/.tmp/messages/archive/review.md" "$ROOT/.tmp/messages/.hidden.md" "$ROOT/.tmp/messages/script.sh" "$ROOT/.tmp/messages/../source.md"; do
  as_review "reviewer staging rejects $forbidden" "$(write_payload "$forbidden")" '.decision == "deny" and (.rule == "reviewer.readonly" or .rule == "coordination.draft")'
done
ln -s "$CHILD/README.md" "$ROOT/.tmp/messages/escape.md"
ln "$CHILD/README.md" "$ROOT/.tmp/messages/hardlink.md"
as_review "reviewer staging rejects symlink escape" "$(write_payload "$ROOT/.tmp/messages/escape.md")" '.decision == "deny" and (.rule == "reviewer.readonly" or .rule == "coordination.draft")'
as_review "reviewer staging rejects hardlink escape" "$(write_payload "$ROOT/.tmp/messages/hardlink.md")" '.decision == "deny" and (.rule == "reviewer.readonly" or .rule == "coordination.draft")'
as_review "reviewer patch can stage a message" "$(jq -cn --arg patch "*** Begin Patch
*** Add File: $ROOT/.tmp/messages/drafts/$REVIEW_PANE/patch.md
+review
*** End Patch" '{tool_name:"apply_patch",tool_input:{input:$patch}}')" '.decision == "allow"'
as_review "reviewer mixed patch cannot edit source" "$(jq -cn --arg patch "*** Begin Patch
*** Add File: $ROOT/.tmp/messages/drafts/$REVIEW_PANE/patch.md
+review
*** Update File: $CHILD/README.md
@@
-hello
+changed
*** End Patch" '{tool_name:"apply_patch",tool_input:{input:$patch}}')" '.decision == "deny" and (.rule == "reviewer.readonly" or .rule == "coordination.draft")'
NO_MESSAGES_CONFIG="$ROOT/.agent-workspace/no-messages.json"
jq '.roles.reviewer.grants = ["scheduler", "contexts"]' "$CONFIG" > "$NO_MESSAGES_CONFIG"
expect "reviewer staging needs an explicit messages grant" reviewer "$REVIEW_PANE" "$CHILD" "$NO_MESSAGES_CONFIG" enforce "$(write_payload "$ROOT/.tmp/messages/drafts/$REVIEW_PANE/review.md")" '.decision == "deny" and (.rule == "reviewer.readonly" or .rule == "coordination.draft")' SESSION_CHAT_TARGET_MESSAGES_DIR="$ROOT/.tmp/messages"
OVERRIDE_CONFIG="$ROOT/.agent-workspace/messages-override.json"
jq '.stores.overrides.messages = ".tmp/replies"' "$CONFIG" > "$OVERRIDE_CONFIG"
mkdir -p "$ROOT/.tmp/replies"
expect "reviewer configured message override allowed" reviewer "$REVIEW_PANE" "$CHILD" "$OVERRIDE_CONFIG" enforce "$(write_payload "$ROOT/.tmp/replies/drafts/$REVIEW_PANE/review.md")" '.decision == "allow"'
expect "reviewer old default excluded after override" reviewer "$REVIEW_PANE" "$CHILD" "$OVERRIDE_CONFIG" enforce "$(write_payload "$ROOT/.tmp/messages/drafts/$REVIEW_PANE/review.md")" '.decision == "deny" and (.rule == "reviewer.readonly" or .rule == "coordination.draft")'
as_review "reviewer reading unaddressed state in the GRANTED messages store is denied" "$(bash_payload "cat $ROOT/.tmp/messages/note.md")" '.decision == "deny" and .rule == "coordination.message_read"'
as_review "reviewer reading an UNGRANTED store (memory) is denied" "$(bash_payload "cat $ROOT/.agents/memory/MEMORY.md")" '.decision == "deny" and .rule == "reviewer.path"'
as_review "reviewer reading a stale (unselected) cache version is denied" "$(bash_payload "cat $STALE_SEND")" '.decision == "deny" and .rule == "reviewer.path"'
as_review "reviewer reading a cache dir of a plugin not selected for this workspace is denied" "$(bash_payload "cat $CLAUDE_CACHE/unlisted-plugin/1.0.0/scripts/mystery.sh")" '.decision == "deny" and .rule == "reviewer.path"'
expect "reviewer inherited SESSION_* env root is NOT a trusted read root" reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce \
  "$(bash_payload "cat $TMPROOT/some dir/file.ts")" '.decision == "deny" and .rule == "reviewer.path"' SESSION_SCHEDULER_HOME="$TMPROOT/some dir"
as_master "orchestrator cd child then read-only git is allowed" "$(bash_payload 'cd component-a && git status')" '.decision == "allow"'
as_master "orchestrator cd child then build (unknown/mutating) is denied" "$(bash_payload 'cd component-a && npm test')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator pushd child ; popd ; rm root file is allowed (cwd restored)" "$(bash_payload 'pushd component-a && ls && popd && rm notes.tmp')" '.decision == "allow"'
as_master "orchestrator cd child ; cd .. ; rm root file is allowed (cwd restored)" "$(bash_payload 'cd component-a && cd .. && rm notes.tmp')" '.decision == "allow"'
as_master "orchestrator cd .. then mutation above the root is not gated" "$(bash_payload 'cd .. && touch scratch.txt')" '.decision == "allow"'

echo "== bare relative operands: symlink canonicalization applies, free text stays data =="
ln -s "$ROOT/component-b/secret.ts" "$CHILD/escape link"
ln -s "$CHILD/README.md" "$CHILD/inner-link"
ln -s "$CHILD" "$ROOT/link-to-child"
mkdir -p "$CHILD/test" "$CHILD/scripts"
printf 'echo ok\n' > "$CHILD/scripts/test.sh"
printf 'echo evil\n' > "$ROOT/component-b/build.sh"
as_exec "executor cat of a bare symlink escaping cwd is denied" "$(bash_payload 'cat escape-link')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor cat of a bare symlink WITH whitespace escaping cwd is denied" "$(bash_payload 'cat "escape link"')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor ls of a bare escaping symlink is denied" "$(bash_payload 'ls escape-link')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor cd into a bare escaping symlink is denied" "$(bash_payload 'cd escape-link && ls')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor bare symlink that stays inside cwd is allowed" "$(bash_payload 'cat inner-link')" '.decision == "allow"'
as_exec "executor bare regular file operand is allowed" "$(bash_payload 'cat README.md')" '.decision == "allow"'
as_exec "executor bare non-existent operand is data/new file and allowed" "$(bash_payload 'touch brand-new-file.txt')" '.decision == "allow"'
as_exec "executor free text that names no entry is not a path (commit message)" "$(bash_payload "git commit -m 'fix: handle a/b edge case'")" '.decision == "allow"'
as_exec "executor bare word coinciding with an inner directory is allowed" "$(bash_payload 'npm test')" '.decision == "allow"'
as_exec "executor path-written executable inside cwd is allowed" "$(bash_payload 'bash ./scripts/test.sh')" '.decision == "allow"'
as_exec "executor direct ./script inside cwd is allowed" "$(bash_payload './scripts/test.sh')" '.decision == "allow"'
as_exec "executor sibling script as executable is denied" "$(bash_payload '../component-b/build.sh')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor absolute outside executable is denied" "$(bash_payload "$ROOT/component-b/build.sh")" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor env-prefixed sibling executable is denied" "$(bash_payload 'CI=1 ../component-b/build.sh')" '.decision == "deny" and .rule == "executor.containment"'
as_review "reviewer cat of a bare escaping symlink is denied" "$(bash_payload 'cat escape-link')" '.decision == "deny" and .rule == "reviewer.path"'
as_review "reviewer cat of a bare escaping symlink WITH whitespace is denied" "$(bash_payload "cat 'escape link'")" '.decision == "deny" and .rule == "reviewer.path"'
as_review "reviewer bare inner symlink is allowed" "$(bash_payload 'cat inner-link')" '.decision == "allow"'
as_review "reviewer grep with a free-text pattern is allowed" "$(bash_payload "grep -rn 'a/b edge case' src")" '.decision == "allow"'
as_review "reviewer path-written executable is denied" "$(bash_payload '/tmp/cat README.md')" '.decision == "deny" and .rule == "reviewer.command"'
as_review "reviewer ./cat lookalike is denied" "$(bash_payload './cat README.md')" '.decision == "deny" and .rule == "reviewer.command"'
as_master "orchestrator rm of a bare root symlink pointing into a child is denied" "$(bash_payload 'rm link-to-child')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator cat through a root symlink into a child is allowed (read)" "$(bash_payload 'cat link-to-child/README.md')" '.decision == "allow"'

echo "== redirection targets, attached cwd options, unquoted globs =="
ln -s "$ROOT/component-b/secret.ts" "$CHILD/escape-star-link"
as_exec "executor redirect to a bare escaping symlink is denied" "$(bash_payload 'printf x > escape-link')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor append to a bare escaping symlink with whitespace is denied" "$(bash_payload 'echo x >> "escape link"')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor redirect to an absolute outside target is denied" "$(bash_payload 'echo x > /tmp/out.txt')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor stderr redirect to an outside target is denied" "$(bash_payload 'npm test 2> /tmp/err.log')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor &> to an outside target is denied" "$(bash_payload 'npm test &> /tmp/all.log')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor clobber redirect to a sibling via .. is denied" "$(bash_payload 'echo x >| ../component-b/x')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor input redirect from outside is denied" "$(bash_payload 'cat < ../component-b/secret.ts')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor redirect to a bare new file inside cwd is allowed" "$(bash_payload 'echo x > out.txt')" '.decision == "allow"'
as_exec "executor fd duplication is allowed" "$(bash_payload 'npm test 2>&1')" '.decision == "allow"'
as_exec "executor input redirect from inside cwd is allowed" "$(bash_payload 'cat < README.md')" '.decision == "allow"'
as_exec "executor here-string body is data" "$(bash_payload "cat <<< 'see ../component-b'")" '.decision == "allow"'
as_exec "executor git -C.. (attached) is denied" "$(bash_payload 'git -C.. clean -fd')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor make -C.. (attached) is denied" "$(bash_payload 'make -C.. build')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor env -C.. (attached) is denied" "$(bash_payload 'env -C.. ls')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor git -Csrc (attached, inside) is allowed" "$(bash_payload 'git -Csrc status')" '.decision == "allow"'
as_exec "executor assignment value naming an outside path is denied" "$(bash_payload 'OUT=/tmp/build make')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor unquoted glob operand is denied (fail closed)" "$(bash_payload 'cat escape-*')" '.decision == "deny" and .rule == "path.dynamic"'
as_exec "executor unquoted brace expansion is denied" "$(bash_payload 'rm {a,b}.txt')" '.decision == "deny" and .rule == "path.dynamic"'
as_exec "executor unquoted ? glob is denied" "$(bash_payload 'ls escape-lin?')" '.decision == "deny" and .rule == "path.dynamic"'
as_exec "executor quoted glob pattern is data and allowed" "$(bash_payload 'find . -name "*.tmp" -delete')" '.decision == "allow"'
as_exec "executor single-quoted brace text is allowed" "$(bash_payload "grep -rn '{ok}' src")" '.decision == "allow"'
as_review "reviewer unquoted glob is denied" "$(bash_payload 'cat escape-*')" '.decision == "deny" and .rule == "reviewer.shell"'
as_review "reviewer git -C.. (attached) is denied" "$(bash_payload 'git -C.. status')" '.decision == "deny" and (.rule == "reviewer.path" or .rule == "reviewer.git")'
as_review "reviewer quoted glob pattern in grep is allowed" "$(bash_payload "grep -rn 'x*y' src")" '.decision == "allow"'
as_master "orchestrator redirect write into a child is denied" "$(bash_payload 'echo x > component-a/generated.ts')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator redirect write at its root is allowed" "$(bash_payload 'echo x > notes.txt')" '.decision == "allow"'
as_master "orchestrator input redirect from a child is a read and allowed" "$(bash_payload 'wc -l < component-a/README.md')" '.decision == "allow"'

echo "== executor selected plugin reads without read_paths =="
as_exec "executor native patch inside checkout control" "$(jq -cn --arg path "$CHILD/README.md" '{tool_name:"apply_patch",tool_input:{patch:("*** Begin Patch\n*** Update File: " + $path + "\n@@\n-hello\n+updated\n*** End Patch")}}')" '.decision == "allow"'
for SELECTED in "$CLAUDE_CACHE/session-chat/1.2.3" "$CODEX_CACHE/session-chat/2.0.0"; do
  mkdir -p "$SELECTED/skills/reply/references" "$SELECTED/commands"
  printf 'Reply instructions\n' > "$SELECTED/skills/reply/SKILL.md"
  printf 'Reply reference\n' > "$SELECTED/skills/reply/references/guide.md"
  printf 'Reply command\n' > "$SELECTED/commands/reply.md"
  ln -s "$ROOT/AGENTS.md" "$SELECTED/skills/reply/escape.md"
  SKILL_FILE="$SELECTED/skills/reply/SKILL.md"
  REF_DIR="$SELECTED/skills/reply/references"
  as_exec "executor selected skill read: $SELECTED" "$(bash_payload "cat $SKILL_FILE")" '.decision == "allow"'
  as_exec "executor Codex argv selected skill read: $SELECTED" "$(jq -cn --arg path "$SKILL_FILE" --arg cwd "$CHILD" '{tool_name:"shell",tool_input:{command:["cat",$path],workdir:$cwd}}')" '.decision == "allow"'
  as_exec "executor selected command read: $SELECTED" "$(bash_payload "cat $SELECTED/commands/reply.md")" '.decision == "allow"'
  as_exec "executor selected reference head: $SELECTED" "$(bash_payload "head -n 1 $REF_DIR/guide.md")" '.decision == "allow"'
  as_exec "executor selected reference grep: $SELECTED" "$(bash_payload "grep Reply $REF_DIR/guide.md")" '.decision == "allow"'
  as_exec "executor selected reference rg: $SELECTED" "$(bash_payload "rg --no-config Reply $REF_DIR")" '.decision == "allow"'
  as_exec "executor selected reference listing: $SELECTED" "$(bash_payload "ls $REF_DIR")" '.decision == "allow"'
  as_exec "executor selected cache symlink escape: $SELECTED" "$(bash_payload "cat $SELECTED/skills/reply/escape.md")" '.decision == "deny" and .rule == "executor.containment"'
  as_exec "executor cache redirection denied: $SELECTED" "$(bash_payload "cat $SKILL_FILE > result.md")" '.decision == "deny" and .rule == "executor.containment"'
  as_exec "executor cache pipeline denied: $SELECTED" "$(bash_payload "cat $SKILL_FILE | tee result.md")" '.decision == "deny" and .rule == "executor.containment"'
  as_exec "executor composed cache read denied: $SELECTED" "$(bash_payload "cat $SKILL_FILE && rm local.md")" '.decision == "deny" and .rule == "executor.containment"'
  as_exec "executor cache chdir denied: $SELECTED" "$(bash_payload "cd $SELECTED && cat skills/reply/SKILL.md")" '.decision == "deny" and .rule == "executor.containment"'
  as_exec "executor cache copy denied: $SELECTED" "$(bash_payload "cp $SKILL_FILE local.md")" '.decision == "deny" and .rule == "executor.containment"'
  as_exec "executor cache rg config denied: $SELECTED" "$(bash_payload "rg Reply $REF_DIR")" '.decision == "deny" and .rule == "executor.containment"'
  as_exec "executor cache grep follow denied: $SELECTED" "$(bash_payload "grep -R Reply $REF_DIR")" '.decision == "deny" and .rule == "executor.containment"'
  as_exec "executor cache rg follow denied: $SELECTED" "$(bash_payload "rg --no-config -L Reply $REF_DIR")" '.decision == "deny" and .rule == "executor.containment"'
  as_exec "executor cache find execution denied: $SELECTED" "$(bash_payload "find $REF_DIR -exec cat '{}' +")" '.decision == "deny" and .rule == "executor.containment"'
  as_exec "executor cache tail follow denied: $SELECTED" "$(bash_payload "tail -f $SKILL_FILE")" '.decision == "deny" and .rule == "executor.containment"'
  as_exec "executor cache preprocessor denied: $SELECTED" "$(bash_payload "rg --no-config --pre cat Reply $REF_DIR")" '.decision == "deny" and .rule == "executor.containment"'
  as_exec "executor cache directory diff denied: $SELECTED" "$(bash_payload "diff $REF_DIR $REF_DIR")" '.decision == "deny" and .rule == "executor.containment"'
  as_exec "executor cache touch denied: $SELECTED" "$(bash_payload "touch $SKILL_FILE")" '.decision == "deny" and .rule == "executor.containment"'
  as_exec "executor cache rm denied: $SELECTED" "$(bash_payload "rm $SKILL_FILE")" '.decision == "deny" and .rule == "executor.containment"'
  as_exec "executor cache native edit denied: $SELECTED" "$(edit_payload "$SKILL_FILE")" '.decision == "deny" and .rule == "executor.containment"'
  as_exec "executor cache native patch denied: $SELECTED" "$(jq -cn --arg path "$SKILL_FILE" '{tool_name:"apply_patch",tool_input:{patch:("*** Begin Patch\n*** Update File: " + $path + "\n@@\n-Reply instructions\n+Updated reply instructions\n*** End Patch")}}')" '.decision == "deny" and .rule == "executor.containment"'
  as_exec "executor cache skill execution denied: $SELECTED" "$(bash_payload "bash $SKILL_FILE")" '.decision == "deny" and (.rule | startswith("helper."))'
  as_exec "executor cache skill source denied: $SELECTED" "$(bash_payload "source $SKILL_FILE")" '.decision == "deny" and (.rule | startswith("helper."))'
  as_exec "executor cache parent listing denied: $SELECTED" "$(bash_payload "ls $SELECTED/..")" '.decision == "deny" and .rule == "executor.containment"'
  as_exec "executor cache workdir denied: $SELECTED" "$(jq -cn --arg dir "$SELECTED" '{tool_name:"Bash",tool_input:{command:"cat skills/reply/SKILL.md",workdir:$dir}}')" '.decision == "deny" and .rule == "executor.containment"'
  as_exec "executor conflicting cwd/workdir cannot grant cache reads: $SELECTED" "$(jq -cn --arg dir "$CHILD" --arg command "cat $SKILL_FILE" '{tool_name:"Bash",tool_input:{command:$command,cwd:$dir,workdir:($dir+"/src")}}')" '.decision == "deny" and .rule == "executor.containment"'
  as_exec "executor matching cwd/workdir cache read control: $SELECTED" "$(jq -cn --arg dir "$CHILD" --arg command "cat $SKILL_FILE" '{tool_name:"Bash",tool_input:{command:$command,cwd:$dir,workdir:$dir}}')" '.decision == "allow"'
done
as_exec "executor selected-version symlink read control" "$(bash_payload "cat $CLAUDE_CACHE/session-chat/link/skills/reply/SKILL.md")" '.decision == "allow"'
as_exec "executor stale Claude cache read denied" "$(bash_payload "cat $STALE_SEND")" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor stale Codex cache read denied" "$(bash_payload "cat $CODEX_STALE_SEND")" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor unselected plugin read denied" "$(bash_payload "cat $CLAUDE_CACHE/unlisted-plugin/1.0.0/scripts/mystery.sh")" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor foreign marketplace read denied" "$(bash_payload "cat $FAKE_CODEX/plugins/cache/other/session-chat/2.0.0/skills/reply/SKILL.md")" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor provider inbox read remains denied" "$(bash_payload "cat $FAKE_CLAUDE/messages/task.md")" '.decision == "deny" and .rule == "coordination.message_read"'
as_exec "executor scheduler store read remains denied" "$(bash_payload "cat $ROOT/.tmp/scheduler/tasks/task.json")" '.decision == "deny" and .rule == "executor.containment"'
expect "executor tilde selected cache read control" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce \
  "$(bash_payload 'cat ~/plugins/cache/girishattri-plugins/session-chat/1.2.3/skills/reply/SKILL.md')" '.decision == "allow"' HOME="$FAKE_CLAUDE"
expect "executor selected cache read in audit mode" executor "$EXEC_PANE" "$CHILD" "$AUDIT_CONFIG" audit \
  "$(bash_payload "cat $SKILL_FILE")" '.decision == "allow"'
PLUGIN_READ_CONFIG="$ROOT/.agent-workspace/plugin-read-paths.json"
jq '.sessions[0].panes[1].read_paths = ["AGENTS.md"]' "$CONFIG" > "$PLUGIN_READ_CONFIG"
PLUGIN_READ_IDENTITY="$(jq -cnS --arg path "$ROOT/AGENTS.md" '[{path:$path,kind:"file"}]')"
expect "executor selected cache read with explicit read_paths" executor "$EXEC_PANE" "$CHILD" "$PLUGIN_READ_CONFIG" enforce \
  "$(bash_payload "cat $SKILL_FILE")" '.decision == "allow"' SESSION_WORKSPACE_READ_PATHS_JSON="$PLUGIN_READ_IDENTITY"
expect "executor explicit grant read control" executor "$EXEC_PANE" "$CHILD" "$PLUGIN_READ_CONFIG" enforce \
  "$(bash_payload "cat $ROOT/AGENTS.md")" '.decision == "allow"' SESSION_WORKSPACE_READ_PATHS_JSON="$PLUGIN_READ_IDENTITY"

echo "== trusted helpers: exact selected provenance (Claude cache) =="
as_exec "executor selected helper send to orchestrator is allowed" "$(bash_payload "bash $SEND $MASTER_PANE 'done: abc123'")" '.decision == "allow"'
as_exec "executor helper send to a sibling reviewer is denied (child routing is master-only)" "$(bash_payload "bash $SEND $REVIEW_PANE hi")" '.decision == "deny" and .rule == "routing.master"'
as_exec "executor helper send with reply correlation is allowed" "$(bash_payload "bash $SEND --reply-to deadbeef $MASTER_PANE 'ack'")" '.decision == "allow"'
as_exec "executor helper with unknown option is denied" "$(bash_payload "bash $SEND --loud $MASTER_PANE hi")" '.decision == "deny" and .rule == "helper.argv"'
as_exec "executor helper with malformed reply id is denied" "$(bash_payload "bash $SEND --reply-to xyz $MASTER_PANE hi")" '.decision == "deny" and .rule == "helper.argv"'
as_exec "executor helper send with a task association is allowed" "$(bash_payload "bash $SEND --reply-to deadbeef --task task-1791000000-abcdef12 $MASTER_PANE 'ack'")" '.decision == "allow"'
as_exec "executor helper with a malformed task id is denied" "$(bash_payload "bash $SEND --task 'bad id' $MASTER_PANE hi")" '.decision == "deny" and .rule == "helper.argv"'
as_exec "executor helper with a duplicated --task is denied" "$(bash_payload "bash $SEND --task a1 --task a1 $MASTER_PANE hi")" '.decision == "deny" and .rule == "helper.argv"'
as_exec "executor check-replies with a task filter is allowed" "$(bash_payload "bash $CLAUDE_CACHE/session-chat/1.2.3/scripts/check-replies.sh --pending --task 1a2b3c4d --since 30")" '.decision == "allow"'
as_exec "executor check-replies with a malformed task filter is denied" "$(bash_payload "bash $CLAUDE_CACHE/session-chat/1.2.3/scripts/check-replies.sh --task 'x;y'")" '.decision == "deny" and .rule == "helper.argv"'
as_exec "executor check-replies with an unknown flag is denied" "$(bash_payload "bash $CLAUDE_CACHE/session-chat/1.2.3/scripts/check-replies.sh --all")" '.decision == "deny" and .rule == "helper.argv"'
as_exec "stale (unselected) Claude helper version is denied" "$(bash_payload "bash $STALE_SEND $MASTER_PANE hi")" '.decision == "deny" and .rule == "helper.selection"'
as_exec "helper reached through a symlinked version dir is denied" "$(bash_payload "bash $CLAUDE_CACHE/session-chat/link/scripts/send-message.sh $MASTER_PANE hi")" '.decision == "deny" and (.rule == "helper.path" or .rule == "helper.provenance")'
as_exec "symlinked helper script is denied" "$(bash_payload "bash $CLAUDE_CACHE/session-chat/1.2.3/scripts/send-link.sh $MASTER_PANE hi")" '.decision == "deny" and .rule == "helper.path"'
as_exec "helper path with traversal is denied" "$(bash_payload "bash $CLAUDE_CACHE/session-chat/0.9.0/../1.2.3/scripts/send-message.sh $MASTER_PANE hi")" '.decision == "deny" and .rule == "helper.path"'
as_exec "helper path with \$HOME is not literal and is denied" "$(bash_payload "bash \$HOME/.claude/plugins/cache/girishattri-plugins/session-chat/1.2.3/scripts/send-message.sh $MASTER_PANE hi")" '.decision == "deny" and (.rule == "helper.segment" or .rule == "helper.path")'
as_exec "unknown helper basename in a selected plugin is denied" "$(bash_payload "bash $CLAUDE_CACHE/session-chat/1.2.3/scripts/rogue.sh $MASTER_PANE hi")" '.decision == "deny" and .rule == "helper.allowlist"'
as_exec "plugin selected only for another project is denied" "$(bash_payload "bash $CLAUDE_CACHE/unlisted-plugin/1.0.0/scripts/mystery.sh")" '.decision == "deny" and (.rule == "helper.selection" or .rule == "helper.allowlist")'
UNTRUSTED="$TMPROOT/send-message.sh"
cp "$SEND" "$UNTRUSTED"
as_exec "lookalike helper outside any cache is denied" "$(bash_payload "bash $UNTRUSTED $MASTER_PANE hi")" '.decision == "deny" and .rule == "routing.master"'
OTHER_MARKET="$FAKE_CLAUDE/plugins/cache/other-marketplace/session-chat/1.2.3/scripts"
mkdir -p "$OTHER_MARKET" && cp "$SEND" "$OTHER_MARKET/send-message.sh"
as_exec "helper from a different marketplace cache is denied" "$(bash_payload "bash $OTHER_MARKET/send-message.sh $MASTER_PANE hi")" '.decision == "deny" and .rule == "helper.provenance"'

echo "== trusted helpers: literal, uncomposed invocation only =="
as_exec "helper chained with ; is denied" "$(bash_payload "bash $SEND $MASTER_PANE hi; touch x")" '.decision == "deny" and .rule == "helper.segment"'
as_exec "helper chained with && is denied" "$(bash_payload "true && bash $SEND $MASTER_PANE hi")" '.decision == "deny" and .rule == "helper.segment"'
as_exec "helper piped is denied" "$(bash_payload "echo hi | bash $SEND $MASTER_PANE hi")" '.decision == "deny" and .rule == "helper.segment"'
as_exec "helper with redirection is denied" "$(bash_payload "bash $SEND $MASTER_PANE hi > /tmp/out")" '.decision == "deny" and .rule == "helper.segment"'
as_exec "helper with command substitution is denied" "$(bash_payload "bash $SEND $MASTER_PANE \"\$(id)\"")" '.decision == "deny" and .rule == "helper.segment"'
as_exec "helper with backtick expansion is denied" "$(bash_payload "bash $SEND $MASTER_PANE \`id\`")" '.decision == "deny" and .rule == "helper.segment"'
as_exec "helper with double-quoted variable expansion is denied" "$(bash_payload "bash $SEND $MASTER_PANE \"hi \$USER\"")" '.decision == "deny" and .rule == "helper.segment"'
as_exec "helper with a single-quoted dollar sign is literal and allowed" "$(bash_payload "bash $SEND $MASTER_PANE 'cost \$5'")" '.decision == "allow"'
as_exec "helper behind an env assignment prefix is denied" "$(bash_payload "FOO=1 bash $SEND $MASTER_PANE hi")" '.decision == "deny" and .rule == "helper.launch"'
as_exec "helper behind env wrapper is denied" "$(bash_payload "env bash $SEND $MASTER_PANE hi")" '.decision == "deny" and .rule == "helper.launch"'
as_exec "helper behind exec is denied" "$(bash_payload "exec bash $SEND $MASTER_PANE hi")" '.decision == "deny" and .rule == "helper.launch"'
as_exec "helper run via sh instead of bash is denied" "$(bash_payload "sh $SEND $MASTER_PANE hi")" '.decision == "deny" and .rule == "helper.launch"'
as_exec "helper executed directly (no bash) is denied" "$(bash_payload "$SEND $MASTER_PANE hi")" '.decision == "deny" and .rule == "helper.launch"'
# Tier 1.4 H4 rewrite: a send-message body is inert free text, so naming another
# installed script THERE is now allowed; the refusal moves to operand slots the
# helper grammar does not classify as free text (target, prompt-file operand).
as_exec "helper naming another installed script as a prompt-file operand is denied" "$(bash_payload "bash $DISPATCH $MASTER_PANE $STALE_SEND")" '.decision == "deny" and .rule == "helper.argv"'
as_exec "helper naming another installed script as the send target is denied" "$(bash_payload "bash $SEND $STALE_SEND hi")" '.decision == "deny" and .rule == "helper.argv"'
as_exec "helper naming another installed script inside a send-message body is inert text and allowed (H4)" "$(bash_payload "bash $SEND $MASTER_PANE $STALE_SEND")" '.decision == "allow"'
as_exec "helper with a multi-line argument is denied" "$(jq -cn --arg c "bash $SEND $MASTER_PANE 'line one
line two'" '{tool_name:"Bash",tool_input:{command:$c}}')" '.decision == "deny" and (.rule == "helper.segment" or .rule == "helper.argv")'

echo "== trusted helpers: Codex cache provenance =="
as_exec "selected Codex helper is allowed" "$(bash_payload "bash $CODEX_SEND $MASTER_PANE hi")" '.decision == "allow"'
as_exec "stale Codex helper version is denied" "$(bash_payload "bash $CODEX_STALE_SEND $MASTER_PANE hi")" '.decision == "deny" and .rule == "helper.selection"'
as_exec "Codex-shaped argv-list helper invocation is allowed" "$(jq -cn --arg s "$CODEX_SEND" --arg m "$MASTER_PANE" '{tool_name:"shell",tool_input:{command:["bash",$s,$m,"hi there"]}}')" '.decision == "allow"'
as_exec "Codex-shaped bash -lc helper invocation is allowed" "$(jq -cn --arg c "bash $CODEX_SEND $MASTER_PANE hi" '{tool_name:"shell",tool_input:{command:["bash","-lc",$c]}}')" '.decision == "allow"'

echo "== reviewer: read-only shell grammar + coordination exception =="
as_review "reviewer git status is allowed" "$(bash_payload 'git status --short')" '.decision == "allow"'
as_review "reviewer git log with limits is allowed" "$(bash_payload 'git log --oneline -n 20')" '.decision == "allow"'
as_review "reviewer git diff against a quoted ~ ref is allowed" "$(bash_payload "git diff 'HEAD~1' -- src/file.ts")" '.decision == "allow"'
as_review "reviewer unquoted ~ is outside the strict word form" "$(bash_payload 'git diff HEAD~1 -- src/file.ts')" '.decision == "deny" and .rule == "reviewer.shell"'
as_review "reviewer git -C inside its cwd is denied (no -C in the exact forms)" "$(bash_payload "git -C $CHILD log -n 3")" '.decision == "deny" and .rule == "reviewer.git"'
as_review "reviewer git log in its cwd is allowed (control)" "$(bash_payload "git log -n 3")" '.decision == "allow"'
as_review "reviewer git -c config injection is denied" "$(bash_payload 'git -c core.pager=touch log')" '.decision == "deny" and .rule == "reviewer.git"'
as_review "reviewer git diff --output is denied" "$(bash_payload 'git diff --output=/tmp/x')" '.decision == "deny" and .rule == "reviewer.git"'
as_review "reviewer git branch -d is denied" "$(bash_payload 'git branch -d topic')" '.decision == "deny" and .rule == "reviewer.git"'
as_review "reviewer git branch <name> (creation) is denied" "$(bash_payload 'git branch reviewer-branch')" '.decision == "deny" and .rule == "reviewer.git"'
as_review "reviewer git branch --list with a pattern is allowed" "$(bash_payload "git branch --list 'feat*'")" '.decision == "allow"'
as_review "reviewer git branch -a is allowed" "$(bash_payload 'git branch -a -v')" '.decision == "allow"'
as_review "reviewer git tag <name> (creation) is denied" "$(bash_payload 'git tag v1.0')" '.decision == "deny" and .rule == "reviewer.git"'
as_review "reviewer git tag -l is allowed" "$(bash_payload "git tag -l 'v*'")" '.decision == "allow"'
as_review "reviewer git remote -v is allowed" "$(bash_payload 'git remote -v')" '.decision == "allow"'
as_review "reviewer git remote get-url is allowed" "$(bash_payload 'git remote get-url origin')" '.decision == "allow"'
as_review "reviewer git remote set-url is denied" "$(bash_payload 'git remote set-url origin https://x.invalid')" '.decision == "deny" and .rule == "reviewer.git"'
as_review "reviewer env-assignment prefix is denied as a launch wrapper" "$(bash_payload "GIT_PAGER='touch x' git log -1")" '.decision == "deny" and .rule == "reviewer.shell"'
as_review "reviewer env wrapper is denied" "$(bash_payload 'env git status')" '.decision == "deny" and .rule == "reviewer.shell"'
as_review "reviewer git remote add is denied" "$(bash_payload 'git remote add evil https://x.invalid')" '.decision == "deny" and .rule == "reviewer.git"'
as_review "reviewer git grep -O (pager exec) is denied" "$(bash_payload 'git grep -O TODO')" '.decision == "deny" and .rule == "reviewer.git"'
as_review "reviewer git push is denied" "$(bash_payload 'git push origin main')" '.decision == "deny" and .rule == "reviewer.git"'
as_review "reviewer git commit is denied" "$(bash_payload 'git commit -m x')" '.decision == "deny" and .rule == "reviewer.git"'
as_review "reviewer git config write is denied" "$(bash_payload 'git config user.email r@example.test')" '.decision == "deny" and .rule == "reviewer.git"'
as_review "reviewer cat inside cwd is allowed" "$(bash_payload 'cat README.md')" '.decision == "allow"'
as_review "reviewer read of the workspace root is denied (only its own checkout)" "$(bash_payload "cat $ROOT/AGENTS.md")" '.decision == "deny" and .rule == "reviewer.path"'
as_review "reviewer sibling checkout read via ../ is denied" "$(bash_payload 'cat ../component-b/secret.ts')" '.decision == "deny" and .rule == "reviewer.path"'
as_review "reviewer git -C sibling checkout is denied" "$(bash_payload "git -C $ROOT/component-b log")" '.decision == "deny" and .rule == "reviewer.git"'
as_review "reviewer cat outside the workspace/trusted roots is denied" "$(bash_payload 'cat /etc/hosts')" '.decision == "deny" and .rule == "reviewer.path"'
as_review "reviewer reading an ungranted provider-inbox file is denied" "$(bash_payload "cat $FAKE_CLAUDE/messages/task.md")" '.decision == "deny" and .rule == "coordination.message_read"'
as_review "reviewer reading a selected plugin cache file is allowed (operand, not execution)" "$(bash_payload "cat $SEND")" '.decision == "allow"'
as_review "reviewer rg inside cwd is allowed" "$(bash_payload 'rg --no-config -n TODO src')" '.decision == "allow"'
as_review "reviewer rg --pre is denied" "$(bash_payload 'rg --no-config --pre ./x TODO')" '.decision == "deny" and .rule == "reviewer.search"'
as_review "reviewer find -exec is denied" "$(bash_payload 'find . -exec sh -c true ;')" '.decision == "deny"'
as_review "reviewer find -delete is denied" "$(bash_payload 'find . -name x -delete')" '.decision == "deny" and .rule == "reviewer.find"'
as_review "reviewer tail -f is denied" "$(bash_payload 'tail -f log.txt')" '.decision == "deny" and .rule == "reviewer.tail"'
as_review "reviewer sort -o is denied" "$(bash_payload 'sort -o out in')" '.decision == "deny" and .rule == "reviewer.sort"'
as_review "reviewer sed has one exact print form" "$(bash_payload 'sed -n 1p README.md')" '.decision == "allow"'
as_review "reviewer sed outside its print form is denied" "$(bash_payload 'sed 1p README.md')" '.decision == "deny" and .rule == "reviewer.sed"'
as_review "reviewer sed -i is denied" "$(bash_payload 'sed -i s/a/b/ file')" '.decision == "deny" and .rule == "reviewer.sed"'
as_review "reviewer awk is denied" "$(bash_payload "awk '{print}' README.md")" '.decision == "deny" and .rule == "reviewer.sed"'
as_review "reviewer touch is denied" "$(bash_payload 'touch file')" '.decision == "deny" and .rule == "reviewer.command"'
as_review "reviewer pipeline of exact read forms is allowed" "$(bash_payload 'git log | head')" '.decision == "allow"'
as_review "reviewer pipeline into an unlisted program is denied" "$(bash_payload 'git log | xargs cat')" '.decision == "deny" and .rule == "reviewer.command"'
as_review "reviewer redirection is denied" "$(bash_payload 'git status > out')" '.decision == "deny" and .rule == "reviewer.shell"'
as_review "reviewer command substitution is denied" "$(bash_payload 'cat $(ls)')" '.decision == "deny" and .rule == "reviewer.shell"'
as_review "reviewer dynamic path operand is denied" "$(bash_payload 'cat $HOME/.ssh/id_rsa')" '.decision == "deny"'
as_review "reviewer glob path operand is denied" "$(bash_payload 'cat ../*/secrets')" '.decision == "deny"'
as_review "reviewer argv-list read command is allowed" '{"tool_name":"shell","tool_input":{"command":["git","status"]}}' '.decision == "allow"'
as_review "reviewer bash -lc read command is allowed" '{"tool_name":"shell","tool_input":{"command":["bash","-lc","git status --short"]}}' '.decision == "allow"'
as_review "reviewer helper send to the orchestrator is allowed" "$(bash_payload "bash $SEND --reply-to cafe1234 $MASTER_PANE 'APPROVE abc123'")" '.decision == "allow"'
as_review "reviewer helper send to the executor is denied" "$(bash_payload "bash $SEND $EXEC_PANE hi")" '.decision == "deny" and .rule == "routing.master"'
as_review "reviewer dispatch of an existing file to the orchestrator is allowed" "$(bash_payload "bash $DISPATCH $MASTER_PANE $FAKE_CLAUDE/messages/task.md")" '.decision == "allow"'
as_review "reviewer dispatch of a missing prompt file is denied" "$(bash_payload "bash $DISPATCH $MASTER_PANE /nonexistent/prompt.md")" '.decision == "deny" and .rule == "helper.argv"'
as_review "reviewer broadcast is denied (master-only helper, no child grammar)" "$(bash_payload "bash $CLAUDE_CACHE/session-chat/1.2.3/scripts/broadcast-message.sh hi")" '.decision == "deny" and .rule == "helper.allowlist"'
as_review "reviewer task-done with note is allowed" "$(bash_payload "bash $SCHED/task-done.sh t-1234 'approved at abc123'")" '.decision == "allow"'
as_review "reviewer task-block with reason is allowed" "$(bash_payload "bash $SCHED/task-block.sh t-1234 'missing tests'")" '.decision == "allow"'
as_review "reviewer task-block without reason is denied" "$(bash_payload "bash $SCHED/task-block.sh t-1234")" '.decision == "deny" and .rule == "helper.argv"'
as_review "reviewer forced transition is denied" "$(bash_payload "bash $SCHED/task-done.sh t-1234 --force ok")" '.decision == "deny" and .rule == "helper.argv"'
as_review "reviewer task-review (executor-only) is denied" "$(bash_payload "bash $SCHED/task-review.sh t-1234 note")" '.decision == "deny" and .rule == "coordination.write"'
as_review "reviewer task-new (creation) is denied" "$(bash_payload "bash $SCHED/task-new.sh 'new task'")" '.decision == "deny" and .rule == "coordination.write"'
as_review "reviewer task-assign (assignment) is denied" "$(bash_payload "bash $SCHED/task-assign.sh $EXEC_PANE t-1 'do it'")" '.decision == "deny" and .rule == "coordination.write"'

# --- Contracted task files: malformed shapes deny (never crash), the
# --generation form needs a real contract, and reconcile notes are literal.
# A crashed policy exits 1, which a PreToolUse hook treats as non-blocking, so
# every unexpected shape must become a deny decision.
CT_TASKS="$ROOT/.tmp/scheduler/tasks"
mkdir -p "$CT_TASKS"
ct_task() { # ct_task ID EXTRA_JQ
  jq -cn --arg id "$1" --arg a "$MASTER_PANE" --arg r "$REVIEW_PANE" --arg e "$EXEC_PANE" \
    "{id:\$id,assigner:\$a,reviewer:\$r,assignee:\$e,status:\"review\"} $2" > "$CT_TASKS/$1.json"
}
ct_task ct-good '| .contract = {version: 1}'
ct_task ct-plain ''
ct_task ct-meta '| .contract = {version: 1} | .meta = "x"'
printf '[]\n' > "$CT_TASKS/ct-list.json"
printf 'null\n' > "$CT_TASKS/ct-null.json"
as_review "contracted --generation done by the bound reviewer is allowed (control)" "$(bash_payload "bash $SCHED/task-done.sh ct-good --generation 1 'APPROVE abc123'")" '.decision == "allow"'
for shape in ct-list ct-null ct-meta; do
  as_review "malformed task file ($shape) denies instead of crashing" "$(bash_payload "bash $SCHED/task-done.sh $shape --generation 1 'APPROVE abc123'")" '.decision == "deny" and .rule == "task.contract"'
done
as_review "--generation form on an uncontracted task is denied" "$(bash_payload "bash $SCHED/task-done.sh ct-plain --generation 1 'APPROVE abc123'")" '.decision == "deny" and .rule == "task.contract"'
as_review "legacy note form on the same uncontracted task stays allowed (control)" "$(bash_payload "bash $SCHED/task-done.sh ct-plain 'approved at abc123'")" '.decision == "allow"'
# --- 1.2b-min: --note-file on task-done/task-block admits only this pane's own
# existing draft inside the validated messages grant. Each refusal sits beside
# the allowed own-draft control; the chat read-check helper is not agent-callable.
NF_DIR="$ROOT/.tmp/messages/drafts/$REVIEW_PANE"
mkdir -p "$NF_DIR" "$ROOT/.tmp/messages/drafts/$EXEC_PANE"
printf 'verdict body\n' > "$NF_DIR/verdict.md"
printf 'peer draft\n' > "$ROOT/.tmp/messages/drafts/$EXEC_PANE/peer.md"
printf 'script\n' > "$NF_DIR/verdict.sh"
printf 'linked\n' > "$NF_DIR/target.md"; ln -s "$NF_DIR/target.md" "$NF_DIR/link.md"
printf 'hard\n' > "$NF_DIR/hard.md"; ln "$NF_DIR/hard.md" "$TMPROOT/nf-hard-other.md"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$CLAUDE_CACHE/session-chat/1.2.3/scripts/own-draft-check.sh"
as_review "reviewer task-done --note-file own draft is allowed (control)" "$(bash_payload "bash $SCHED/task-done.sh t-1234 --note-file $NF_DIR/verdict.md")" '.decision == "allow"'
as_review "reviewer task-block --note-file own draft is allowed (control)" "$(bash_payload "bash $SCHED/task-block.sh t-1234 --note-file $NF_DIR/verdict.md")" '.decision == "allow"'
as_review "contracted task-done --generation --note-file own draft is allowed (control)" "$(bash_payload "bash $SCHED/task-done.sh ct-good --generation 1 --note-file $NF_DIR/verdict.md")" '.decision == "allow"'
as_review "contracted --generation --note-file on an uncontracted task is denied" "$(bash_payload "bash $SCHED/task-done.sh ct-plain --generation 1 --note-file $NF_DIR/verdict.md")" '.decision == "deny" and .rule == "task.contract"'
NF_DENY='.decision == "deny" and .rule == "helper.argv"'
as_review "note-file: the executor's draft is denied" "$(bash_payload "bash $SCHED/task-done.sh t-1234 --note-file $ROOT/.tmp/messages/drafts/$EXEC_PANE/peer.md")" "$NF_DENY"
as_review "note-file: a delivered message file is denied" "$(bash_payload "bash $SCHED/task-done.sh t-1234 --note-file $FAKE_CLAUDE/messages/task.md")" "$NF_DENY"
as_review "note-file: a file directly in the messages root is denied" "$(bash_payload "bash $SCHED/task-done.sh t-1234 --note-file $ROOT/.tmp/messages/hardlink.md")" "$NF_DENY"
as_review "note-file: a file in the checkout is denied" "$(bash_payload "bash $SCHED/task-done.sh t-1234 --note-file $CHILD/README.md")" "$NF_DENY"
as_review "note-file: a symlink in the own drafts directory is denied" "$(bash_payload "bash $SCHED/task-done.sh t-1234 --note-file $NF_DIR/link.md")" "$NF_DENY"
as_review "note-file: a hardlinked own draft is denied" "$(bash_payload "bash $SCHED/task-done.sh t-1234 --note-file $NF_DIR/hard.md")" "$NF_DENY"
as_review "note-file: a missing own draft is denied" "$(bash_payload "bash $SCHED/task-done.sh t-1234 --note-file $NF_DIR/absent.md")" "$NF_DENY"
as_review "note-file: a draft with an ineligible name is denied" "$(bash_payload "bash $SCHED/task-done.sh t-1234 --note-file $NF_DIR/verdict.sh")" "$NF_DENY"
as_review "note-file: traversal back into the drafts directory is denied" "$(bash_payload "bash $SCHED/task-done.sh t-1234 --note-file $NF_DIR/../$REVIEW_PANE/verdict.md")" "$NF_DENY"
as_review "note-file: an option-like path is denied" "$(bash_payload "bash $SCHED/task-done.sh t-1234 --note-file --force")" "$NF_DENY"
as_review "note-file: with an inline note is denied" "$(bash_payload "bash $SCHED/task-done.sh t-1234 --note-file $NF_DIR/verdict.md 'extra note'")" "$NF_DENY"
as_review "note-file: with --force is denied" "$(bash_payload "bash $SCHED/task-done.sh t-1234 --force --note-file $NF_DIR/verdict.md")" "$NF_DENY"
as_review "note-file: repeated flag is denied" "$(bash_payload "bash $SCHED/task-done.sh t-1234 --note-file $NF_DIR/verdict.md --note-file $NF_DIR/verdict.md")" "$NF_DENY"
as_review "note-file: missing path operand is denied" "$(bash_payload "bash $SCHED/task-block.sh t-1234 --note-file")" "$NF_DENY"
as_review "note-file: on task-review (executor-only helper) is denied" "$(bash_payload "bash $SCHED/task-review.sh t-1234 --note-file $NF_DIR/verdict.md")" '.decision == "deny" and .rule == "coordination.write"'
as_exec "note-file: the executor's own draft is allowed on task-block (control)" "$(bash_payload "bash $SCHED/task-block.sh t-1234 --note-file $ROOT/.tmp/messages/drafts/$EXEC_PANE/peer.md")" '.decision == "allow"'
as_exec "note-file: the executor may not use the reviewer's draft" "$(bash_payload "bash $SCHED/task-block.sh t-1234 --note-file $NF_DIR/verdict.md")" "$NF_DENY"
as_review "chat own-draft-check helper is not agent-callable" "$(bash_payload "bash $CLAUDE_CACHE/session-chat/1.2.3/scripts/own-draft-check.sh $NF_DIR/verdict.md")" '.decision == "deny" and .rule == "helper.allowlist"'
as_review "chat own-draft-check --consume is not agent-callable" "$(bash_payload "bash $CLAUDE_CACHE/session-chat/1.2.3/scripts/own-draft-check.sh --consume $NF_DIR/verdict.md 1:2 $(printf '0%.0s' $(seq 1 64))")" '.decision == "deny" and .rule == "helper.allowlist"'
as_master "orchestrator task-done --note-file stays denied (worker-owned stage)" "$(bash_payload "bash $SCHED/task-done.sh t-1234 --note-file $NF_DIR/verdict.md")" '.decision == "deny" and .rule == "coordination.write"'

as_master "contract reconcile with a literal note is allowed (control)" "$(bash_payload "bash $SCHED/task-contract.sh reconcile ct-good --generation 1 --note 'worker stopped; no external effects'")" '.decision == "allow"'
as_master "contract reconcile with an option-like note is denied" "$(bash_payload "bash $SCHED/task-contract.sh reconcile ct-good --generation 1 --note --force")" '.decision == "deny" and .rule == "helper.argv"'

# Module-level: an unexpected exception in evaluate() must deny with exit 2
# (positive control: a normal allow still exits 0), and scoped_task refuses
# non-object task files and meta instead of raising AttributeError.
h1_out=$("$PY" -B - "$POLICY" 2>&1 <<'PY'
import contextlib, importlib.util, io, json, sys, tempfile, types
from pathlib import Path
spec = importlib.util.spec_from_file_location("harness_policy_h1", sys.argv[1])
m = importlib.util.module_from_spec(spec); sys.modules[spec.name] = m; spec.loader.exec_module(m)
results = {}
def run_main(fn):
    m.evaluate = fn; sys.stdin = io.StringIO("{}"); err = io.StringIO()
    with contextlib.redirect_stderr(err):
        rc = m.main([])
    return rc, err.getvalue()
def boom(raw): raise AttributeError("unexpected")
rc, err = run_main(boom); results["crash_denies"] = rc == 2 and "policy.internal" in err
rc, err = run_main(lambda raw: m.allow(None, "")); results["allow_control"] = rc == 0
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp).resolve(); (root / "tasks").mkdir()
    ctx = types.SimpleNamespace(environment="", scheduler_root=root, executor_panes={"e"}, reviewer_panes={"r"}, orchestrator_pane="o")
    def scoped(body):
        (root / "tasks" / "t1.json").write_text(body)
        try:
            m.scoped_task(ctx, "task-done.sh", ["t1"]); return "allow"
        except m.PolicyFailure:
            return "deny"
        except Exception as exc:
            return "crash:" + type(exc).__name__
    results["scoped_control"] = scoped(json.dumps({"meta": {"environment": "root"}, "assignee": "e", "reviewer": "r", "assigner": "o"})) == "allow"
    for name, body in [("list", "[]"), ("null", "null"), ("meta_string", json.dumps({"meta": "x"}))]:
        results["scoped_" + name] = scoped(body) == "deny"
    # scheduler_store_root: a child uses its own grant; the orchestrator
    # resolves to the single shared child grant; anything else is none.
    a, b = root / "store-a", root / "store-b"
    def g(path): return {"store": "scheduler", "path": str(path)}
    child = lambda *grants: {"grants": list(grants)}
    resolve = m.scheduler_store_root
    results["store_child_own"] = resolve(child(g(a)), [], "executor") == m.canonical(a)
    results["store_child_ungranted"] = resolve(child(), [child(g(a))], "executor") is None
    results["store_orch_unique"] = resolve(child(), [child(g(a)), child(g(a))], "orchestrator") == m.canonical(a)
    results["store_orch_ambiguous"] = resolve(child(), [child(g(a)), child(g(b))], "orchestrator") is None
    results["store_orch_ungranted"] = resolve(child(), [child(), child({"store": "messages", "path": str(a)})], "orchestrator") is None
    results["store_orch_malformed_grants"] = resolve({"grants": None}, [{"grants": ["scheduler"]}, child({"store": "scheduler"})], "orchestrator") is None
bad = [k for k, v in results.items() if not v]
print("H1-OK" if not bad else "H1-BAD " + ",".join(bad))
PY
)
if [ "$h1_out" = "H1-OK" ]; then pass "unexpected policy errors deny (exit 2) and scoped tasks refuse malformed shapes"; else fail "unexpected policy errors deny (exit 2) and scoped tasks refuse malformed shapes" "$h1_out"; fi
as_review "reviewer task-status is allowed" "$(bash_payload "bash $SCHED/task-status.sh --mine")" '.decision == "allow"'
as_review "reviewer task-board is allowed" "$(bash_payload "bash $SCHED/task-board.sh")" '.decision == "allow"'
as_review "reviewer memory write (remember) is denied" "$(bash_payload "bash $KNOW/memory-remember.sh --staged x")" '.decision == "deny" and .rule == "coordination.write"'
as_review "reviewer docs write is denied" "$(bash_payload "bash $KNOW/docs-write.sh docs/x.md")" '.decision == "deny" and .rule == "coordination.write"'
as_review "reviewer context load is allowed" "$(bash_payload "bash $KNOW/load-context.sh review_arc")" '.decision == "allow"'
as_review "reviewer context save of an existing snapshot file is allowed" "$(bash_payload "bash $KNOW/save-context.sh review_arc $CHILD/README.md --handoff --expires 2026-12-31T00:00:00Z")" '.decision == "allow"'
# Handoff data uses the same literal-file boundary as the snapshot operand.
printf '{"scope":{},"items":[]}\n' > "$CHILD/handoff data.json"
HANDOFF_DATA="$CHILD/handoff data.json"
as_review "reviewer context save with handoff data is allowed" "$(bash_payload "bash $KNOW/save-context.sh review_arc $CHILD/README.md --handoff --handoff-data '$HANDOFF_DATA'")" '.decision == "allow"'
as_review "reviewer context save with handoff data before handoff is allowed" "$(bash_payload "bash $KNOW/save-context.sh review_arc $CHILD/README.md --handoff-data '$HANDOFF_DATA' --expires 2026-12-31T00:00:00Z --handoff")" '.decision == "allow"'
as_review "reviewer context save with missing handoff data value is denied" "$(bash_payload "bash $KNOW/save-context.sh review_arc $CHILD/README.md --handoff --handoff-data")" '.decision == "deny" and .rule == "helper.argv"'
as_review "reviewer context save with empty handoff data value is denied" "$(bash_payload "bash $KNOW/save-context.sh review_arc $CHILD/README.md --handoff --handoff-data ''")" '.decision == "deny" and .rule == "helper.argv"'
as_review "reviewer context save with a flag as handoff data value is denied" "$(bash_payload "bash $KNOW/save-context.sh review_arc $CHILD/README.md --handoff-data --handoff")" '.decision == "deny" and .rule == "helper.argv"'
as_review "reviewer context save with nonexistent handoff data is denied" "$(bash_payload "bash $KNOW/save-context.sh review_arc $CHILD/README.md --handoff --handoff-data $CHILD/missing.json")" '.decision == "deny" and .rule == "helper.argv"'
as_review "reviewer context save with directory handoff data is denied" "$(bash_payload "bash $KNOW/save-context.sh review_arc $CHILD/README.md --handoff --handoff-data $CHILD")" '.decision == "deny" and .rule == "helper.argv"'
as_review "reviewer context save with dynamic handoff data is denied" "$(bash_payload "bash $KNOW/save-context.sh review_arc $CHILD/README.md --handoff --handoff-data '\$HOME/data.json'")" '.decision == "deny" and .rule == "path.dynamic"'
as_review "reviewer context save with outside handoff data is denied" "$(bash_payload "bash $KNOW/save-context.sh review_arc $CHILD/README.md --handoff --handoff-data /etc/hosts")" '.decision == "deny" and .rule == "helper.argv"'
as_review "reviewer context save with handoff data without handoff is denied" "$(bash_payload "bash $KNOW/save-context.sh review_arc $CHILD/README.md --handoff-data '$HANDOFF_DATA'")" '.decision == "deny" and .rule == "helper.argv"'
as_review "reviewer context save with a bad --expires is denied" "$(bash_payload "bash $KNOW/save-context.sh review_arc $CHILD/README.md --expires tomorrow")" '.decision == "deny" and .rule == "helper.argv"'
as_review "reviewer context share to the orchestrator is allowed" "$(bash_payload "bash $KNOW/share-context.sh $MASTER_PANE review_arc")" '.decision == "allow"'
as_review "reviewer context share to the executor is denied" "$(bash_payload "bash $KNOW/share-context.sh $EXEC_PANE review_arc")" '.decision == "deny" and .rule == "routing.master"'
as_review "reviewer memory search is allowed" "$(bash_payload "bash $KNOW/memory-search.sh --limit 5 harness policy")" '.decision == "allow"'
as_review "reviewer memory search with --store override is denied" "$(bash_payload "bash $KNOW/memory-search.sh --store /tmp/x harness")" '.decision == "deny" and .rule == "helper.argv"'
as_review "reviewer workspace read verb via dispatcher is allowed" "$(bash_payload "bash $WS/workspace.sh harness-status --json")" '.decision == "allow"'
as_review "reviewer workspace start via dispatcher is denied" "$(bash_payload "bash $WS/workspace.sh start")" '.decision == "deny" and .rule == "coordination.write"'
as_review "reviewer harness-status.sh is allowed" "$(bash_payload "bash $WS/harness-status.sh --json")" '.decision == "allow"'
as_review "reviewer harness-status.sh --config pointing elsewhere is denied" "$(bash_payload "bash $WS/harness-status.sh --config /tmp/other.json")" '.decision == "deny" and .rule == "helper.argv"'
as_review "reviewer harness-status.sh --probe --json is allowed" "$(bash_payload "bash $WS/harness-status.sh --probe --json")" '.decision == "allow"'
as_exec "executor harness-status --probe via dispatcher is allowed" "$(bash_payload "bash $WS/workspace.sh harness-status --probe")" '.decision == "allow"'
as_review "reviewer workspace-status.sh --probe is denied (harness-status only)" "$(bash_payload "bash $WS/workspace-status.sh --probe")" '.decision == "deny" and .rule == "helper.argv"'
as_review "reviewer workspace-start.sh is denied" "$(bash_payload "bash $WS/workspace-start.sh")" '.decision == "deny" and .rule == "coordination.write"'
as_review "reviewer helper from an unlisted plugin is denied" "$(bash_payload "bash $CLAUDE_CACHE/unlisted-plugin/1.0.0/scripts/mystery.sh")" '.decision == "deny"'

as_review "reviewer memory recall without --store is allowed (store resolved by the script)" "$(bash_payload "bash $KNOW/memory-search.sh --recall --limit 5 harness policy")" '.decision == "allow"'
as_review "reviewer explicit --store on an ungranted memory root is denied (no memory grant)" "$(bash_payload "bash $KNOW/memory-search.sh --store $ROOT/.agents/memory --recall harness")" '.decision == "deny" and .rule == "helper.argv"'
as_exec "executor explicit --store on its granted memory root is allowed" "$(bash_payload "bash $KNOW/memory-search.sh --store $ROOT/.agents/memory --recall --limit 5 harness policy")" '.decision == "allow"'
as_review "reviewer memory search --json and --recall together is denied" "$(bash_payload "bash $KNOW/memory-search.sh --json --recall x")" '.decision == "deny" and .rule == "helper.argv"'
as_review "reviewer memory search with an external --store is denied" "$(bash_payload "bash $KNOW/memory-search.sh --store /tmp/elsewhere harness")" '.decision == "deny" and .rule == "helper.argv"'
as_review "reviewer memory search with --store after the query is denied" "$(bash_payload "bash $KNOW/memory-search.sh harness --store $ROOT/.agents/memory")" '.decision == "deny" and .rule == "helper.argv"'
as_review "reviewer knowledge doctor without --store is allowed" "$(bash_payload "bash $KNOW/doctor.sh")" '.decision == "allow"'
as_exec "executor knowledge doctor with its granted store is allowed" "$(bash_payload "bash $KNOW/doctor.sh --store $ROOT/.agents/memory")" '.decision == "allow"'
as_review "reviewer memory-lint without --store is allowed" "$(bash_payload "bash $KNOW/memory-lint.sh")" '.decision == "allow"'
as_review "reviewer graph neighbors is allowed" "$(bash_payload "bash $KNOW/memory-backlinks.sh neighbors project_session_workspace")" '.decision == "allow"'
as_review "reviewer graph render with a reviewed format is allowed" "$(bash_payload "bash $KNOW/memory-backlinks.sh graph --format mermaid")" '.decision == "allow"'
as_review "reviewer graph with an unreviewed subcommand is denied" "$(bash_payload "bash $KNOW/memory-backlinks.sh rewrite x")" '.decision == "deny" and .rule == "helper.argv"'
as_exec "executor tool workdir inside its cwd is allowed" "$(jq -cn --arg w "$CHILD/src" '{tool_name:"shell",tool_input:{command:["ls"],workdir:$w}}')" '.decision == "allow"'
as_exec "executor tool workdir escaping its cwd is denied" "$(jq -cn --arg w "$ROOT/component-b" '{tool_name:"shell",tool_input:{command:["ls"],workdir:$w}}')" '.decision == "deny" and .rule == "executor.containment"'
as_review "reviewer tool workdir outside allowed roots is denied" '{"tool_name":"shell","tool_input":{"command":["ls"],"workdir":"/etc"}}' '.decision == "deny" and .rule == "reviewer.path"'
as_master "orchestrator tool workdir inside a child repo is denied" "$(jq -cn --arg w "$CHILD" '{tool_name:"shell",tool_input:{command:["ls"],workdir:$w}}')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_exec "executor apply_patch with JSON-string tool_input is decoded" "$(jq -cn '{tool_name:"apply_patch",tool_input:("{\"patch\":\"*** Begin Patch\\n*** Update File: ../component-b/x.ts\\n*** End Patch\"}")}')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor apply_patch with bare patch-text tool_input is classified" "$(jq -cn '{tool_name:"apply_patch",tool_input:"*** Begin Patch\n*** Update File: src/ok.ts\n*** End Patch"}')" '.decision == "allow"'
as_exec "executor relative edit target under a tool workdir is resolved against it" "$(jq -cn --arg w "$ROOT/component-b" '{tool_name:"apply_patch",tool_input:{workdir:$w,patch:"*** Begin Patch\n*** Update File: x.ts\n*** End Patch"}}')" '.decision == "deny" and .rule == "executor.containment"'

echo "== executor: coordination helpers =="
as_exec "executor task-review with note is allowed" "$(bash_payload "bash $SCHED/task-review.sh t-1234 'ready: abc123'")" '.decision == "allow"'
as_exec "executor task-assign is denied (master-owned)" "$(bash_payload "bash $SCHED/task-assign.sh $REVIEW_PANE t-1 'review'")" '.decision == "deny" and .rule == "coordination.write"'
as_exec "executor task-new is denied (master-owned)" "$(bash_payload "bash $SCHED/task-new.sh 'x'")" '.decision == "deny" and .rule == "coordination.write"'
as_exec "executor memory remember of a staged file is allowed" "$(bash_payload "bash $KNOW/memory-remember.sh --staged $TMPROOT/candidate.md")" '.decision == "allow"'
as_exec "executor memory remember --list is allowed" "$(bash_payload "bash $KNOW/memory-remember.sh --list --expired-only")" '.decision == "allow"'
as_exec "executor memory remember with free text is denied (exact grammar only)" "$(bash_payload "bash $KNOW/memory-remember.sh 'remember this'")" '.decision == "deny" and .rule == "helper.argv"'
as_exec "executor memory remember of a missing staged file is denied" "$(bash_payload "bash $KNOW/memory-remember.sh --staged /nonexistent/c.md")" '.decision == "deny" and .rule == "helper.argv"'
as_exec "executor docs write is denied (no child grammar)" "$(bash_payload "bash $KNOW/docs-write.sh docs/x.md")" '.decision == "deny" and .rule == "coordination.write"'
as_exec "executor broadcast is denied (master-owned)" "$(bash_payload "bash $CLAUDE_CACHE/session-chat/1.2.3/scripts/broadcast-message.sh hi")" '.decision == "deny" and .rule == "helper.allowlist"'

echo "== orchestrator: child-repo floor =="
as_master "orchestrator root edit is allowed" "$(edit_payload 'AGENTS.md')" '.decision == "allow" and .role == "orchestrator"'
as_master "orchestrator edit of the workspace config is allowed" "$(edit_payload "$CONFIG")" '.decision == "allow"'
as_master "orchestrator edit outside the workspace is allowed (floor is child roots only)" "$(edit_payload "$TMPROOT/notes.md")" '.decision == "allow"'
as_master "orchestrator child edit is denied" "$(edit_payload 'component-a/src/file.ts')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator child Write is denied" "$(jq -cn --arg p "$CHILD/new.ts" '{tool_name:"Write",tool_input:{file_path:$p,content:"x"}}')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator apply_patch touching a child is denied" '{"tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\n*** Update File: component-a/src/file.ts\n*** End Patch"}}' '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator child read is allowed" "$(bash_payload 'cat component-a/README.md')" '.decision == "allow"'
as_master "orchestrator git -C child read is allowed" "$(bash_payload 'git -C component-a status --short')" '.decision == "allow"'

# 0.9.0: remote identifiers never need to collide with filesystem paths for
# the orchestrator gh mutation floor to apply. Every deny family below shares
# a nearby read control; no gh command is actually executed or authenticated.
GH_ALLOW='.decision == "allow" and .role == "orchestrator" and .rule == "orchestrator.gh_read"'
GH_MUTATE='.decision == "deny" and .role == "orchestrator" and .rule == "orchestrator.gh_mutation"'
GH_UNSUPPORTED='.decision == "deny" and .role == "orchestrator" and .rule == "orchestrator.gh_unsupported"'
for gh_read in 'run list' 'run view 123' 'run view 123 --log' 'run view 123 --log-failed' \
  'pr list' 'pr view 1' 'pr diff 1' 'pr checks 1' 'workflow list' 'workflow view 1 --yaml' 'release list' 'release view v1'; do
  as_master "gh read $gh_read" "$(bash_payload "gh $gh_read --repo sample-org/component-a")" "$GH_ALLOW"
done
for gh_repo in '--repo sample-org/component-a' '--repo=sample-org/component-a' '-R sample-org/component-a' '-Rsample-org/component-a'; do
  as_master "gh repository spelling $gh_repo" "$(bash_payload "gh run list $gh_repo --limit 5")" "$GH_ALLOW"
done
as_master "gh positional repo view" "$(bash_payload 'gh repo view sample-org/component-a --json name --jq .name')" "$GH_ALLOW"
as_master "gh quoted jq metacharacters are data" "$(bash_payload "gh pr list -R sample-org/component-a --json number --jq '.[] | .number?'")" "$GH_ALLOW"
as_master "gh single quoted pipe is formatting data" "$(bash_payload "gh pr list -R sample-org/component-a --template '|'")" "$GH_ALLOW"
as_master "gh workflow -w filter is not browser launch" "$(bash_payload 'gh run list -R sample-org/component-a -w ci.yml')" "$GH_ALLOW"
as_master "gh workflow list JSON recipe" "$(bash_payload "gh workflow list -R sample-org/component-a --json name --jq '.[] | .name' --limit 5")" "$GH_ALLOW"
for gh_endpoint in repos/sample-org/component-a/actions/runs repositories/123/actions/runs; do
  as_master "gh implicit API GET $gh_endpoint" "$(bash_payload "gh api $gh_endpoint")" "$GH_ALLOW"
  for gh_method in '-X GET' '-XGET' '--method GET' '--method=GET'; do
    as_master "gh explicit GET $gh_method $gh_endpoint" "$(bash_payload "gh api $gh_endpoint $gh_method -F per_page=5")" "$GH_ALLOW"
  done
  for gh_method in POST PUT PATCH DELETE HEAD OPTIONS TRACE CONNECT Post delete; do
    as_master "gh remote method $gh_method $gh_endpoint denied without path collision" "$(bash_payload "gh api $gh_endpoint -X $gh_method")" "$GH_MUTATE"
  done
  for gh_method in '-XDELETE' '--method=PATCH' '--method PUT'; do
    as_master "gh attached remote method $gh_method denied" "$(bash_payload "gh api $gh_endpoint $gh_method")" "$GH_MUTATE"
  done
  for gh_field in '-f per_page=5' '-F per_page=5' '-fper_page=5' '-Fper_page=5' '--raw-field=per_page=5' '--field per_page=5' '--input AGENTS.md' '--input=AGENTS.md'; do
    as_master "gh implicit POST $gh_field $gh_endpoint denied" "$(bash_payload "gh api $gh_endpoint $gh_field")" "$GH_MUTATE"
    as_master "gh explicit GET control $gh_field $gh_endpoint" "$(bash_payload "gh api $gh_endpoint $gh_field --method GET")" "$GH_ALLOW"
  done
done
as_master "gh file field explicit GET" "$(bash_payload 'gh api repos/sample-org/component-a/issues -X GET -F body=@AGENTS.md')" "$GH_ALLOW"
as_master "gh raw field at sign is data" "$(bash_payload 'gh api repos/sample-org/component-a/issues -X GET -f body=@-')" "$GH_ALLOW"
as_master "gh quoted API query punctuation" "$(bash_payload "gh api 'repos/sample-org/component-a/actions/runs?per_page=5&page=2'")" "$GH_ALLOW"
for gh_mutation in 'run rerun' 'run cancel' 'run delete' 'workflow run' 'workflow enable' 'workflow disable' \
  'pr create' 'pr merge' 'pr close' 'pr comment' 'pr review' 'pr edit' 'release create' 'release delete' 'release upload' 'repo edit' 'repo delete'; do
  as_master "gh $gh_mutation remote mutation denied without path collision" "$(bash_payload "gh $gh_mutation --repo sample-org/component-a")" "$GH_MUTATE"
done
for gh_bad in 'gh pv -R sample-org/component-a' 'gh extension exec helper' 'gh unknown -R sample-org/component-a' \
  'gh pr checkout 1 -R sample-org/component-a' 'gh repo clone sample-org/component-a' \
  'gh run list -R component-a' 'gh run list -R ./component-a' 'gh run list -R ../component-a' \
  'gh run list -R /tmp/component-a' 'gh run list -R ~/component-a' 'gh run list -R $HOME/component-a' \
  'gh run list -R sample-org/component-a/extra' 'gh run list -R sample-org/..' \
  'gh run list --repo' 'gh run list -R sample-org/component-a --repo sample-org/component-b' \
  'gh run list -R sample-org/component-a --future-flag' 'gh run list -R sample-org/component-a --web' \
  'gh pr view 1 -R sample-org/component-a -w' 'gh run list -R sample-org/component-a --limit=-1' \
  'gh api graphql' 'gh api https://example.invalid/repos/sample-org/component-a/issues' \
  'gh api //example.invalid/repos/sample-org/component-a/issues' 'gh api repos/sample-org/component-a/../issues' \
  'gh api repos/sample-org/component-a/issues --hostname example.invalid' \
  'gh api repos/sample-org/component-a/issues -H X-HTTP-Method-Override:DELETE' \
  'gh api repos/sample-org/component-a/issues --cache 1h' \
  'gh api repos/sample-org/component-a/issues -X GET --method GET' \
  'gh api repos/sample-org/component-a/issues -X get' \
  'gh api repos/sample-org/component-a/issues -X GET --input -' \
  'gh api repos/sample-org/component-a/issues -X GET -F body=@-' \
  'gh api repos/sample-org/component-a/issues -X GET -F body={owner}' \
  'gh pr list -R sample-org/component-a | gh pr merge 1 -R sample-org/component-a' \
  'gh pr list -R sample-org/component-a | cat' 'true && gh pr list -R sample-org/component-a' \
  'gh pr list -R sample-org/component-a; true' 'gh pr list -R sample-org/component-a 2>/dev/null' \
  'gh pr list -R $(echo sample-org/component-a)' 'GH_CONFIG_DIR=/tmp gh pr list -R sample-org/component-a' \
  'timeout 5 gh pr merge 1 -R sample-org/component-a' 'nice gh pr merge 1 -R sample-org/component-a' \
  'find . -maxdepth 0 -exec gh pr merge 1 -R sample-org/component-a \;' \
  'env gh pr list -R sample-org/component-a' 'command gh pr list -R sample-org/component-a' '/usr/bin/gh pr list -R sample-org/component-a'; do
  as_master "gh unsupported $gh_bad" "$(bash_payload "$gh_bad")" "$GH_UNSUPPORTED"
done
as_master "gh newline composition denied" "$(bash_payload $'gh pr list -R sample-org/component-a\ngh pr merge 1 -R sample-org/component-a')" "$GH_UNSUPPORTED"
as_master "gh after newline denied" "$(bash_payload $'true\ngh pr merge 1 -R sample-org/component-a')" "$GH_UNSUPPORTED"
as_master "gh continued executable denied" "$(bash_payload $'g\\\nh pr merge 1 -R sample-org/component-a')" "$GH_UNSUPPORTED"
as_master "literal gh operand to read command is unchanged" "$(bash_payload 'echo gh')" '.decision == "allow" and .rule == "allow"'
# An OWNER/NAME that also resolves to a child is still a remote identifier,
# but the exact same spelling remains a path for ordinary commands.
as_master "gh identifier colliding with child path" "$(bash_payload 'gh pr list -R component-a/src')" "$GH_ALLOW"
as_master "non-gh colliding child path still denied" "$(bash_payload 'rm component-a/src')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "git stderr redirect unchanged" "$(bash_payload 'git -C component-a status 2>/dev/null')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "git loop unchanged" "$(bash_payload 'for repo in component-a; do git -C "$repo" status; done')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_exec "executor gh remote mutation floor unchanged" "$(bash_payload 'gh api repositories/123/actions/runs -X DELETE')" '.decision == "allow" and .rule == "allow"'
as_exec "executor gh local config control" "$(bash_payload 'GH_CONFIG_DIR=./config gh pr list --repo sample-org/component-a')" '.decision == "allow" and .rule == "allow"'
as_exec "executor gh config escape unchanged" "$(bash_payload 'GH_CONFIG_DIR=../component-b gh pr list --repo sample-org/component-a')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor gh repo path escape unchanged" "$(bash_payload 'gh pr list --repo ../component-b')" '.decision == "deny" and .rule == "executor.containment"'
as_review "reviewer gh still denied" "$(bash_payload 'gh pr list --repo sample-org/component-a')" '.decision == "deny" and .rule == "reviewer.command"'
as_review "reviewer git control" "$(bash_payload 'git status --short')" '.decision == "allow" and .rule == "allow"'
expect "gh audit mutation retains rule" master "$MASTER_PANE" "$ROOT" "$AUDIT_CONFIG" audit \
  "$(bash_payload 'gh api repositories/123/actions/runs -X DELETE')" '.decision == "audit" and .rule == "orchestrator.gh_mutation"'
as_master "orchestrator git -C child commit is denied" "$(bash_payload 'git -C component-a commit -m "log"')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator rm inside child is denied" "$(bash_payload 'rm component-a/src/file.ts')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator cd child && mutate is denied" "$(bash_payload 'cd component-a && git commit -m x')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator absolute child path mutation is denied" "$(bash_payload "touch $CHILD/marker")" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator git push is denied (route to the owning executor)" "$(bash_payload 'git push origin main')" '.decision == "deny" and .rule == "orchestrator.push"'
as_master "orchestrator git -C . push is denied" "$(bash_payload 'git -C . push origin main')" '.decision == "deny" and .rule == "orchestrator.push"'
as_master "orchestrator push hidden behind && is denied" "$(bash_payload 'git commit -m x && git push')" '.decision == "deny" and .rule == "orchestrator.push"'
as_master "orchestrator git commit on its own root is allowed" "$(bash_payload 'git commit -m "docs: x"')" '.decision == "allow"'
as_master "orchestrator root mutation is allowed" "$(bash_payload 'rm -f notes.tmp')" '.decision == "allow"'
as_master "orchestrator task-assign naming a child path in the prompt is allowed (helper argv is data)" "$(bash_payload "bash $SCHED/task-assign.sh $EXEC_PANE t-9 --eta 30 'Edit component-a/src/file.ts and run tests'")" '.decision == "allow"'
as_master "orchestrator routing outside its configured topology is denied" "$(bash_payload "bash $SEND some-other-project-pane hi")" '.decision == "deny" and .rule == "routing.master"'
as_master "orchestrator send to its executor is allowed" "$(bash_payload "bash $SEND $EXEC_PANE 'go'")" '.decision == "allow"'
as_master "orchestrator dispatch to its reviewer is allowed" "$(bash_payload "bash $DISPATCH $REVIEW_PANE $FAKE_CLAUDE/messages/task.md")" '.decision == "allow"'
as_master "orchestrator stale helper version is denied" "$(bash_payload "bash $STALE_SEND $EXEC_PANE hi")" '.decision == "deny" and .rule == "helper.selection"'
as_master "orchestrator lookalike helper outside the cache is denied" "$(bash_payload "bash $UNTRUSTED $EXEC_PANE hi")" '.decision == "deny" and .rule == "routing.master"'
as_master "orchestrator helper with expansion is denied" "$(bash_payload "bash $SEND $EXEC_PANE \"\$(id)\"")" '.decision == "deny" and .rule == "helper.segment"'
as_master "orchestrator helper behind an env prefix is denied" "$(bash_payload "FOO=1 bash $SEND $EXEC_PANE hi")" '.decision == "deny" and .rule == "helper.launch"'
as_master "orchestrator unknown helper basename is denied" "$(bash_payload "bash $CLAUDE_CACHE/session-chat/1.2.3/scripts/rogue.sh x")" '.decision == "deny" and .rule == "helper.allowlist"'
as_master "orchestrator task-new with a configured reviewer is allowed" "$(bash_payload "bash $SCHED/task-new.sh 'Ship feature' --stage build --reviewer $REVIEW_PANE --depends-on t-1,t-2")" '.decision == "allow"'
as_master "orchestrator task-new with an unknown reviewer pane is denied" "$(bash_payload "bash $SCHED/task-new.sh 'x' --reviewer stranger")" '.decision == "deny" and .rule == "helper.argv"'
as_master "orchestrator task-assign to a stranger pane is denied" "$(bash_payload "bash $SCHED/task-assign.sh stranger t-1 'do it'")" '.decision == "deny" and .rule == "routing.master"'
as_master "orchestrator task-assign --force is denied" "$(bash_payload "bash $SCHED/task-assign.sh $EXEC_PANE t-1 --force 'do it'")" '.decision == "deny" and .rule == "helper.argv"'
as_master "orchestrator task-done is denied (worker-owned stage)" "$(bash_payload "bash $SCHED/task-done.sh t-1 ok")" '.decision == "deny" and .rule == "coordination.write"'
as_master "orchestrator tasks-clean dry run is allowed" "$(bash_payload "bash $SCHED/tasks-clean.sh --older-than 30 --status done")" '.decision == "allow"'
as_master "orchestrator memory-write apply with literal CAS flags is allowed" "$(bash_payload "bash $KNOW/memory-write.sh apply --store $ROOT/.agents/memory --target note.md --staged-target $TMPROOT/candidate.md --staged-index $TMPROOT/candidate.md --expect-target absent --expect-index 0000000000000000000000000000000000000000000000000000000000000000")" '.decision == "allow"'
as_master "orchestrator memory-write with an unreviewed flag is denied" "$(bash_payload "bash $KNOW/memory-write.sh apply --store $ROOT/.agents/memory --hook /tmp/x")" '.decision == "deny" and .rule == "helper.argv"'
for disposition in dismiss restore; do
  disposition_command="bash $KNOW/memory-write.sh $disposition --store $ROOT/.agents/memory --candidate 0000000000000000000000000000000000000000000000000000000000000000 --expect-candidate 0000000000000000000000000000000000000000000000000000000000000000"
  as_master "orchestrator memory-write $disposition is allowed" "$(bash_payload "$disposition_command")" '.decision == "allow"'
  as_exec "executor memory-write $disposition remains denied" "$(bash_payload "$disposition_command")" '.decision == "deny" and .rule == "coordination.write"'
  as_review "reviewer memory-write $disposition remains denied" "$(bash_payload "$disposition_command")" '.decision == "deny" and .rule == "coordination.write"'
done
as_master "orchestrator dismissed inbox listing is allowed" "$(bash_payload "bash $KNOW/memory-remember.sh --store $ROOT/.agents/memory --list --dismissed")" '.decision == "allow"'
as_master "orchestrator memory-lint --fix is allowed" "$(bash_payload "bash $KNOW/memory-lint.sh --fix")" '.decision == "allow"'
as_master "orchestrator docs-write inside the workspace is allowed" "$(bash_payload "bash $KNOW/docs-write.sh --repo $ROOT")" '.decision == "allow"'
as_master "orchestrator docs-write outside the workspace is denied" "$(bash_payload "bash $KNOW/docs-write.sh --repo /tmp")" '.decision == "deny" and .rule == "helper.argv"'
as_master "orchestrator auto-capture without staged input is denied" "$(bash_payload "bash $KNOW/memory-auto-capture.sh")" '.decision == "deny" and .rule == "helper.argv"'
as_master "orchestrator auto-capture staged input is allowed" "$(bash_payload "bash $KNOW/memory-auto-capture.sh --staged $ROOT/AGENTS.md")" '.decision == "allow"'
as_exec "executor auto-capture with granted memory store is allowed" "$(bash_payload "bash $KNOW/memory-auto-capture.sh --store $ROOT/.agents/memory --staged $CHILD/README.md")" '.decision == "allow"'
as_exec "executor auto-capture repeated staged inputs are allowed" "$(bash_payload "bash $KNOW/memory-auto-capture.sh --staged $CHILD/README.md --staged $CHILD/README.md")" '.decision == "allow"'
as_review "reviewer auto-capture is denied" "$(bash_payload "bash $KNOW/memory-auto-capture.sh --staged $CHILD/README.md")" '.decision == "deny" and .rule == "coordination.write"'
as_exec "auto-capture outside staged path is denied" "$(bash_payload "bash $KNOW/memory-auto-capture.sh --staged /etc/hosts")" '.decision == "deny" and .rule == "helper.argv"'
as_exec "auto-capture foreign store is denied" "$(bash_payload "bash $KNOW/memory-auto-capture.sh --store /tmp/foreign --staged $CHILD/README.md")" '.decision == "deny" and .rule == "helper.argv"'
as_exec "auto-capture batch directory is outside reviewed grammar" "$(bash_payload "bash $KNOW/memory-auto-capture.sh --batch-dir $CHILD")" '.decision == "deny" and .rule == "helper.argv"'
as_exec "auto-capture purge is outside reviewed grammar" "$(bash_payload "bash $KNOW/memory-auto-capture.sh --purge --confirm $ROOT/.agents/memory")" '.decision == "deny" and .rule == "helper.argv"'
as_exec "auto-capture missing staged value is denied" "$(bash_payload "bash $KNOW/memory-auto-capture.sh --staged")" '.decision == "deny" and .rule == "helper.argv"'
as_master "orchestrator workspace-stop --confirmed is allowed" "$(bash_payload "bash $WS/workspace-stop.sh development --confirmed")" '.decision == "allow"'
as_master "orchestrator workspace.sh start via dispatcher is allowed" "$(bash_payload "bash $WS/workspace.sh start --no-attach")" '.decision == "allow"'
as_master "orchestrator workspace start with a foreign --config is denied" "$(bash_payload "bash $WS/workspace-start.sh --config /tmp/other.json")" '.decision == "deny" and .rule == "helper.argv"'
echo "== single service panes (--pane) =="
# A services session beside the golden topology: a browser and a dev server
# (role service) plus a non-service tool pane, so --pane resolution, the
# service-only rule, and every refused shape are exercised against a real plan.
SVC_CONFIG="$ROOT/.agent-workspace/services.json"
jq '.roles.service = {"runtime":"shell","env_group":"none"} | .roles.tooling = {"runtime":"shell","env_group":"none"}
  | .browser = {"session_id":"services","pane_name":"${PROJECT_ID}-browser","port":9326,"chrome_program":"true","mcp_package":"chrome-devtools-mcp@1.2.3"}
  | .sessions += [{"id":"services","name":"${PROJECT_ID}-services","panes":[
      {"name":"${PROJECT_ID}-browser","role":"service","cwd":".","idle_stop_minutes":30},
      {"name":"${PROJECT_ID}-web","role":"service","cwd":".","command":["npm","run","dev"],"port":3001},
      {"name":"${PROJECT_ID}-tool","role":"tooling","cwd":"."}]}]' "$CONFIG" > "$SVC_CONFIG"
as_master_svc() { expect "$1" master "$MASTER_PANE" "$ROOT" "$SVC_CONFIG" enforce "$2" "$3"; }
as_exec_svc() { expect "$1" executor "$EXEC_PANE" "$CHILD" "$SVC_CONFIG" enforce "$2" "$3"; }
as_review_svc() { expect "$1" reviewer "$REVIEW_PANE" "$CHILD" "$SVC_CONFIG" enforce "$2" "$3"; }
as_master_svc "orchestrator start --pane (short name) is allowed" "$(bash_payload "bash $WS/workspace-start.sh services --pane browser")" '.decision == "allow"'
as_master_svc "orchestrator start --pane (full name, repeated pane flag, --no-attach, own --config) is allowed" "$(bash_payload "bash $WS/workspace-start.sh services --pane harness-sample-browser --pane web --no-attach --config $SVC_CONFIG")" '.decision == "allow"'
as_master_svc "orchestrator start --pane via dispatcher is allowed" "$(bash_payload "bash $WS/workspace.sh start services --pane browser")" '.decision == "allow"'
as_master_svc "orchestrator stop --pane --confirmed is allowed" "$(bash_payload "bash $WS/workspace-stop.sh services --pane browser --confirmed")" '.decision == "allow"'
as_master_svc "orchestrator stop --pane via dispatcher is allowed" "$(bash_payload "bash $WS/workspace.sh stop services --pane web --confirmed")" '.decision == "allow"'
as_master_svc "orchestrator status --pane --json is allowed" "$(bash_payload "bash $WS/workspace-status.sh services --pane browser --json")" '.decision == "allow"'
as_master_svc "orchestrator plan --json --running is allowed" "$(bash_payload "bash $WS/workspace-plan.sh --json --running")" '.decision == "allow"'
as_master_svc "orchestrator start --pane without a session is denied" "$(bash_payload "bash $WS/workspace-start.sh --pane browser")" '.decision == "deny" and .rule == "helper.argv"'
as_master_svc "orchestrator start all --pane is denied" "$(bash_payload "bash $WS/workspace-start.sh all --pane browser")" '.decision == "deny" and .rule == "helper.argv"'
as_master_svc "orchestrator start --pane of an unknown pane is denied" "$(bash_payload "bash $WS/workspace-start.sh services --pane nope")" '.decision == "deny" and .rule == "helper.argv"'
as_master_svc "orchestrator start --pane of a pane in another session is denied" "$(bash_payload "bash $WS/workspace-start.sh services --pane master")" '.decision == "deny" and .rule == "helper.argv"'
as_master_svc "orchestrator start --pane of an agent pane is denied" "$(bash_payload "bash $WS/workspace-start.sh development --pane master")" '.decision == "deny" and .rule == "helper.argv" and (.reason | contains("service panes only"))'
as_master_svc "orchestrator start --pane of a non-service pane is denied" "$(bash_payload "bash $WS/workspace-start.sh services --pane tool")" '.decision == "deny" and .rule == "helper.argv" and (.reason | contains("service panes only"))'
as_master_svc "orchestrator start --pane naming one pane twice is denied" "$(bash_payload "bash $WS/workspace-start.sh services --pane browser --pane harness-sample-browser")" '.decision == "deny" and .rule == "helper.argv"'
for extra in "--adopt --confirmed" "--no-services" "--no-agents" "--confirmed"; do
  as_master_svc "orchestrator start --pane with $extra is denied" "$(bash_payload "bash $WS/workspace-start.sh services --pane browser $extra")" '.decision == "deny" and .rule == "helper.argv"'
done
as_master_svc "orchestrator start --pane with no value is denied" "$(bash_payload "bash $WS/workspace-start.sh services --pane")" '.decision == "deny" and .rule == "helper.argv"'
as_master_svc "orchestrator start --pane with a path-like value is denied" "$(bash_payload "bash $WS/workspace-start.sh services --pane ../browser")" '.decision == "deny" and .rule == "helper.argv"'
as_master_svc "orchestrator start --pane with an expansion is denied" "$(bash_payload "bash $WS/workspace-start.sh services --pane \$PANE")" '.decision == "deny" and .rule == "helper.segment"'
as_master_svc "orchestrator stop --pane without --confirmed is denied" "$(bash_payload "bash $WS/workspace-stop.sh services --pane browser")" '.decision == "deny" and .rule == "helper.argv"'
as_master_svc "orchestrator stop --pane with --all is denied" "$(bash_payload "bash $WS/workspace-stop.sh services --pane browser --confirmed --all")" '.decision == "deny" and .rule == "helper.argv"'
as_master_svc "orchestrator stop --pane with --no-save is denied" "$(bash_payload "bash $WS/workspace-stop.sh services --pane browser --confirmed --no-save")" '.decision == "deny" and .rule == "helper.argv"'
as_master_svc "orchestrator stop --expect-pane-id (idle watcher only) is denied" "$(bash_payload "bash $WS/workspace-stop.sh services --pane browser --confirmed --expect-pane-id %3")" '.decision == "deny" and .rule == "helper.argv"'
as_master_svc "orchestrator status --pane without a session is denied" "$(bash_payload "bash $WS/workspace-status.sh --pane browser")" '.decision == "deny" and .rule == "helper.argv"'
as_master_svc "orchestrator restart --pane is outside the grammar" "$(bash_payload "bash $WS/workspace-restart.sh services --pane browser")" '.decision == "deny" and .rule == "helper.argv"'
as_exec_svc "executor start --pane helper is denied" "$(bash_payload "bash $WS/workspace-start.sh services --pane browser")" '.decision == "deny" and .rule == "coordination.write"'
as_exec_svc "executor stop --pane helper is denied" "$(bash_payload "bash $WS/workspace-stop.sh services --pane browser --confirmed")" '.decision == "deny" and .rule == "coordination.write"'
as_review_svc "reviewer start --pane helper is denied" "$(bash_payload "bash $WS/workspace.sh start services --pane browser")" '.decision == "deny" and .rule == "coordination.write"'
as_exec_svc "executor status --pane helper stays allowed" "$(bash_payload "bash $WS/workspace-status.sh services --pane browser --json")" '.decision == "allow"'
# The PATH dispatcher (workspace-install), the project shim and a lifecycle
# script run by name reach the same engine; a child role is refused on every
# route, while read verbs stay available.
for route in "workspace start services --pane browser" "workspace stop services --pane browser --confirmed" "workspace stop all --confirmed --all" \
             "workspace restart services" "workspace reconcile --apply" "env workspace start" "bash /usr/local/bin/workspace stop services --confirmed" \
             "./.agent-workspace/workspace.sh start services" "workspace-stop.sh services --confirmed" "sh workspace-start.sh services" \
             "workspace-environment.sh start --environment x"; do
  as_exec_svc "executor lifecycle via '$route' is denied" "$(bash_payload "$route")" '.decision == "deny" and .rule == "coordination.write"'
done
as_review_svc "reviewer lifecycle via the PATH dispatcher is denied" "$(bash_payload "workspace stop services --pane browser --confirmed")" '.decision == "deny" and .rule == "coordination.write"'
as_exec_svc "executor read verb via the PATH dispatcher stays allowed" "$(bash_payload "workspace status services --pane browser")" '.decision == "allow"'
as_exec_svc "executor plan via the PATH dispatcher stays allowed" "$(bash_payload "workspace plan --json --running")" '.decision == "allow"'
as_exec_svc "executor naming a lifecycle script as an operand is a read, not a run" "$(bash_payload "cat workspace-start.sh")" '.decision == "allow"'
as_master_svc "orchestrator PATH dispatcher keeps its free shell" "$(bash_payload "workspace start services --pane browser")" '.decision == "allow"'
as_master "orchestrator workspace install --target is allowed" "$(bash_payload "bash $WS/workspace-install.sh --target /usr/local/bin/workspace --dry-run")" '.decision == "allow"'
as_master "orchestrator browser-config with a bad provider is denied" "$(bash_payload "bash $WS/workspace-browser-config.sh --provider vim")" '.decision == "deny" and .rule == "helper.argv"'
as_master "orchestrator session delete requires --confirmed" "$(bash_payload "bash $SM/delete-session.sh 123e4567-e89b-12d3-a456-426614174000")" '.decision == "deny" and .rule == "helper.argv"'
as_master "orchestrator session delete with uuid and --confirmed is allowed" "$(bash_payload "bash $SM/delete-session.sh 123e4567-e89b-12d3-a456-426614174000 --confirmed")" '.decision == "allow"'
as_review "reviewer session-manager helper is denied" "$(bash_payload "bash $SM/list-sessions.sh")" '.decision == "deny" and .rule == "coordination.write"'
as_review "reviewer memory-lint --fix is denied" "$(bash_payload "bash $KNOW/memory-lint.sh --fix")" '.decision == "deny" and .rule == "helper.argv"'
as_master "orchestrator broadcast is denied (no topology-bound routing possible)" "$(bash_payload "bash $CLAUDE_CACHE/session-chat/1.2.3/scripts/broadcast-message.sh --all 'standup'")" '.decision == "deny" and .rule == "helper.allowlist"'
as_master "orchestrator helper chained with a child mutation is still refused" "$(bash_payload "bash $SEND $EXEC_PANE hi && rm component-a/src/file.ts")" '.decision == "deny" and .rule == "helper.segment"'

echo "== orchestrator: wrapped push and attached child cwd options =="
as_master "orchestrator env git push is denied" "$(bash_payload 'env git push origin main')" '.decision == "deny" and .rule == "orchestrator.push"'
as_master "orchestrator command git push is denied" "$(bash_payload 'command git push')" '.decision == "deny" and .rule == "orchestrator.push"'
as_master "orchestrator assignment-prefixed git push is denied" "$(bash_payload 'GIT_CONFIG_NOSYSTEM=1 git push origin main')" '.decision == "deny" and .rule == "orchestrator.push"'
as_master "orchestrator exec git push is denied" "$(bash_payload 'exec git push')" '.decision == "deny" and .rule == "orchestrator.push"'
as_master "orchestrator nohup git push is denied" "$(bash_payload 'nohup git push origin main')" '.decision == "deny" and .rule == "orchestrator.push"'
as_master "orchestrator env -u VAR git push is denied" "$(bash_payload 'env -u GIT_DIR git push')" '.decision == "deny" and .rule == "orchestrator.push"'
as_master "orchestrator env -Cchild npm test is denied" "$(bash_payload 'env -Ccomponent-a npm test')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator git -Cchild clean -fd is denied" "$(bash_payload 'git -Ccomponent-a clean -fd')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator make -Cchild clean is denied" "$(bash_payload 'make -Ccomponent-a clean')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator env --chdir=child mutation is denied" "$(bash_payload 'env --chdir=component-a rm -rf dist')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator git -C child read-only log is allowed" "$(bash_payload 'git -Ccomponent-a log -n 3')" '.decision == "allow"'
as_master "orchestrator env-wrapped read of a child is allowed" "$(bash_payload 'env cat component-a/README.md')" '.decision == "allow"'
as_master "orchestrator command git status on its root is allowed" "$(bash_payload 'command git status')" '.decision == "allow"'

echo "== wrapper-prefixed cd and separated env cwd values =="
as_exec "executor env -C .. (separated) then rm sibling is denied" "$(bash_payload 'env -C .. rm component-b/secret.ts')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor env --chdir .. (separated) then rm sibling is denied" "$(bash_payload 'env --chdir .. rm component-b/secret.ts')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor env -C src (inside) is allowed" "$(bash_payload 'env -C src ls')" '.decision == "allow"'
as_exec "executor env -C src then ../escape operand is resolved against the env cwd and denied" "$(bash_payload 'env -C src cat ../escape-link')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor command cd . then truncate through a bare escaping symlink is denied" "$(bash_payload 'command cd . && truncate -s0 escape-link')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor builtin cd . then cat escaping symlink is denied" "$(bash_payload 'builtin cd . && cat escape-link')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor command cd src then ls . is allowed (cwd tracked through the wrapper)" "$(bash_payload 'command cd src && ls .')" '.decision == "allow"'
as_exec "executor command pushd .. then rm sibling is denied" "$(bash_payload 'command pushd .. && rm component-b/secret.ts')" '.decision == "deny" and .rule == "executor.containment"'
as_master "orchestrator command cd child then build is denied" "$(bash_payload 'command cd component-a && npm test')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator builtin cd child then build is denied" "$(bash_payload 'builtin cd component-a && npm test')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator command pushd child then build is denied" "$(bash_payload 'command pushd component-a && npm test')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator env -C child (separated) build is denied" "$(bash_payload 'env -C component-a npm test')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator env --chdir child (separated) rm is denied" "$(bash_payload 'env --chdir component-a rm -rf dist')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator env -C child read-only git is allowed" "$(bash_payload 'env -C component-a git status')" '.decision == "allow"'
as_master "orchestrator command cd child then read is allowed" "$(bash_payload 'command cd component-a && cat README.md')" '.decision == "allow"'

echo "== privilege wrappers are refused for every role =="
as_exec "executor sudo -D .. rm sibling is denied" "$(bash_payload 'sudo -D .. rm component-b/secret.ts')" '.decision == "deny" and .rule == "shell.privilege"'
as_exec "executor sudo -u root tmux send-keys is denied" "$(bash_payload "sudo -u root tmux send-keys -t $MASTER_PANE hi Enter")" '.decision == "deny" and .rule == "shell.privilege"'
as_exec "executor doas -u root tmux send-keys is denied" "$(bash_payload "doas -u root tmux send-keys -t $MASTER_PANE hi Enter")" '.decision == "deny" and .rule == "shell.privilege"'
as_exec "executor sudo-wrapped inline shell is denied" "$(bash_payload "sudo bash -c 'rm -rf /tmp/x'")" '.decision == "deny" and .rule == "shell.privilege"'
as_exec "executor env-wrapped sudo is denied" "$(bash_payload 'env sudo ls')" '.decision == "deny" and .rule == "shell.privilege"'
as_exec "executor command-wrapped doas is denied" "$(bash_payload 'command doas ls')" '.decision == "deny" and .rule == "shell.privilege"'
as_exec "executor assignment-prefixed sudo is denied" "$(bash_payload 'FOO=1 sudo ls')" '.decision == "deny" and .rule == "shell.privilege"'
as_exec "executor sudo in a later segment is denied" "$(bash_payload 'ls && sudo rm x')" '.decision == "deny" and .rule == "shell.privilege"'
as_exec "executor su is denied" "$(bash_payload 'su -c ls')" '.decision == "deny" and .rule == "shell.privilege"'
as_exec "executor the word sudo as data is not a wrapper" "$(bash_payload "grep -rn 'sudo' src")" '.decision == "allow"'
as_review "reviewer sudo cat is denied" "$(bash_payload 'sudo cat README.md')" '.decision == "deny" and .rule == "shell.privilege"'
as_master "orchestrator sudo -u root git push is denied" "$(bash_payload 'sudo -u root git push origin main')" '.decision == "deny" and .rule == "shell.privilege"'
as_master "orchestrator doas git push is denied" "$(bash_payload 'doas git push')" '.decision == "deny" and .rule == "shell.privilege"'
as_master "orchestrator sudo-wrapped helper invocation is denied" "$(bash_payload "sudo bash $SEND $EXEC_PANE hi")" '.decision == "deny" and .rule == "shell.privilege"'
as_master "orchestrator pkexec is denied" "$(bash_payload 'pkexec ls')" '.decision == "deny" and .rule == "shell.privilege"'

echo "== one strict wrapper grammar for every role =="
as_exec "executor exec -a fake tmux send-keys is denied" "$(bash_payload "exec -a fake tmux send-keys -t $MASTER_PANE hi Enter")" '.decision == "deny" and .rule == "shell.wrapper"'
as_exec "executor exec -l tmux is denied" "$(bash_payload "exec -l tmux send-keys -t $MASTER_PANE hi")" '.decision == "deny" and .rule == "shell.wrapper"'
as_exec "executor nohup -- tmux is denied" "$(bash_payload "nohup -- tmux send-keys -t $MASTER_PANE hi")" '.decision == "deny" and .rule == "shell.wrapper"'
as_exec "executor env -S quoted command is denied (re-parsed argv)" "$(bash_payload "env -S 'tmux send-keys -t $MASTER_PANE hi'")" '.decision == "deny" and .rule == "shell.wrapper"'
as_exec "executor env --split-string= is denied" "$(bash_payload "env --split-string='tmux send-keys -t $MASTER_PANE hi'")" '.decision == "deny" and .rule == "shell.wrapper"'
as_exec "executor time -p is denied" "$(bash_payload 'time -p npm test')" '.decision == "deny" and .rule == "shell.wrapper"'
as_exec "executor env --default-signal is denied (unreviewed option)" "$(bash_payload 'env --default-signal npm test')" '.decision == "deny" and .rule == "shell.wrapper"'
as_exec "executor env -u without a name is denied" "$(bash_payload 'env -u')" '.decision == "deny" and .rule == "shell.wrapper"'
as_exec "executor env --unset= with an empty name is denied" "$(bash_payload 'env --unset= npm test')" '.decision == "deny" and .rule == "shell.wrapper"'
as_exec "executor env --unset=BAD-NAME is denied" "$(bash_payload 'env --unset=BAD-NAME npm test')" '.decision == "deny" and .rule == "shell.wrapper"'
as_exec "executor builtin -x is denied (unreviewed option)" "$(bash_payload 'builtin -x cd src')" '.decision == "deny" and .rule == "shell.wrapper"'
as_exec "executor runuser is denied" "$(bash_payload 'runuser -u root ls')" '.decision == "deny" and .rule == "shell.privilege"'
as_exec "executor bare time wrapper is allowed" "$(bash_payload 'time npm test')" '.decision == "allow"'
as_exec "executor env -i / -u wrappers are allowed" "$(bash_payload 'env -i -u FOO --unset=BAR npm test')" '.decision == "allow"'
as_exec "executor bare nohup wrapper is allowed" "$(bash_payload 'nohup npm test')" '.decision == "allow"'
as_exec "executor bare exec wrapper is allowed" "$(bash_payload 'exec npm test')" '.decision == "allow"'
as_exec "executor command -v query is allowed" "$(bash_payload 'command -v jq')" '.decision == "allow"'
as_exec "executor command -p is denied (unreviewed option)" "$(bash_payload 'command -p ls')" '.decision == "deny" and .rule == "shell.wrapper"'
as_exec "executor wrapped inline shell is still inline code" "$(bash_payload "nohup bash -c 'rm x'")" '.decision == "deny" and .rule == "executor.inline_code"'
as_review "reviewer env -S is denied" "$(bash_payload "env -S 'cat README.md'")" '.decision == "deny"'
as_review "reviewer time git status is denied (wrapper)" "$(bash_payload 'time git status')" '.decision == "deny" and .rule == "reviewer.shell"'
as_master "orchestrator exec -a x git push is denied" "$(bash_payload 'exec -a x git push')" '.decision == "deny" and .rule == "shell.wrapper"'
as_master "orchestrator exec -l git push is denied" "$(bash_payload 'exec -l git push')" '.decision == "deny" and .rule == "shell.wrapper"'
as_master "orchestrator /usr/bin/time -o file git push is denied" "$(bash_payload '/usr/bin/time -o timing.txt git push')" '.decision == "deny" and .rule == "shell.wrapper"'
as_master "orchestrator nohup -- git push is denied" "$(bash_payload 'nohup -- git push')" '.decision == "deny" and .rule == "shell.wrapper"'
as_master "orchestrator env -S git push is denied" "$(bash_payload "env -S 'git push'")" '.decision == "deny" and .rule == "shell.wrapper"'
as_master "orchestrator env --split-string= git push is denied" "$(bash_payload "env --split-string='git push origin main'")" '.decision == "deny" and .rule == "shell.wrapper"'
as_master "orchestrator runuser git push is denied" "$(bash_payload 'runuser -u root git push')" '.decision == "deny" and .rule == "shell.privilege"'
as_master "orchestrator time git status is allowed" "$(bash_payload 'time git status')" '.decision == "allow"'
as_master "orchestrator /usr/bin/time git status is allowed (bare, path-written wrapper)" "$(bash_payload '/usr/bin/time git status')" '.decision == "allow"'
as_master "orchestrator env -C child time npm test is denied" "$(bash_payload 'env -C component-a time npm test')" '.decision == "deny" and .rule == "orchestrator.child_write"'

echo "== nested env -C hops compose (each hop resolved against the previous) =="
mkdir -p "$CHILD/src/inner" "$CHILD/safe" "$ROOT/wrap/other" "$ROOT/safe" "$TMPROOT/outside-dir"
ln -s "$TMPROOT/outside-dir" "$CHILD/src/safe"
ln -s "$CHILD" "$ROOT/wrap/safe"
as_exec "executor nested env -C through a symlinked second hop escaping cwd is denied" "$(bash_payload 'env -C src env -C safe truncate -s 0 target')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor nested env -C with mixed attached/long forms escaping cwd is denied" "$(bash_payload 'env -Csrc env --chdir=safe rm target')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor nested env -C hops staying inside cwd are allowed (positive control)" "$(bash_payload 'env -C src env -C inner ls')" '.decision == "allow"'
as_exec "executor single env -C safe (root-local real dir) is allowed (control for the symlink case)" "$(bash_payload 'env -C safe ls')" '.decision == "allow"'
as_exec "executor three composed hops escaping via .. are denied" "$(bash_payload 'env -C src env -C inner env -C ../../.. ls')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor operand resolved against the composed cwd is denied" "$(bash_payload 'env -C src env -C inner cat ../../escape-link')" '.decision == "deny" and .rule == "executor.containment"'
as_master "orchestrator nested env -C landing in a child through a symlink is denied" "$(bash_payload 'env -C wrap env -C safe npm test')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator nested env -C landing root-local is allowed (positive control)" "$(bash_payload 'env -C wrap env -C other npm test')" '.decision == "allow"'
as_master "orchestrator single env -C safe (root-local) is allowed (control)" "$(bash_payload 'env -C safe npm test')" '.decision == "allow"'
as_master "orchestrator nested env -C into a child then read-only git is allowed" "$(bash_payload 'env -C wrap env -C safe git status')" '.decision == "allow"'

echo "== repeated -C within ONE env: last wins against that env's starting cwd =="
ln -s "$TMPROOT/outside-dir" "$CHILD/repeat-safe"
ln -s "$CHILD" "$ROOT/repeat-child"
as_exec "executor repeated separated -C (last is an escaping symlink) is denied" "$(bash_payload 'env -C src -C repeat-safe truncate -s 0 target')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor repeated attached -C (last escapes) is denied" "$(bash_payload 'env -Csrc -Crepeat-safe truncate -s 0 target')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor repeated mixed --chdir/-C (last escapes) is denied" "$(bash_payload 'env --chdir src -Crepeat-safe truncate -s 0 target')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor repeated -C where an EARLIER value escapes is still denied (every value checked)" "$(bash_payload 'env -C .. -C src ls')" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor repeated -C both inside is allowed (last wins, positive control)" "$(bash_payload 'env -C safe -C src ls')" '.decision == "allow"'
as_exec "executor operand resolved against the LAST -C (not composed) is allowed" "$(bash_payload 'env -C safe -C src cat inner/x.ts')" '.decision == "allow"'
as_master "orchestrator repeated -C landing in a child (last is a child symlink) is denied" "$(bash_payload 'env -C wrap -C repeat-child npm test')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator repeated -C where the last is root-local is allowed (not composed through wrap/safe)" "$(bash_payload 'env -C wrap -C safe npm test')" '.decision == "allow"'
as_master "orchestrator nested env hops still compose (wrap then safe -> child) and deny" "$(bash_payload 'env -C wrap env -C safe npm test')" '.decision == "deny" and .rule == "orchestrator.child_write"'

echo "== delivered-message reads: own dispatches/drafts only, no aliases or store traversal =="
# A delivered dispatch is <epoch>-<pid>-<id>-<from>-to-<to>.md written 0600 at
# the top of the granted messages root. Endpoints must resolve to exactly one
# pair of validated plan panes; this pane must be one of them.
MSG="$ROOT/.tmp/messages"
mkmsg() { printf 'task body %s\n' "$1" > "$MSG/$1"; chmod "${2:-600}" "$MSG/$1"; }
TO_EXEC="1700000000-101-abcdef01-$MASTER_PANE-to-$EXEC_PANE.md"
FROM_EXEC="1700000000-102-abcdef02-$EXEC_PANE-to-$MASTER_PANE.md"
TO_REVIEW="1700000000-103-abcdef03-$MASTER_PANE-to-$REVIEW_PANE.md"
OFF_PLAN="1700000000-104-abcdef04-stranger-to-$EXEC_PANE.md"
LOOSE="1700000000-105-abcdef05-$MASTER_PANE-to-$EXEC_PANE.md"
HARD="1700000000-106-abcdef06-$MASTER_PANE-to-$EXEC_PANE.md"
LINKED="1700000000-107-abcdef07-$MASTER_PANE-to-$EXEC_PANE.md"
BAD_ID="1700000000-108-NOTHEX00-$MASTER_PANE-to-$EXEC_PANE.md"
mkmsg "$TO_EXEC"; mkmsg "$FROM_EXEC"; mkmsg "$TO_REVIEW"; mkmsg "$OFF_PLAN"; mkmsg "$LOOSE" 644; mkmsg "$HARD"; mkmsg "$BAD_ID"
ln "$MSG/$HARD" "$TMPROOT/hardlink-copy.md"
ln -s "$MSG/$TO_EXEC" "$MSG/$LINKED"
mkdir -p "$MSG/archive" "$MSG/drafts/$EXEC_PANE"
printf 'archived\n' > "$MSG/archive/$TO_EXEC"; chmod 600 "$MSG/archive/$TO_EXEC"
printf 'my draft\n' > "$MSG/drafts/$EXEC_PANE/plan.md"
printf 'sched\n' > "$ROOT/.tmp/scheduler/state.json"
ln -s "$MSG" "$CHILD/msg-alias"
M_READ='.decision == "allow" and .rule == "coordination.message_read"'
M_DENY='.decision == "deny" and .rule == "coordination.message_read"'
M_WALK='.decision == "deny" and .rule == "coordination.message_traversal"'
as_exec "executor cat of a dispatch addressed to it is allowed" "$(bash_payload "cat $MSG/$TO_EXEC")" "$M_READ"
as_exec "executor head of a dispatch it sent is allowed" "$(bash_payload "head -n 5 $MSG/$FROM_EXEC")" "$M_READ"
as_exec "executor wc of its dispatch is allowed" "$(bash_payload "wc -l $MSG/$TO_EXEC")" "$M_READ"
as_exec "executor rg of an explicit dispatch file is allowed" "$(bash_payload "rg --no-config -n body $MSG/$TO_EXEC")" "$M_READ"
as_exec "executor Codex argv-shaped dispatch read is allowed" "$(jq -cn --arg f "$MSG/$TO_EXEC" '{tool_name:"shell",tool_input:{command:["cat",$f]}}')" "$M_READ"
as_exec "executor read of a peer-to-peer dispatch is denied" "$(bash_payload "cat $MSG/$TO_REVIEW")" "$M_DENY"
as_exec "executor read of a dispatch from an off-plan sender is denied" "$(bash_payload "cat $MSG/$OFF_PLAN")" "$M_DENY"
as_exec "executor read of a group/other-readable dispatch is denied" "$(bash_payload "cat $MSG/$LOOSE")" "$M_DENY"
as_exec "executor read of a hardlinked dispatch is denied" "$(bash_payload "cat $MSG/$HARD")" "$M_DENY"
as_exec "executor read of a symlinked dispatch name is denied" "$(bash_payload "cat $MSG/$LINKED")" "$M_DENY"
as_exec "executor read of a non-hex message id is denied" "$(bash_payload "cat $MSG/$BAD_ID")" "$M_DENY"
as_exec "executor read of an own-named file in a store subdirectory is denied" "$(bash_payload "cat $MSG/archive/$TO_EXEC")" "$M_DENY"
as_exec "executor read through a symlinked store directory is denied" "$(bash_payload "cat msg-alias/$TO_EXEC")" "$M_DENY"
as_exec "executor read through a ../ alias is denied" "$(bash_payload "cat ../.tmp/messages/$TO_EXEC")" "$M_DENY"
as_exec "executor ls of the messages root is denied" "$(bash_payload "ls $MSG")" "$M_DENY"
as_exec "executor read of its own existing draft is allowed" "$(bash_payload "cat $MSG/drafts/$EXEC_PANE/plan.md")" "$M_READ"
as_exec "executor read of a missing own draft is denied" "$(bash_payload "cat $MSG/drafts/$EXEC_PANE/absent.md")" "$M_DENY"
as_exec "executor read of the reviewer's draft is denied" "$(bash_payload "cat $MSG/drafts/$REVIEW_PANE/review.md")" "$M_DENY"
as_exec "executor git read of its dispatch is denied (no Git message grant)" "$(bash_payload "git diff --no-index $MSG/$TO_EXEC README.md")" "$M_DENY"
as_exec "executor sort of dispatch content is allowed" "$(bash_payload "sort $MSG/$TO_EXEC")" "$M_READ"
as_exec "executor sort cannot treat dispatch as file operands" "$(bash_payload "sort --files0-from=$MSG/$TO_EXEC")" "$M_DENY"
as_review "reviewer sort of dispatch content is allowed" "$(bash_payload "sort $MSG/$TO_REVIEW")" "$M_READ"
as_review "reviewer du cannot treat dispatch as file operands" "$(bash_payload "du --files0-from=$MSG/$TO_REVIEW")" '.decision == "deny" and .rule == "reviewer.file_list"'
as_review "reviewer reads its dispatch by one command, never in a pipeline" "$(bash_payload "cat $MSG/$TO_REVIEW | head -n 1")" "$M_DENY"
for list_command in "sort --files0=$MSG/$TO_EXEC" "sort --fil=$MSG/$TO_EXEC" "wc --f=$MSG/$TO_EXEC"; do
  as_exec "executor message file-list abbreviation denied: $list_command" "$(bash_payload "$list_command")" "$M_DENY"
done
printf '%s\0' "$MSG/$TO_EXEC" > "$CHILD/list.txt"
as_review "reviewer plain sort content control" "$(bash_payload 'sort list.txt')" '.decision == "allow"'
as_review "reviewer wc plain file control" "$(bash_payload 'wc -l list.txt')" '.decision == "allow"'
as_review "reviewer du plain file control" "$(bash_payload 'du list.txt')" '.decision == "allow"'
as_review "reviewer find literal starting path control" "$(bash_payload 'find src')" '.decision == "allow"'
for list_command in 'sort --files0-from=list.txt' 'sort --files0=list.txt' 'sort --fil=list.txt' \
    'du --files0-from=list.txt' 'du --f=list.txt' 'wc --files0-from=list.txt' 'wc --f=list.txt' 'find -files0-from list.txt'; do
  as_review "reviewer file-list operand denied: $list_command" "$(bash_payload "$list_command")" '.decision == "deny" and .rule == "reviewer.file_list"'
done
as_exec "executor ordinary in-checkout file-list floor remains unchanged" "$(bash_payload 'sort --files0-from=list.txt')" '.decision == "allow" and .rule != "coordination.message_read"'
as_exec "executor piped dispatch read stays under the shell floor" "$(bash_payload "cat $MSG/$TO_EXEC | head -n 1")" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor copy of its dispatch into the checkout is denied" "$(bash_payload "cp $MSG/$TO_EXEC notes.md")" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor copy of a peer dispatch is denied as a message read" "$(bash_payload "cp $MSG/$TO_REVIEW notes.md")" "$M_DENY"
as_exec "executor redirect into its dispatch is denied" "$(bash_payload "printf x >> $MSG/$TO_EXEC")" '.decision == "deny" and .rule == "executor.containment"'
as_exec "executor edit of a delivered dispatch is denied" "$(edit_payload "$MSG/$TO_EXEC")" '.decision == "deny" and .rule == "coordination.draft"'
as_exec "executor edit of its own draft stays allowed" "$(edit_payload "$MSG/drafts/$EXEC_PANE/plan.md")" '.decision == "allow"'
as_exec "executor tool workdir inside the messages root is denied" "$(jq -cn --arg d "$MSG" --arg c "cat $TO_EXEC" '{tool_name:"Bash",tool_input:{command:$c,workdir:$d}}')" "$M_WALK"
as_exec "executor scheduler store read stays denied" "$(bash_payload "cat $ROOT/.tmp/scheduler/state.json")" '.decision == "deny" and .rule == "executor.containment"'
as_review "reviewer cat of a dispatch addressed to it is allowed" "$(bash_payload "cat $MSG/$TO_REVIEW")" "$M_READ"
as_review "reviewer read of the executor's dispatch is denied" "$(bash_payload "cat $MSG/$TO_EXEC")" "$M_DENY"
as_review "reviewer read of its own existing draft is allowed" "$(bash_payload "cat $MSG/drafts/$REVIEW_PANE/review.md")" "$M_READ"
as_review "reviewer read of the executor's draft is denied" "$(bash_payload "cat $MSG/drafts/$EXEC_PANE/plan.md")" "$M_DENY"
as_review "reviewer recursive search of the messages root is denied" "$(bash_payload "rg --no-config body $MSG")" '.decision == "deny" and (.rule == "coordination.message_read" or .rule == "coordination.message_traversal")'
as_review "reviewer find over the messages root is denied" "$(bash_payload "find $MSG -name '*.md'")" '.decision == "deny" and (.rule == "coordination.message_read" or .rule == "coordination.message_traversal")'
as_review "reviewer git log of its dispatch is denied" "$(bash_payload "git log -- $MSG/$TO_REVIEW")" "$M_DENY"
as_review "reviewer tool workdir inside the messages root is denied" "$(jq -cn --arg d "$MSG" --arg c "cat $TO_REVIEW" '{tool_name:"Bash",tool_input:{command:$c,workdir:$d}}')" '.decision == "deny"'
as_review "reviewer non-message grant root read is unchanged" "$(bash_payload "cat $ROOT/.tmp/scheduler/state.json")" '.decision == "allow"'
as_review "reviewer ordinary checkout read carries no message rule" "$(bash_payload 'cat README.md')" '.decision == "allow" and .rule != "coordination.message_read"'
expect "reviewer without a messages grant cannot read its dispatch" reviewer "$REVIEW_PANE" "$CHILD" "$NO_MESSAGES_CONFIG" enforce "$(bash_payload "cat $MSG/$TO_REVIEW")" '.decision == "deny"'

# Topology: a delimiter split must be unique across ALL validated plan panes.
AMBIG_CONFIG="$ROOT/.agent-workspace/ambiguous.json"
jq '.sessions[0].panes += [{name:"${PROJECT_ID}-master-to-x",role:"executor",cwd:"component-b"},{name:"x-to-${PROJECT_ID}-component-reviewer",role:"reviewer",cwd:"component-b"}]' "$CONFIG" > "$AMBIG_CONFIG"
AMBIG="1700000000-109-abcdef09-$MASTER_PANE-to-x-to-$REVIEW_PANE.md"
mkmsg "$AMBIG"
expect "reviewer dispatch with two valid endpoint splits is denied" reviewer "$REVIEW_PANE" "$CHILD" "$AMBIG_CONFIG" enforce "$(bash_payload "cat $MSG/$AMBIG")" "$M_DENY"
expect "reviewer unambiguous dispatch control under the same topology" reviewer "$REVIEW_PANE" "$CHILD" "$AMBIG_CONFIG" enforce "$(bash_payload "cat $MSG/$TO_REVIEW")" "$M_READ"
expect "reviewer dispatch with the ambiguous name is denied under the base topology control" reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(bash_payload "cat $MSG/$AMBIG")" "$M_DENY"
SUFFIX="1700000000-110-abcdef0a-$MASTER_PANE-to-x-to-$EXEC_PANE.md"
mkmsg "$SUFFIX"
expect "executor name-suffix match to an unknown recipient is denied" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(bash_payload "cat $MSG/$SUFFIX")" "$M_DENY"

# Store under the executor cwd (messages override inside the checkout):
# explicit own reads work, peer reads and every traversal of the store do not.
INCWD_CONFIG="$ROOT/.agent-workspace/messages-in-checkout.json"
jq '.stores.overrides.messages = "component-a/.msgs"' "$CONFIG" > "$INCWD_CONFIG"
IMSG="$CHILD/.msgs"
mkdir -p "$IMSG"
for name in "$TO_EXEC" "$TO_REVIEW"; do printf 'task body\n' > "$IMSG/$name"; chmod 600 "$IMSG/$name"; done
as_incwd() { expect "$1" executor "$EXEC_PANE" "$CHILD" "$INCWD_CONFIG" enforce "$2" "$3"; }
as_incwd "in-checkout store: relative read of its dispatch is allowed" "$(bash_payload "cat .msgs/$TO_EXEC")" "$M_READ"
as_incwd "in-checkout store: relative read of a peer dispatch is denied" "$(bash_payload "cat .msgs/$TO_REVIEW")" "$M_DENY"
INCWD_NO_MESSAGES_CONFIG="$ROOT/.agent-workspace/in-checkout-no-messages.json"
jq '.roles.executor.grants = ["scheduler", "contexts", "memory"]' "$INCWD_CONFIG" > "$INCWD_NO_MESSAGES_CONFIG"
expect "in-checkout store without messages grant cannot borrow checkout access" executor "$EXEC_PANE" "$CHILD" "$INCWD_NO_MESSAGES_CONFIG" enforce \
  "$(bash_payload "cat .msgs/$TO_EXEC")" "$M_DENY"
as_incwd "in-checkout store: rm of a peer dispatch is denied" "$(bash_payload "rm .msgs/$TO_REVIEW")" "$M_DENY"
as_incwd "in-checkout store: tool workdir inside the store is denied" "$(jq -cn --arg d "$IMSG" --arg c "rm $TO_REVIEW" '{tool_name:"Bash",tool_input:{command:$c,workdir:$d}}')" "$M_WALK"
as_incwd "in-checkout store: workdir-relative ../ alias is denied" "$(jq -cn --arg d "$CHILD/src" --arg c "cat ../.msgs/$TO_EXEC" '{tool_name:"Bash",tool_input:{command:$c,workdir:$d}}')" "$M_DENY"
as_incwd "in-checkout store: rg over cwd is denied" "$(bash_payload 'rg --no-config body .')" "$M_WALK"
as_incwd "in-checkout store: rg with implicit cwd is denied" "$(bash_payload 'rg --no-config body')" "$M_WALK"
as_incwd "in-checkout store: rg whose pattern names a file is denied" "$(bash_payload 'rg --no-config README.md')" "$M_WALK"
as_incwd "in-checkout store: rg of a subdirectory is allowed" "$(bash_payload 'rg --no-config body src')" '.decision == "allow"'
as_incwd "in-checkout store: grep -r over cwd is denied" "$(bash_payload 'grep -r body .')" "$M_WALK"
as_incwd "in-checkout store: grep -d recurse over cwd is denied" "$(bash_payload 'grep -d recurse body .')" "$M_WALK"
as_incwd "in-checkout store: grep of one file is allowed" "$(bash_payload 'grep hello README.md')" '.decision == "allow"'
as_incwd "in-checkout store: find with implicit start is denied" "$(bash_payload "find -name '*.md'")" "$M_WALK"
as_incwd "in-checkout store: find of a subdirectory is allowed" "$(bash_payload "find src -name '*.md'")" '.decision == "allow"'
as_incwd "in-checkout store: ls -R is denied" "$(bash_payload 'ls -R')" "$M_WALK"
as_incwd "in-checkout store: ls of cwd is allowed" "$(bash_payload 'ls .')" '.decision == "allow"'
as_incwd "in-checkout store: du of cwd is denied" "$(bash_payload 'du -sh')" "$M_WALK"
as_incwd "in-checkout store: du depth option retains implicit cwd" "$(bash_payload 'du -d 1')" "$M_WALK"
as_incwd "in-checkout store: bundled du depth retains implicit cwd" "$(bash_payload 'du -hd 1')" "$M_WALK"
as_incwd "in-checkout store: rg pattern file retains implicit cwd" "$(bash_payload 'rg --no-config -f README.md')" "$M_WALK"
as_incwd "in-checkout store: ls ignore option retains implicit cwd" "$(bash_payload 'ls -R -I README.md')" "$M_WALK"
as_incwd "in-checkout store: bundled ls ignore retains implicit cwd" "$(bash_payload 'ls -RI README.md')" "$M_WALK"
as_incwd "in-checkout store: du of a subdirectory is allowed" "$(bash_payload 'du -sh src')" '.decision == "allow"'
rm -rf "$IMSG"
echo "== message-read denial matrix for both receiving roles =="
mkdir -p "$MSG/queue" "$MSG/nested"
printf 'sent ledger\n' > "$MSG/sent-log.tsv"
printf 'reply ledger\n' > "$MSG/replies-log.tsv"
for message_role in executor reviewer; do
  message_pane="$EXEC_PANE"
  message_peer="$REVIEW_PANE"
  [ "$message_role" != reviewer ] || { message_pane="$REVIEW_PANE"; message_peer="$EXEC_PANE"; }
  received="1700000000-201-abcdef21-$MASTER_PANE-to-$message_pane.md"
  sent="1700000000-202-abcdef22-$message_pane-to-$MASTER_PANE.md"
  peer="1700000000-203-abcdef23-$MASTER_PANE-to-$message_peer.md"
  mkmsg "$received"; mkmsg "$sent"; mkmsg "$peer"
  for nested in queue archive nested; do
    printf 'nested task\n' > "$MSG/$nested/$received"
    chmod 600 "$MSG/$nested/$received"
  done
  linked="1700000000-204-abcdef24-$MASTER_PANE-to-$message_pane.md"
  ln -s "$MSG/$received" "$MSG/$linked"
  expect "$message_role matrix addressed control" "$message_role" "$message_pane" "$CHILD" "$CONFIG" enforce "$(bash_payload "cat $MSG/$received")" "$M_READ"
  expect "$message_role matrix sent control" "$message_role" "$message_pane" "$CHILD" "$CONFIG" enforce "$(bash_payload "cat $MSG/$sent")" "$M_READ"
  for forbidden in "$MSG/$peer" "$MSG/queue/$received" "$MSG/archive/$received" "$MSG/nested/$received" \
      "$MSG/sent-log.tsv" "$MSG/replies-log.tsv" "$MSG/$linked" "$MSG/../messages/$received"; do
    expect "$message_role matrix denies $forbidden" "$message_role" "$message_pane" "$CHILD" "$CONFIG" enforce "$(bash_payload "cat $forbidden")" "$M_DENY"
  done
  for command in "cat $MSG/*.md" "cat $MSG/$received | head" "cat $MSG/$received > saved.md" \
      "cat \$SESSION_CHAT_TARGET_MESSAGES_DIR/$received" "cat '$MSG/*.md'"; do
    expect "$message_role matrix denies dynamic/composed command $command" "$message_role" "$message_pane" "$CHILD" "$CONFIG" enforce "$(bash_payload "$command")" '.decision == "deny"'
  done
  expect "$message_role matrix rejects spoofed chat identity" "$message_role" "$message_pane" "$CHILD" "$CONFIG" enforce "$(bash_payload "cat $MSG/$peer")" \
    '.decision == "deny" and .rule == "identity.alias"' SESSION_CHAT_PANE_NAME="$message_peer"
  expect "$message_role matrix inherited store cannot grant peer reads" "$message_role" "$message_pane" "$CHILD" "$CONFIG" enforce "$(bash_payload "cat $MSG/$peer")" \
    "$M_DENY" SESSION_CHAT_TARGET_MESSAGES_DIR="$MSG"
  expect "$message_role matrix unchanged draft edit control" "$message_role" "$message_pane" "$CHILD" "$CONFIG" enforce \
    "$(edit_payload "$MSG/drafts/$message_pane/own.md")" '.decision == "allow"'
done
# Overlapping -to- delimiters must also be enumerated. Both endpoint pairs
# below are in the plan; accepting only the first split could leak a peer task.
OVERLAP_CONFIG="$ROOT/.agent-workspace/overlap.json"
jq '.sessions[0].panes[1].name = "a" | .sessions[0].panes += [{name:"a-to",role:"executor",cwd:"component-b"},{name:"to-b",role:"reviewer",cwd:"component-b"},{name:"b",role:"executor",cwd:"component-c"},{name:"b-review",role:"reviewer",cwd:"component-c"}]' "$CONFIG" > "$OVERLAP_CONFIG"
mkdir -p "$ROOT/component-c"
mkmsg '1700000000-205-abcdef25-a-to-to-b.md'
mkmsg "1700000000-206-abcdef26-$MASTER_PANE-to-a.md"
expect "overlapping delimiter control" executor a "$CHILD" "$OVERLAP_CONFIG" enforce "$(bash_payload "cat $MSG/1700000000-206-abcdef26-$MASTER_PANE-to-a.md")" "$M_READ"
expect "overlapping delimiter ambiguity denied" executor a "$CHILD" "$OVERLAP_CONFIG" enforce "$(bash_payload "cat $MSG/1700000000-205-abcdef25-a-to-to-b.md")" "$M_DENY"
for message_config in "$AMBIG_CONFIG" "$OVERLAP_CONFIG" "$INCWD_CONFIG" "$INCWD_NO_MESSAGES_CONFIG"; do
  if bash "$HERE/validate-config.sh" --config "$message_config" >/dev/null 2>&1; then
    pass "message fixture validates: $(basename "$message_config")"
  else
    fail "message fixture validates: $(basename "$message_config")" "invalid fixture cannot test message policy"
  fi
done
rm -f "$CHILD/msg-alias"

echo "== 0.12.7 read-command writes, reviewer reflog, executor inline code =="
# Each gap_case is a payload the released policy allowed. With
# HARNESS_TEST_BASELINE_POLICY set to that release's harness-policy.py
# inside a copy of that release's scripts directory (git archive <rev>
# plugins/session-workspace/scripts | tar -x -C DIR; the policy loads siblings),
# every gap_case also asserts the baseline allowed it: the control that the
# gap was real. The allow cases are the controls that the fix stays narrow.
BASELINE_POLICY="${HARNESS_TEST_BASELINE_POLICY:-}"
# gap_case LABEL ROLE PAYLOAD JQ_EXPR
gap_case() {
  local label="$1" role="$2" payload="$3" expression="$4" pane cwd out
  case "$role" in
    reviewer) pane="$REVIEW_PANE" cwd="$CHILD" ;;
    executor) pane="$EXEC_PANE" cwd="$CHILD" ;;
    *) pane="$MASTER_PANE" cwd="$ROOT" ;;
  esac
  expect "$label" "$role" "$pane" "$cwd" "$CONFIG" enforce "$payload" "$expression"
  [ -n "$BASELINE_POLICY" ] || return 0
  out="$(POLICY="$BASELINE_POLICY" run_policy "$role" "$pane" "$cwd" "$CONFIG" enforce "$payload" 2>&1)"
  if printf '%s' "$out" | jq -e '.decision == "allow"' >/dev/null 2>&1; then
    pass "baseline control: released policy allowed it: $label"
  else
    fail "baseline control: released policy allowed it: $label" "$out"
  fi
}
[ -n "$BASELINE_POLICY" ] || echo "  (baseline controls skipped: set HARNESS_TEST_BASELINE_POLICY to the released harness-policy.py)"
printf 'kept\n' > "$CHILD/src/uniq-existing.txt"
UNIQ='.decision == "deny" and .rule == "reviewer.uniq"'
as_review "uniq: one input operand is allowed" "$(bash_payload 'uniq README.md')" '.decision == "allow"'
as_review "uniq: options with values and one operand are allowed" "$(bash_payload 'uniq -c -f 1 -s 2 README.md')" '.decision == "allow"'
as_review "uniq: -- after the options with one operand is allowed" "$(bash_payload 'uniq -c -- README.md')" '.decision == "allow"'
as_review "uniq: clusters and attached values are outside the exact forms" "$(bash_payload 'uniq -cf1 -- README.md')" '.decision == "deny" and .rule == "reviewer.form"'
as_review "uniq: unlisted long options are outside the exact forms" "$(bash_payload 'uniq --skip-fields 1 README.md')" '.decision == "deny" and .rule == "reviewer.form"'
as_review "uniq: stdin with no operand is allowed" "$(bash_payload 'uniq -d')" '.decision == "allow"'
gap_case "uniq: reported form, nonexistent bare input and slash output, is denied" reviewer "$(bash_payload 'uniq package.json src/b.txt')" "$UNIQ"
gap_case "uniq: nonexistent slash output is denied" reviewer "$(bash_payload 'uniq README.md src/b.txt')" "$UNIQ"
gap_case "uniq: nonexistent bare output is denied" reviewer "$(bash_payload 'uniq README.md notes.txt')" "$UNIQ"
gap_case "uniq: existing slash output is denied" reviewer "$(bash_payload 'uniq README.md src/uniq-existing.txt')" "$UNIQ"
gap_case "uniq: existing bare output is denied" reviewer "$(bash_payload 'uniq src/uniq-existing.txt README.md')" "$UNIQ"
gap_case "uniq: output after options is denied" reviewer "$(bash_payload 'uniq -c -f 1 README.md notes.txt')" "$UNIQ"
gap_case "uniq: stdin input with an output operand is denied" reviewer "$(bash_payload 'uniq - notes.txt')" "$UNIQ"
gap_case "uniq: BSD form, an option after the input (output file -c), is denied" reviewer "$(bash_payload 'uniq README.md -c')" "$UNIQ"
gap_case "uniq: an output operand after -- is denied" reviewer "$(bash_payload 'uniq -- README.md notes.txt')" "$UNIQ"
gap_case "uniq: executor read grant path does not admit an output operand" executor "$(bash_payload "uniq $CLAUDE_CACHE/session-chat/1.2.3/scripts/send-message.sh $CLAUDE_CACHE/session-chat/1.2.3/scripts/out.txt")" '.decision == "deny" and .rule == "executor.containment"'
as_exec "uniq: executor output inside its checkout stays allowed (control)" "$(bash_payload 'uniq README.md notes.txt')" '.decision == "allow"'

# Step 2 audit gaps (see the READ_COMMANDS comment): one case each.
as_review "file: a plain read is allowed" "$(bash_payload 'file -b README.md')" '.decision == "allow"'
gap_case "file: -C -m compiles and writes a magic file, denied" reviewer "$(bash_payload 'file -C -m README.md')" '.decision == "deny" and .rule == "reviewer.file"'
gap_case "file: clustered -bC is denied" reviewer "$(bash_payload 'file -bC -m README.md')" '.decision == "deny" and .rule == "reviewer.file"'
gap_case "file: --compile abbreviation is denied" reviewer "$(bash_payload 'file --comp -m README.md')" '.decision == "deny" and .rule == "reviewer.file"'
gap_case "file: -f loads operands from a name list, denied" reviewer "$(bash_payload 'file -f README.md')" '.decision == "deny" and .rule == "reviewer.file_list"'
as_review "date: +FORMAT and -u print only and are allowed" "$(bash_payload "date -u '+%F %T'")" '.decision == "allow"'
as_review "date: -d and -I are outside the exact forms" "$(bash_payload "date -u -d '2 days ago' +%F")" '.decision == "deny" and .rule == "reviewer.form"'
as_review "date: -Iseconds is outside the exact forms" "$(bash_payload 'date -Iseconds')" '.decision == "deny" and .rule == "reviewer.form"'
gap_case "date: -s sets the clock, denied" reviewer "$(bash_payload 'date -s 00:00')" '.decision == "deny" and .rule == "reviewer.date"'
gap_case "date: --set= sets the clock, denied" reviewer "$(bash_payload 'date --set=00:00')" '.decision == "deny" and .rule == "reviewer.date"'
gap_case "date: a non-+ operand sets the clock (GNU and BSD), denied" reviewer "$(bash_payload 'date -u 0101000026')" '.decision == "deny" and .rule == "reviewer.date"'
as_review "shasum/cksum: hashing a named file is allowed" "$(bash_payload 'shasum -a 256 README.md')" '.decision == "allow"'
gap_case "shasum: -c hashes the files a list names, denied" reviewer "$(bash_payload 'shasum -c README.md')" '.decision == "deny" and .rule == "reviewer.file_list"'
gap_case "cksum: --check hashes the files a list names, denied" reviewer "$(bash_payload 'cksum --check README.md')" '.decision == "deny" and .rule == "reviewer.file_list"'
CW='.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator uniq with a root-local output is allowed (control)" "$(bash_payload 'uniq AGENTS.md notes.txt')" '.decision == "allow"'
as_master "orchestrator uniq reading a child is allowed (control)" "$(bash_payload 'uniq component-a/README.md')" '.decision == "allow"'
gap_case "orchestrator uniq writing into a child is a child write" master "$(bash_payload 'uniq AGENTS.md component-a/out.txt')" "$CW"
gap_case "orchestrator uniq run inside a child is a child write" master "$(bash_payload 'cd component-a && uniq README.md out.txt')" "$CW"
as_master "orchestrator find reading a child is allowed (control)" "$(bash_payload 'find component-a -name README.md')" '.decision == "allow"'
gap_case "orchestrator find -delete in a child is a child write" master "$(bash_payload 'find component-a -name x -delete')" "$CW"
gap_case "orchestrator rg --pre over a child is a child write" master "$(bash_payload 'rg --pre ./x hello component-a')" "$CW"
gap_case "orchestrator file -C inside a child is a child write" master "$(bash_payload 'cd component-a && file -C -m README.md')" "$CW"

GITD='.decision == "deny" and .rule == "reviewer.git"'
as_review "reflog: bare git reflog is allowed" "$(bash_payload 'git reflog')" '.decision == "allow"'
as_review "reflog: show with -n and a quoted ref is allowed" "$(bash_payload "git reflog show -n 5 'HEAD@{1}'")" '.decision == "allow"'
as_review "reflog: --oneline -n on the implicit show is allowed" "$(bash_payload 'git reflog --oneline -n 5')" '.decision == "allow"'
as_review "reflog: show --date=FORMAT (a listed attached value) is allowed" "$(bash_payload "git reflog show --date=iso -n 5 'HEAD@{1}'")" '.decision == "allow"'
as_review "reflog: an unlisted attached value is outside the exact forms" "$(bash_payload "git reflog show --format=%H 'HEAD@{1}'")" "$GITD"
as_review "reflog: list and exists are not listed forms" "$(bash_payload 'git reflog list')" "$GITD"
as_review "reflog: exists is not a listed form" "$(bash_payload 'git reflog exists HEAD')" "$GITD"
as_review "reflog: --date=FORMAT on the implicit show is allowed" "$(bash_payload 'git reflog --date=relative')" '.decision == "allow"'
as_review "reflog: a --date value starting with - is denied" "$(bash_payload 'git reflog --date=-x')" "$GITD"
gap_case "reflog: expire --all --expire=now is denied" reviewer "$(bash_payload 'git reflog expire --all --expire=now')" "$GITD"
gap_case "reflog: expire with an unquoted ref is denied" reviewer "$(bash_payload 'git reflog expire --expire=now main')" "$GITD"
gap_case "reflog: delete with a single-quoted ref is denied" reviewer "$(bash_payload "git reflog delete 'HEAD@{0}'")" "$GITD"
gap_case "reflog: delete with a double-quoted ref is denied" reviewer "$(bash_payload 'git reflog delete "main@{1}"')" '.decision == "deny" and .rule == "reviewer.shell"'
gap_case "reflog: delete with an unquoted plain ref is denied" reviewer "$(bash_payload 'git reflog delete HEAD')" "$GITD"
as_review "reflog: delete with an unquoted brace ref is denied" "$(bash_payload 'git reflog delete HEAD@{0}')" '.decision == "deny" and .rule == "reviewer.shell"'
gap_case "reflog: drop (Git 2.50) is denied" reviewer "$(bash_payload 'git reflog drop main')" "$GITD"
gap_case "reflog: an unknown word after reflog is denied" reviewer "$(bash_payload 'git reflog main')" "$GITD"
gap_case "reflog: a write word later in an implicit show is denied" reviewer "$(bash_payload 'git reflog -n 1 expire')" "$GITD"
gap_case "reflog: behind global options is still denied" reviewer "$(bash_payload 'git --no-pager -C . reflog expire --all')" "$GITD"
gap_case "orchestrator reflog expire in a child is a child write" master "$(bash_payload 'git -C component-a reflog expire --all')" "$CW"
as_master "orchestrator reflog read in a child is allowed (control)" "$(bash_payload 'git -C component-a reflog')" '.decision == "allow"'

INL='.decision == "deny" and .rule == "executor.inline_code"'
as_exec "inline: python3 running a script file is allowed" "$(bash_payload 'python3 tool.py --verbose')" '.decision == "allow"'
as_exec "inline: script arguments that look like options are not interpreter options" "$(bash_payload 'node server.js -p 3000 -env')" '.decision == "allow"'
as_exec "inline: python3 -W value with a c is not -c" "$(bash_payload 'python3 -Wignore::DeprecationWarning:collections tool.py')" '.decision == "allow"'
as_exec "inline: python3 -m module run is allowed" "$(bash_payload 'python3 -m pytest -q')" '.decision == "allow"'
as_exec "inline: perl -M module import is allowed" "$(bash_payload 'perl -MData::Dumper -w tool.pl')" '.decision == "allow"'
as_exec "inline: ruby -Ke (EUC) is not -e" "$(bash_payload 'ruby -Ke tool.rb')" '.decision == "allow"'
as_exec "inline: php script with -d ini is allowed" "$(bash_payload 'php -d display_errors=1 tool.php')" '.decision == "allow"'
as_exec "inline: node --import of a file module is allowed" "$(bash_payload 'node --import ./setup.mjs tool.js')" '.decision == "allow"'
gap_case "inline: python3 -c attached code is denied" executor "$(bash_payload 'python3 -c"print(1)"')" "$INL"
gap_case "inline: python3 -c attached import/system is denied" executor "$(bash_payload "python3 -c\"import os; os.system('true')\"")" "$INL"
gap_case "inline: python3 clustered -Bc is denied" executor "$(bash_payload "python3 -Bc 'print(1)'")" "$INL"
gap_case "inline: python3 -X value then attached -c is denied" executor "$(bash_payload "python3 -X dev -c'print(1)'")" "$INL"
gap_case "inline: versioned python3.12 -c is denied" executor "$(bash_payload "python3.12 -c 'print(1)'")" "$INL"
gap_case "inline: node --eval= is denied" executor "$(bash_payload 'node --eval=1')" "$INL"
gap_case "inline: node -p is denied" executor "$(bash_payload "node -p '1'")" "$INL"
gap_case "inline: node --print is denied" executor "$(bash_payload "node --print '1'")" "$INL"
gap_case "inline: node --print= is denied" executor "$(bash_payload 'node --print=1')" "$INL"
gap_case "inline: node -pe is denied" executor "$(bash_payload "node -pe '1'")" "$INL"
gap_case "inline: node --import of a data: URL is denied" executor "$(bash_payload "node --import 'data:text/javascript,process.exit()' tool.js")" "$INL"
gap_case "inline: perl attached -e is denied" executor "$(bash_payload "perl -e'print 1'")" "$INL"
gap_case "inline: perl -E is denied" executor "$(bash_payload "perl -E 'say 1'")" "$INL"
gap_case "inline: perl clustered -lne is denied" executor "$(bash_payload "perl -lne 'print'")" "$INL"
gap_case "inline: perl -M with code is denied" executor "$(bash_payload "perl '-Mstrict; print 1' tool.pl")" "$INL"
gap_case "inline: ruby attached -e is denied" executor "$(bash_payload "ruby -e'p 1'")" "$INL"
gap_case "inline: ruby clustered -ne is denied" executor "$(bash_payload "ruby -ne 'p 1'")" "$INL"
gap_case "inline: php attached -r is denied" executor "$(bash_payload "php -r'echo 1;'")" "$INL"
gap_case "inline: php clustered -nr is denied" executor "$(bash_payload "php -nr 'echo 1;'")" "$INL"
gap_case "inline: php -B begin code is denied" executor "$(bash_payload "php -B 'echo 1;'")" "$INL"
gap_case "inline: php --run= is denied" executor "$(bash_payload "php --run='echo 1;'")" "$INL"
as_exec "inline: bash running a script file is allowed (shell branch unchanged)" "$(bash_payload 'bash tool.sh')" '.decision == "allow"'
rm -f "$CHILD/src/uniq-existing.txt"

echo "== 0.12.8 executor inline code on stdin, behind launch prefixes, on a later line =="
# Same gap_case controls as 0.12.7, against their own baseline: set
# HARNESS_TEST_BASELINE_POLICY_0127 to the 0.12.7 harness-policy.py (inside a
# copy of its scripts directory) to assert that 0.12.7 allowed each case.
BASELINE_POLICY_0125="$BASELINE_POLICY"
BASELINE_POLICY="${HARNESS_TEST_BASELINE_POLICY_0127:-}"
[ -n "$BASELINE_POLICY" ] || echo "  (baseline controls skipped: set HARNESS_TEST_BASELINE_POLICY_0127 to the 0.12.7 harness-policy.py)"
NL=$'\n'
TAB=$'\t'
# Program on stdin: a pipe, heredoc, here-string, < redirect, - or -s.
gap_case "stdin: python3 reading a pipe is denied" executor "$(bash_payload "echo 'import os' | python3")" "$INL"
gap_case "stdin: python3 - reading a heredoc is denied" executor "$(bash_payload "python3 - <<'EOF'${NL}import os${NL}EOF")" "$INL"
gap_case "stdin: python3 reading a heredoc with no operand is denied" executor "$(bash_payload "python3 <<'EOF'${NL}import os${NL}EOF")" "$INL"
gap_case "stdin: python3 reading a <<- heredoc is denied" executor "$(bash_payload "python3 <<-EOF${NL}${TAB}import os${NL}${TAB}EOF")" "$INL"
gap_case "stdin: node reading a here-string is denied" executor "$(bash_payload "node <<<'process.exit()'")" "$INL"
gap_case "stdin: python3 reading a < redirect is denied" executor "$(bash_payload 'python3 < tool.py')" "$INL"
gap_case "stdin: python3 - is denied" executor "$(bash_payload 'cat tool.py | python3 -')" "$INL"
gap_case "stdin: python3 -- with no script is denied" executor "$(bash_payload 'cat tool.py | python3 -u --')" "$INL"
gap_case "stdin: perl reading a pipe is denied" executor "$(bash_payload 'cat tool.pl | perl -w')" "$INL"
gap_case "stdin: ruby - is denied" executor "$(bash_payload 'cat tool.rb | ruby -')" "$INL"
gap_case "stdin: php reading a < redirect is denied" executor "$(bash_payload 'php < tool.php')" "$INL"
gap_case "stdin: versioned python3.12 reading a pipe is denied" executor "$(bash_payload 'cat tool.py | python3.12')" "$INL"
gap_case "stdin: bash reading a pipe is denied" executor "$(bash_payload 'echo ls | bash')" "$INL"
gap_case "stdin: bash reading a heredoc is denied" executor "$(bash_payload "bash <<'EOF'${NL}ls${NL}EOF")" "$INL"
gap_case "stdin: sh -s is denied" executor "$(bash_payload 'cat tool.sh | sh -s')" "$INL"
gap_case "stdin: bash -eu with no script is denied" executor "$(bash_payload 'cat tool.sh | bash -eu')" "$INL"
gap_case "stdin: zsh - is denied" executor "$(bash_payload 'cat tool.sh | zsh -')" "$INL"
gap_case "stdin: ruby -v with another option reads stdin and is denied" executor "$(bash_payload 'cat tool.rb | ruby -v -w')" "$INL"
gap_case "stdin: bash -ox takes pipefail as the -o value, so no script is denied" executor "$(bash_payload 'cat tool.sh | bash -ox pipefail')" "$INL"
gap_case "inline: fish --command= is denied" executor "$(bash_payload 'fish --command=ls')" "$INL"
gap_case "inline: fish -C init command is denied" executor "$(bash_payload "fish -C 'ls' tool.fish")" "$INL"
as_exec "stdin control: python3 script with a < redirect input is allowed" "$(bash_payload 'python3 tool.py < input.txt')" '.decision == "allow"'
as_exec "stdin control: a pipe into a python3 script is allowed" "$(bash_payload 'cat input.txt | python3 tool.py')" '.decision == "allow"'
as_exec "stdin control: a heredoc into a python3 script is allowed" "$(bash_payload "python3 tool.py <<'EOF'${NL}input${NL}EOF")" '.decision == "allow"'
as_exec "stdin control: python3 --version is allowed" "$(bash_payload 'python3 --version')" '.decision == "allow"'
as_exec "stdin control: python3 -V is allowed" "$(bash_payload 'python3 -V')" '.decision == "allow"'
as_exec "stdin control: node -v is allowed" "$(bash_payload 'node -v')" '.decision == "allow"'
as_exec "stdin control: node --test is allowed" "$(bash_payload 'node --test')" '.decision == "allow"'
as_exec "stdin control: ruby -v alone is allowed" "$(bash_payload 'ruby -v')" '.decision == "allow"'
as_exec "stdin control: node --test with options is allowed" "$(bash_payload 'node --test --test-reporter spec')" '.decision == "allow"'
as_exec "stdin control: php -S built-in server is allowed" "$(bash_payload 'php -S localhost:8000 -t public')" '.decision == "allow"'
as_exec "stdin control: bash -ox pipefail script is allowed" "$(bash_payload 'bash -ox pipefail tool.sh')" '.decision == "allow"'
as_exec "stdin control: perl -v is allowed" "$(bash_payload 'perl -v')" '.decision == "allow"'
as_exec "stdin control: ruby --version is allowed" "$(bash_payload 'ruby --version')" '.decision == "allow"'
as_exec "stdin control: php -m is allowed" "$(bash_payload 'php -m')" '.decision == "allow"'
as_exec "stdin control: php -f script is allowed" "$(bash_payload 'php -f tool.php')" '.decision == "allow"'
as_exec "stdin control: bash --version is allowed" "$(bash_payload 'bash --version')" '.decision == "allow"'
as_exec "stdin control: bash -euo pipefail script is allowed" "$(bash_payload 'bash -euo pipefail tool.sh')" '.decision == "allow"'
as_exec "stdin control: bash -- script is allowed" "$(bash_payload 'bash -- tool.sh')" '.decision == "allow"'
as_exec "stdin control: a heredoc into cat is data" "$(bash_payload "cat > notes.md <<'EOF'${NL}python3 -c 'print(1)'${NL}EOF")" '.decision == "allow"'
# Launch prefixes: unwrapped, then the same checks.
gap_case "wrapper: timeout python3 -c is denied" executor "$(bash_payload "timeout 5 python3 -c 'print(1)'")" "$INL"
gap_case "wrapper: timeout -s KILL -k 1 bash -c is denied" executor "$(bash_payload 'timeout -s KILL -k 1 5 bash -c true')" "$INL"
gap_case "wrapper: timeout --signal= python3 attached -c is denied" executor "$(bash_payload 'timeout --signal=TERM 5 python3 -c"print(1)"')" "$INL"
gap_case "wrapper: nice python3 -c is denied" executor "$(bash_payload 'nice python3 -c 1')" "$INL"
gap_case "wrapper: nice -n 5 node -e is denied" executor "$(bash_payload 'nice -n 5 node -e 1')" "$INL"
gap_case "wrapper: obsolete nice -10 perl -e is denied" executor "$(bash_payload 'nice -10 perl -e 1')" "$INL"
gap_case "wrapper: stdbuf -oL ruby -e is denied" executor "$(bash_payload 'stdbuf -oL ruby -e 1')" "$INL"
gap_case "wrapper: ionice -c3 php -r is denied" executor "$(bash_payload "ionice -c3 php -r 'echo 1;'")" "$INL"
gap_case "wrapper: setsid -f python3 -c is denied" executor "$(bash_payload 'setsid -f python3 -c 1')" "$INL"
gap_case "wrapper: taskset -c 0 python3 -c is denied" executor "$(bash_payload 'taskset -c 0 python3 -c 1')" "$INL"
gap_case "wrapper: chrt -f 10 bash -c is denied" executor "$(bash_payload 'chrt -f 10 bash -c ls')" "$INL"
gap_case "wrapper: nested timeout nice env python3 -c is denied" executor "$(bash_payload 'timeout 5 nice env python3 -c 1')" "$INL"
gap_case "wrapper: time timeout python3 -c is denied" executor "$(bash_payload 'time timeout 5 python3 -c 1')" "$INL"
gap_case "wrapper: an unknown timeout option still finds python3 -c" executor "$(bash_payload 'timeout --unknown 5 python3 -c 1')" "$INL"
gap_case "wrapper: timeout python3 reading a pipe is denied" executor "$(bash_payload 'cat tool.py | timeout 5 python3')" "$INL"
gap_case "wrapper: then python3 -c is denied" executor "$(bash_payload 'if true; then python3 -c 1; fi')" "$INL"
gap_case "wrapper: do bash -c is denied" executor "$(bash_payload 'while false; do bash -c ls; done')" "$INL"
gap_case "wrapper: ! python3 -c is denied" executor "$(bash_payload '! python3 -c 1')" "$INL"
gap_case "wrapper: find -exec python3 -c is denied" executor "$(bash_payload 'find . -name x -exec python3 -c 1 \;')" "$INL"
gap_case "wrapper: find -execdir bash -c is denied" executor "$(bash_payload 'find . -execdir bash -c ls \;')" "$INL"
as_exec "wrapper control: env python3 -c was already denied" "$(bash_payload 'env python3 -c 1')" "$INL"
as_exec "wrapper control: command python3 -c was already denied" "$(bash_payload 'command python3 -c 1')" "$INL"
as_exec "wrapper control: exec python3 -c was already denied" "$(bash_payload 'exec python3 -c 1')" "$INL"
as_exec "wrapper control: nohup python3 -c was already denied" "$(bash_payload 'nohup python3 -c 1')" "$INL"
as_exec "wrapper control: timeout python3 script is allowed" "$(bash_payload 'timeout 5 python3 tool.py')" '.decision == "allow"'
as_exec "wrapper control: timeout -k 1 make is allowed" "$(bash_payload 'timeout -k 1 60 make test')" '.decision == "allow"'
as_exec "wrapper control: nice -n 5 python3 script is allowed" "$(bash_payload 'nice -n 5 python3 tool.py')" '.decision == "allow"'
as_exec "wrapper control: stdbuf -oL node script is allowed" "$(bash_payload 'stdbuf -oL node server.js -p 3000')" '.decision == "allow"'
as_exec "wrapper control: timeout python3 -m module is allowed" "$(bash_payload 'timeout 60 python3 -m pytest -q')" '.decision == "allow"'
as_exec "wrapper control: then python3 script is allowed" "$(bash_payload 'if true; then python3 tool.py; fi')" '.decision == "allow"'
as_exec "wrapper control: find -exec grep is allowed" "$(bash_payload 'find . -name x -exec grep -l y \;')" '.decision == "allow"'
as_exec "wrapper control: timeout sudo is still shell.privilege" "$(bash_payload 'timeout 5 sudo python3 tool.py')" '.decision == "deny" and .rule == "shell.privilege"'
# A newline ends a command; parse_shell alone folded it into the first one.
gap_case "newline: python3 -c on the second line is denied" executor "$(bash_payload "ls${NL}python3 -c 1")" "$INL"
gap_case "newline: python3 -c after a heredoc is denied" executor "$(bash_payload "cat <<'EOF'${NL}text${NL}EOF${NL}python3 -c 1")" "$INL"
gap_case "newline: a heredoc opener inside a comment hides nothing" executor "$(bash_payload "ls # <<X${NL}python3 -c 1${NL}X")" "$INL"
gap_case "newline: a privilege wrapper on the second line is shell.privilege" executor "$(bash_payload "ls${NL}sudo ls")" '.decision == "deny" and .rule == "shell.privilege"'
as_exec "newline control: two plain commands on two lines are allowed" "$(bash_payload "ls${NL}ls -la")" '.decision == "allow"'
as_exec "newline control: a backslash-newline continuation is allowed" "$(bash_payload "ls \\${NL} -la")" '.decision == "allow"'
as_exec "newline control: a newline inside quotes is one argument" "$(bash_payload "echo 'a${NL}python3 -c 1'")" '.decision == "allow"'
as_exec "newline control: a <<- heredoc body into a file is data" "$(bash_payload "cat > notes.md <<-'EOF'${NL}${TAB}python3 -c 1${NL}${TAB}EOF${NL}ls")" '.decision == "allow"'
as_exec "newline control: an escape on the second line still escapes containment" "$(bash_payload "ls${NL}cat ../component-b/x")" '.decision == "deny" and .rule == "executor.containment"'
BASELINE_POLICY="$BASELINE_POLICY_0125"

echo "== 0.12.11 reviewer exact read forms =="
# Every bypass class the exact-form grammar closes, each next to a working
# control. Symlink cases use temporary fixtures under the reviewer checkout.
# Set HARNESS_TEST_BASELINE_POLICY_01210 to the 0.12.10 harness-policy.py
# (inside a copy of its scripts directory) to assert that 0.12.10 allowed
# each gap_case.
BASELINE_POLICY_0127="$BASELINE_POLICY"
BASELINE_POLICY="${HARNESS_TEST_BASELINE_POLICY_01210:-}"
[ -n "$BASELINE_POLICY" ] || echo "  (baseline controls skipped: set HARNESS_TEST_BASELINE_POLICY_01210 to the 0.12.10 harness-policy.py)"
XF="$CHILD/xf"
XF_OUT="$TMPROOT/xf-outside"
mkdir -p "$XF/dirA" "$XF/dirB" "$XF/sub" "$XF_OUT"
printf 'secret\n' > "$XF_OUT/secret.txt"
printf 'a\n' > "$XF/dirA/f"
printf 'b\n' > "$XF/dirB/f"
printf '[core]\n\tbare = false\n' > "$XF/config"
ln -s "$XF_OUT/secret.txt" "$XF/dirA/leak"
ln -s "$XF_OUT/secret.txt" "$XF/dirB/leak"
ln -s "$XF_OUT" "$XF/src"
# A symlink named - and one named -- in the reviewer's cwd itself.
ln -s "$XF_OUT" "$CHILD/-"
ln -s "$XF_OUT/secret.txt" "$CHILD/--"
XA='.decision == "allow"'
xd() { printf '.decision == "deny" and .rule == "%s"' "$1"; }
# Word form: zsh EXTENDED_GLOB ^ and ~, quoting, metacharacters, operators.
gap_case "word form: cat ^x (zsh EXTENDED_GLOB negation) is denied" reviewer "$(bash_payload 'cat ^README.md')" "$(xd reviewer.shell)"
gap_case "word form: cat a~b (zsh EXTENDED_GLOB exclusion) is denied" reviewer "$(bash_payload 'cat README~b')" "$(xd reviewer.shell)"
as_review "word form control: ^ inside single quotes is a literal name" "$(bash_payload "cat '^README.md'")" "$XA"
as_review "word form control: ~ inside single quotes is a literal name" "$(bash_payload "cat 'README~b'")" "$XA"
as_review "word form: double quotes are denied" "$(bash_payload 'cat "README.md"')" "$(xd reviewer.shell)"
as_review "word form: a backslash escape is denied" "$(bash_payload 'cat README\.md')" "$(xd reviewer.shell)"
as_review "word form: text attached after a quoted run is denied" "$(bash_payload "cat 'READ'ME.md")" "$(xd reviewer.shell)"
as_review "word form: text attached before a quoted run is denied" "$(bash_payload "cat READ'ME.md'")" "$(xd reviewer.shell)"
as_review "word form: two quoted runs in one word are denied" "$(bash_payload "cat 'READ''ME.md'")" "$(xd reviewer.shell)"
printf 'q\n' > "$XF/it's.md"
as_review "word form control: runs joined by the POSIX \\' idiom are one literal word (a path with an apostrophe)" "$(bash_payload "cat 'xf/it'\\''s.md'")" "$XA"
as_review "word form: text after a \\' joined word is denied" "$(bash_payload "cat 'xf/it'\\''s.md'x")" "$(xd reviewer.shell)"
as_review "word form: a \\' escape outside a join is denied" "$(bash_payload "cat 'xf/it'\\'")" "$(xd reviewer.shell)"
as_review "word form: a leading = (zsh EQUALS expansion) is denied" "$(bash_payload 'cat =ls')" "$(xd reviewer.shell)"
as_review "word form: == inside a word is denied" "$(bash_payload 'cat README==md')" "$(xd reviewer.shell)"
as_review "word form: an empty quoted word is denied" "$(bash_payload "cat '' README.md")" "$(xd reviewer.shell)"
as_review "word form: a quoted word made only of operator characters is denied" "$(bash_payload "grep -n ';' README.md")" "$(xd reviewer.shell)"
as_review "word form control: a quoted word holding an operator character among others is allowed" "$(bash_payload "grep -n 'a;b' README.md")" "$XA"
as_review "word form: a # comment is denied" "$(bash_payload 'cat README.md # x')" "$(xd reviewer.shell)"
as_review "word form: a tab is denied" "$(bash_payload "cat${TAB}README.md")" "$(xd reviewer.shell)"
as_review "word form: a newline is denied" "$(bash_payload "cat README.md${NL}ls")" "$(xd reviewer.shell)"
as_review "word form: a background & is denied" "$(bash_payload 'cat README.md &')" "$(xd reviewer.shell)"
as_review "word form: |& is denied" "$(bash_payload 'cat README.md |& head -n 1')" "$(xd reviewer.shell)"
as_review "word form: a trailing ; is denied" "$(bash_payload 'cat README.md ;')" "$(xd reviewer.shell)"
as_review "word form: ;; is denied" "$(bash_payload 'cat README.md ;; ls')" "$(xd reviewer.shell)"
as_review "word form: a subshell is denied" "$(bash_payload '(cat README.md)')" "$(xd reviewer.shell)"
as_review "word form: input redirection is denied" "$(bash_payload 'cat < README.md')" "$(xd reviewer.shell)"
as_review "word form control: | between listed forms is allowed" "$(bash_payload 'git log --oneline -n 3 | head -n 1')" "$XA"
as_review "word form control: ; && || between listed forms are allowed" "$(bash_payload 'git status --short; ls && wc -l README.md || true')" "$XA"
as_review "word form: an unlisted program after | is denied" "$(bash_payload 'cat README.md | sh')" "$(xd reviewer.command)"
as_review "word form: a write after && is denied" "$(bash_payload 'cat README.md && touch x')" "$(xd reviewer.command)"
as_review "word form: an outward read after ; is denied" "$(bash_payload 'cat README.md; cat /etc/hosts')" "$(xd reviewer.path)"
# Program word and assignments.
as_review "program: /tmp/cat (a path to a program) is denied" "$(bash_payload '/tmp/cat README.md')" "$(xd reviewer.command)"
as_review "program: ./cat is denied" "$(bash_payload './cat README.md')" "$(xd reviewer.command)"
as_review "program: a quoted first word 'LANG=./cat' is the program and is denied" "$(bash_payload "'LANG=./cat' cat README.md")" "$(xd reviewer.command)"
as_review "program: python3 -m json.tool (imports a checkout json.py) is denied" "$(bash_payload 'python3 -m json.tool README.md')" "$(xd reviewer.command)"
as_review "assignment: PATH=/tmp is denied" "$(bash_payload 'PATH=/tmp cat README.md')" "$(xd reviewer.shell)"
as_review "assignment: LD_PRELOAD= is denied" "$(bash_payload 'LD_PRELOAD=x.so cat README.md')" "$(xd reviewer.shell)"
as_review "assignment: DYLD_INSERT_LIBRARIES= is denied" "$(bash_payload 'DYLD_INSERT_LIBRARIES=x cat README.md')" "$(xd reviewer.shell)"
as_review "assignment: DYLD_LIBRARY_PATH= is denied" "$(bash_payload 'DYLD_LIBRARY_PATH=x cat README.md')" "$(xd reviewer.shell)"
as_review "assignment: BASH_ENV= is denied" "$(bash_payload 'BASH_ENV=x cat README.md')" "$(xd reviewer.shell)"
as_review "assignment: GIT_PAGER= is denied" "$(bash_payload 'GIT_PAGER=x git log')" "$(xd reviewer.shell)"
as_review "assignment: a value with / (TZ=/etc/x reads a zone file) is denied" "$(bash_payload 'TZ=/etc/x date')" "$(xd reviewer.shell)"
as_review "assignment: a quoted value is denied" "$(bash_payload "LANG='C' cat README.md")" "$(xd reviewer.shell)"
as_review "assignment control: LANG=C is allowed" "$(bash_payload 'LANG=C cat README.md')" "$XA"
as_review "assignment control: LC_ALL=C and TZ=UTC are allowed" "$(bash_payload 'LC_ALL=C TZ=UTC sort README.md')" "$XA"
as_review "assignment control: NO_COLOR, TERM, COLUMNS and LINES are allowed" "$(bash_payload 'NO_COLOR=1 TERM=dumb COLUMNS=80 LINES=24 ls')" "$XA"
# Options: whole words as listed, before operands; -- only after them; no bare -.
gap_case "options: cat x -- (BSD cat opens a file named --) is denied" reviewer "$(bash_payload 'cat README.md --')" "$(xd reviewer.form)"
gap_case "options: ls -- - (a symlink named -) is denied" reviewer "$(bash_payload 'ls -- -')" "$(xd reviewer.form)"
as_review "options control: cat -- x is allowed" "$(bash_payload 'cat -- README.md')" "$XA"
as_review "options control: ls -- DIR is allowed" "$(bash_payload 'ls -- xf')" "$XA"
as_review "options: cat - (stdin or a file named -) is denied" "$(bash_payload 'cat -')" "$(xd reviewer.form)"
as_review "options: an option after an operand is denied" "$(bash_payload 'cat README.md -n')" "$(xd reviewer.form)"
as_review "options: an unlisted cluster is denied" "$(bash_payload 'cat -nb README.md')" "$(xd reviewer.form)"
as_review "options: an attached value is denied" "$(bash_payload 'head -n5 README.md')" "$(xd reviewer.form)"
as_review "options: a long option with = is denied" "$(bash_payload 'head --lines=5 README.md')" "$(xd reviewer.form)"
as_review "options: a numeric shorthand is denied" "$(bash_payload 'head -5 README.md')" "$(xd reviewer.form)"
as_review "options: a value that starts with - is denied" "$(bash_payload 'grep -e -x README.md')" "$(xd reviewer.form)"
as_review "options: a non-numeric count is denied" "$(bash_payload 'head -n x README.md')" "$(xd reviewer.form)"
as_review "options control: head -n N is allowed" "$(bash_payload 'head -n 5 README.md')" "$XA"
as_review "options control: a listed cluster (ls -la) is allowed" "$(bash_payload 'ls -la xf')" "$XA"
# --context[=N] takes only an attached value (GNU and BSD), so it is a flag
# and the next word is the pattern; short -C takes the next word on both.
as_review "options: grep --context name /etc/passwd (the file is checked) is denied" "$(bash_payload 'grep --context name /etc/passwd')" "$(xd reviewer.path)"
as_review "options control: grep --context PATTERN FILE is allowed" "$(bash_payload 'grep --context name README.md')" "$XA"
as_review "options: grep --context=N (attached value) is denied" "$(bash_payload 'grep --context=2 name README.md')" "$(xd reviewer.form)"
as_review "options control: grep -C N PATTERN FILE is allowed" "$(bash_payload 'grep -C 2 hello README.md')" "$XA"
as_review "options: grep -CN (attached value) is denied" "$(bash_payload 'grep -C2 hello README.md')" "$(xd reviewer.form)"
as_review "options: grep -f FILE (patterns from a file) is denied" "$(bash_payload 'grep -f README.md README.md')" "$(xd reviewer.form)"
as_review "options: grep --file FILE is denied" "$(bash_payload 'grep --file README.md README.md')" "$(xd reviewer.form)"
as_review "options: rg -f FILE is denied" "$(bash_payload 'rg --no-config -f README.md README.md')" "$(xd reviewer.form)"
as_review "options control: grep --include GLOB -r PATTERN DIR is allowed" "$(bash_payload "grep --include '*.md' -r hello xf")" "$XA"
as_review "options control: nl -ba and sha256sum are allowed" "$(bash_payload 'nl -ba README.md && sha256sum README.md')" "$XA"
as_review "options control: grep -A N and -B N are allowed" "$(bash_payload 'grep -A 2 -B 1 hello README.md')" "$XA"
as_review "options control: grep -e PATTERN FILE is allowed" "$(bash_payload 'grep -n -e hello README.md')" "$XA"
# Follow, output and write forms keep their specific rules.
as_review "follow: ls -L is denied" "$(bash_payload 'ls -L xf')" "$(xd reviewer.symlink_follow)"
as_review "follow: ls -RL is denied" "$(bash_payload 'ls -RL xf')" "$(xd reviewer.symlink_follow)"
as_review "follow control: ls -R is allowed" "$(bash_payload 'ls -R xf')" "$XA"
as_review "output: sort -o is denied" "$(bash_payload 'sort -o out README.md')" "$(xd reviewer.sort)"
as_review "output: sort -m /etc/passwd x is denied" "$(bash_payload 'sort -m /etc/passwd README.md')" '.decision == "deny"'
as_review "output control: sort -n x is allowed" "$(bash_payload 'sort -n README.md')" "$XA"
as_review "output: uniq in out is denied" "$(bash_payload 'uniq README.md out')" "$(xd reviewer.uniq)"
as_review "output control: uniq -c x is allowed" "$(bash_payload 'uniq -c README.md')" "$XA"
as_review "sed: sed -n r/etc/passwd x is denied" "$(bash_payload 'sed -n r/etc/passwd README.md')" "$(xd reviewer.sed)"
as_review "sed: sed -n wout x is denied" "$(bash_payload 'sed -n wout README.md')" "$(xd reviewer.sed)"
as_review "sed: sed -n -e '{ r /etc/passwd' -e '}' x is denied" "$(bash_payload "sed -n -e '{ r /etc/passwd' -e '}' README.md")" "$(xd reviewer.sed)"
as_review "sed: sed -n '1p;w out' x is denied" "$(bash_payload "sed -n '1p;w out' README.md")" "$(xd reviewer.sed)"
as_review "sed: sed -i is denied" "$(bash_payload 'sed -i s/a/b/ README.md')" "$(xd reviewer.sed)"
as_review "sed: sed -n 'N,Mp' with no file is denied" "$(bash_payload "sed -n '1,2p'")" "$(xd reviewer.sed)"
as_review "sed control: sed -n 'N,Mp' FILE is allowed" "$(bash_payload "sed -n '1,20p' README.md")" "$XA"
as_review "sed control: sed -n '\$p' FILE is allowed" "$(bash_payload "sed -n '\$p' README.md")" "$XA"
as_review "sed: sed -n 'N,Mp' on an outward file is denied" "$(bash_payload "sed -n '1p' /etc/hosts")" "$(xd reviewer.path)"
# jq is not a reviewer read form: its programs load modules from a search path.
gap_case "jq: include with a search path (reads a .jq outside the checkout) is denied" reviewer "$(bash_payload "jq 'include \"x\" {search:\"/tmp\"}; .' README.md")" "$(xd reviewer.command)"
as_review "jq: a plain field read is denied too" "$(bash_payload "jq -r '.env' README.md")" "$(xd reviewer.command)"
# find: starting paths first, listed primaries only.
as_review "find: -L is denied" "$(bash_payload 'find -L xf')" "$(xd reviewer.symlink_follow)"
gap_case "find: -E (BSD option before the paths) is denied" reviewer "$(bash_payload 'find -E xf -name f')" "$(xd reviewer.form)"
gap_case "find: -f PATH (BSD hides a path operand) is denied" reviewer "$(bash_payload 'find -f xf -name f')" "$(xd reviewer.form)"
gap_case "find: -Bnewer FILE is denied" reviewer "$(bash_payload 'find xf -Bnewer README.md')" "$(xd reviewer.form)"
gap_case "find: -samefile FILE is denied" reviewer "$(bash_payload 'find xf -samefile README.md')" "$(xd reviewer.form)"
as_review "find: -newer FILE is denied" "$(bash_payload 'find xf -newer README.md')" "$(xd reviewer.form)"
as_review "find: -exec is denied" "$(bash_payload 'find xf -exec cat README.md')" "$(xd reviewer.find)"
as_review "find: -delete is denied" "$(bash_payload 'find xf -name f -delete')" "$(xd reviewer.find)"
as_review "find: a negative -mtime value is denied" "$(bash_payload 'find xf -mtime -1')" "$(xd reviewer.form)"
as_review "find: an outward start path is denied" "$(bash_payload 'find xf/src -name secret.txt')" "$(xd reviewer.path)"
as_review "find control: find PATH -type f -name PATTERN is allowed" "$(bash_payload "find xf -type f -name '*.txt' -maxdepth 2")" "$XA"
# diff: regular files only (directory diff follows outward leaf symlinks).
as_review "diff: two directories with outward leaf symlinks are denied" "$(bash_payload 'diff xf/dirA xf/dirB')" "$(xd reviewer.symlink_follow)"
as_review "diff: an outward leaf symlink operand is denied" "$(bash_payload 'diff xf/dirA/leak xf/dirB/f')" "$(xd reviewer.path)"
as_review "diff: -r is denied" "$(bash_payload 'diff -r xf/dirA/f xf/dirB/f')" "$(xd reviewer.symlink_follow)"
as_review "diff control: two regular files are allowed" "$(bash_payload 'diff -u xf/dirA/f xf/dirB/f')" "$XA"
# Symlinks are resolved for every path operand.
as_review "symlink: cat through an outward directory symlink is denied" "$(bash_payload 'cat xf/src/secret.txt')" "$(xd reviewer.path)"
as_review "symlink: grep -r on an outward directory symlink is denied" "$(bash_payload 'grep -r secret xf/src')" "$(xd reviewer.path)"
as_review "symlink: an outward leaf symlink is denied" "$(bash_payload 'head -n 1 xf/dirA/leak')" "$(xd reviewer.path)"
as_review "symlink control: grep -r in the checkout is allowed" "$(bash_payload 'grep -r hello xf')" "$XA"
# git: subcommands, revision words, pathspecs, blame and config.
as_review "git: diff --output is denied" "$(bash_payload 'git diff --output x')" "$(xd reviewer.git)"
as_review "git: diff /etc/passwd /dev/null (falls back to --no-index) is denied" "$(bash_payload 'git diff /etc/passwd /dev/null')" "$(xd reviewer.path)"
as_review "git: diff README.md /dev/null is denied (revision word starts with /)" "$(bash_payload 'git diff README.md /dev/null')" "$(xd reviewer.git)"
as_review "git: diff a/../../etc/passwd x is denied" "$(bash_payload 'git diff a/../../etc/passwd README.md')" "$(xd reviewer.path)"
as_review "git: a dot-led revision component is denied" "$(bash_payload 'git log xf/.hidden')" "$(xd reviewer.git)"
as_review "git: a // in a revision word is denied" "$(bash_payload 'git log origin//main')" "$(xd reviewer.git)"
as_review "git: a revision word through an outward symlink is denied" "$(bash_payload 'git log xf/src')" "$(xd reviewer.path)"
as_review "git: REV:PATH with a dot-led path is denied" "$(bash_payload "git show 'HEAD:.env'")" "$(xd reviewer.git)"
as_review "git: an index path (:PATH) is denied" "$(bash_payload 'git show :README.md')" "$(xd reviewer.git)"
as_review "git: unquoted HEAD~1 is denied (zsh EXTENDED_GLOB)" "$(bash_payload 'git diff HEAD~1')" "$(xd reviewer.shell)"
as_review "git control: quoted 'HEAD~1' -- PATH is allowed" "$(bash_payload "git diff 'HEAD~1' -- README.md")" "$XA"
as_review "git control: git diff --stat REV..REV is allowed" "$(bash_payload 'git diff --stat main..HEAD')" "$XA"
as_review "git control: git show REV:PATH is allowed" "$(bash_payload 'git show HEAD:README.md')" "$XA"
as_review "git: blame PATH without -- is denied" "$(bash_payload 'git blame xf/src/secret.txt')" "$(xd reviewer.git)"
as_review "git: blame -- PATH through an outward symlink is denied" "$(bash_payload 'git blame -- xf/src/secret.txt')" "$(xd reviewer.path)"
as_review "git: blame with two revisions is denied" "$(bash_payload 'git blame HEAD main -- README.md')" "$(xd reviewer.git)"
as_review "git control: blame [REV] -- PATH is allowed" "$(bash_payload 'git blame HEAD -- README.md')" "$XA"
as_review "git: diff --no-index of two directories is denied" "$(bash_payload 'git diff --no-index xf/dirA xf/dirB')" "$(xd reviewer.symlink_follow)"
as_review "git: diff --no-index through an outward leaf symlink is denied" "$(bash_payload 'git diff --no-index -- xf/dirA/leak xf/dirB/f')" "$(xd reviewer.path)"
as_review "git: diff --no-index of three files is denied" "$(bash_payload 'git diff --no-index xf/dirA/f xf/dirB/f README.md')" "$(xd reviewer.git)"
as_review "git control: diff --no-index of two regular files is allowed" "$(bash_payload 'git diff --no-index -- xf/dirA/f xf/dirB/f')" "$XA"
as_review "git: ls-files -X/etc/passwd is denied" "$(bash_payload 'git ls-files -X/etc/passwd')" "$(xd reviewer.git)"
as_review "git: ls-files -X FILE is denied" "$(bash_payload 'git ls-files -X README.md')" "$(xd reviewer.git)"
as_review "git: a pathspec glob is denied" "$(bash_payload "git ls-files -- '*.md'")" "$(xd path.dynamic)"
as_review "git: pathspec magic is denied" "$(bash_payload "git ls-files -- ':(top)README.md'")" "$(xd path.dynamic)"
as_review "git: a glob word without -- (read as a pathspec) is denied" "$(bash_payload "git log 'v[1]'")" "$(xd path.dynamic)"
as_review "git control: a glob pathspec under --literal-pathspecs is allowed" "$(bash_payload "git --literal-pathspecs ls-files -- '*.md'")" "$XA"
as_review "git control: ls-files -- PATH is allowed" "$(bash_payload 'git ls-files -- README.md')" "$XA"
gap_case "git: grep -f -q -- x (-q read as the pattern file) is denied" reviewer "$(bash_payload 'git grep -f -q -- README.md')" "$(xd reviewer.git)"
as_review "git control: grep -n -e PATTERN -- PATH is allowed" "$(bash_payload 'git grep -n -e hello -- README.md')" "$XA"
as_review "git: config --list without --file is denied" "$(bash_payload 'git config --list')" "$(xd reviewer.git)"
as_review "git: config --get-regexp without --file is denied" "$(bash_payload 'git config --get-regexp .')" "$(xd reviewer.git)"
as_review "git: config --get KEY without --file is denied" "$(bash_payload 'git config --get user.email')" "$(xd reviewer.git)"
as_review "git: config --file outside the checkout is denied" "$(bash_payload 'git config --file /etc/gitconfig --list')" "$(xd reviewer.path)"
as_review "git: config --file KEY VALUE (a write) is denied" "$(bash_payload 'git config --file xf/config core.bare true')" "$(xd reviewer.git)"
as_review "git control: config --get core.hooksPath is allowed" "$(bash_payload 'git config --get core.hooksPath')" "$XA"
as_review "git control: config --get-all remote.origin.fetch is allowed" "$(bash_payload 'git config --get-all remote.origin.fetch')" "$XA"
as_review "git control: config --file FILE --list is allowed" "$(bash_payload 'git config --file xf/config --list')" "$XA"
as_review "git control: config -f FILE --get KEY is allowed" "$(bash_payload 'git config -f xf/config --get core.bare')" "$XA"
as_review "git: reflog expire is denied" "$(bash_payload 'git reflog expire')" "$(xd reviewer.git)"
as_review "git: reflog REF without show is denied" "$(bash_payload 'git reflog HEAD')" "$(xd reviewer.git)"
as_review "git control: reflog show REV is allowed" "$(bash_payload 'git reflog show -n 5 HEAD')" "$XA"
as_review "git: remote show (contacts the remote) is denied" "$(bash_payload 'git remote show origin')" "$(xd reviewer.git)"
as_review "git: -c is denied" "$(bash_payload 'git -c core.pager=cat log')" "$(xd reviewer.git)"
as_review "git: --git-dir is denied" "$(bash_payload 'git --git-dir xf log')" "$(xd reviewer.git)"
as_review "git: -C DIR is denied (git would read that repository's config)" "$(bash_payload 'git -C xf status --short')" "$(xd reviewer.git)"
as_review "git: -C . is denied" "$(bash_payload 'git -C . status')" "$(xd reviewer.git)"
as_review "git control: -P (no pager) is allowed" "$(bash_payload 'git -P log -n 1 --oneline')" "$XA"
as_review "git control: log --format=FORMAT (a listed attached value) is allowed" "$(bash_payload 'git --no-pager log -n 1 --format=%H')" "$XA"
as_review "git: log --format=VALUE starting with - is denied" "$(bash_payload 'git log --format=-x')" "$(xd reviewer.git)"
as_review "git: an unlisted attached value is denied" "$(bash_payload 'git log --output=x')" "$(xd reviewer.git)"
as_review "git control: status --porcelain=v1 --untracked-files=all --no-renames is allowed" "$(bash_payload 'git status --porcelain=v1 --untracked-files=all --no-renames')" "$XA"
as_review "git control: tag --list --sort=-KEY --format FORMAT -- PATTERN is allowed" "$(bash_payload "git tag --list --sort=-creatordate --format refname -- 'v*'")" "$XA"
as_review "git: tag --list -- PATTERN --force is denied" "$(bash_payload "git tag --list -- 'v*' --force")" "$(xd reviewer.git)"
as_review "git: tag -- PATTERN without --list is denied" "$(bash_payload "git tag -- 'v*'")" "$(xd reviewer.git)"
as_review "git: branch --list -- NAME is denied" "$(bash_payload 'git branch --list -- main')" "$(xd reviewer.git)"
as_review "git control: reflog show --date=FORMAT REV is allowed" "$(bash_payload 'git reflog show --date=iso HEAD')" "$XA"
as_review "git control: remote show -n NAME and get-url --push NAME are allowed" "$(bash_payload 'git remote show -n origin && git remote get-url --push origin')" "$XA"
as_review "git: remote show -n NAME EXTRA is denied" "$(bash_payload 'git remote show -n origin extra')" "$(xd reviewer.git)"
# Messages: the pane's own delivered files and drafts stay readable.
as_review "messages control: an own draft is readable with the exact grammar" "$(bash_payload "cat '$NF_DIR/verdict.md'")" '.decision == "allow" and .rule == "coordination.message_read"'
as_review "messages control: an own draft is readable with head -n N" "$(bash_payload "head -n 1 '$NF_DIR/verdict.md'")" '.decision == "allow" and .rule == "coordination.message_read"'
as_review "messages: an own draft read inside a pipeline is denied (one command alone)" "$(bash_payload "head -n 1 '$NF_DIR/verdict.md' | wc -l")" "$(xd coordination.message_read)"
as_review "messages: a peer draft is denied" "$(bash_payload "cat '$ROOT/.tmp/messages/drafts/$EXEC_PANE/peer.md'")" "$(xd coordination.message_read)"
as_review "messages: git reading an own draft is denied" "$(bash_payload "git diff -- '$NF_DIR/verdict.md'")" "$(xd coordination.message_read)"
rm -f "$CHILD/-" "$CHILD/--"
BASELINE_POLICY="$BASELINE_POLICY_0127"

echo "== 0.12.11 claimed reviewers fail closed without a readable config =="
# run_claim ROLE PANE CONFIG [env...]: --decision-json with no harness mode.
run_claim() {
  local role="$1" pane="$2" config="$3"
  shift 3
  printf '%s' "$(bash_payload 'rm -rf /')" | env -u TMUX -u TMUX_PANE -u SESSION_WORKSPACE_HARNESS_MODE \
    -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME \
    SESSION_WORKSPACE_CONFIG="$config" SESSION_WORKSPACE_ROLE="$role" SESSION_WORKSPACE_PANE_NAME="$pane" \
    CLAUDE_HOME="$FAKE_CLAUDE" CODEX_HOME="$FAKE_CODEX" "$@" "$PY" "$POLICY" --decision-json 2>&1
}
claim_case() {
  local label="$1" expression="$2" out
  shift 2
  out="$(run_claim "$@")"
  if printf '%s' "$out" | jq -e "$expression" >/dev/null 2>&1; then pass "$label"; else fail "$label" "$out"; fi
}
CLAIM='.decision == "deny" and .rule == "identity.reviewer" and .diagnostic.reason == "hook.identity.reviewer"'
INACTIVE='.decision == "allow" and .rule == "inactive" and .active == false'
claim_case "claim: role reviewer with no SESSION_WORKSPACE_CONFIG is denied" "$CLAIM" reviewer "" ""
claim_case "claim: a role naming reviewer as a word is denied" "$CLAIM" code-reviewer "" ""
claim_case "claim: a pane name naming reviewer is denied" "$CLAIM" "" "example-app-api-reviewer" ""
claim_case "claim: an unreadable config is denied" "$CLAIM" reviewer "$REVIEW_PANE" "$ROOT/.agent-workspace/missing.json"
claim_case "claim: a config that is not JSON is denied" "$CLAIM" reviewer "$REVIEW_PANE" "$BROKEN_CONFIG"
claim_case "claim control: a valid config with the harness off stays a no-op" "$INACTIVE" reviewer "$REVIEW_PANE" "$OFF_CONFIG"
claim_case "claim control: a schema v1 config stays a no-op" "$INACTIVE" reviewer "$REVIEW_PANE" "$V1_CONFIG"
claim_case "claim control: an executor with no config stays a no-op" "$INACTIVE" executor "example-app-api-executor" ""
claim_case "claim control: a name that only contains the letters (previewer) is not a claim" "$INACTIVE" previewer "" ""
claim_case "claim control: no workspace identity at all stays a no-op" "$INACTIVE" "" "" ""
if command -v tmux >/dev/null 2>&1; then
  CLAIM_SOCK="$TMPROOT/claim-tmux.sock"
  if LC_ALL=C.UTF-8 tmux -S "$CLAIM_SOCK" new-session -d -s claim 'sleep 300' 2>/dev/null; then
    CLAIM_PANE="$(tmux -S "$CLAIM_SOCK" display-message -p -t claim '#{pane_id}')"
    tmux -S "$CLAIM_SOCK" set-option -p -t "$CLAIM_PANE" @name example-app-api-reviewer
    claim_case "claim: a tmux pane @name naming reviewer is denied" "$CLAIM" "" "" "" TMUX="$CLAIM_SOCK,1,0" TMUX_PANE="$CLAIM_PANE"
    tmux -S "$CLAIM_SOCK" set-option -p -t "$CLAIM_PANE" @name example-app-api-executor
    claim_case "claim control: a tmux pane @name without reviewer stays a no-op" "$INACTIVE" "" "" "" TMUX="$CLAIM_SOCK,1,0" TMUX_PANE="$CLAIM_PANE"
    tmux -S "$CLAIM_SOCK" kill-server 2>/dev/null || true
  else
    echo "  (tmux @name claim cases skipped: could not start a private tmux server)"
  fi
else
  echo "  (tmux @name claim cases skipped: tmux is not installed)"
fi
printf '%s' "$(bash_payload 'rm -rf /')" | env -u TMUX -u TMUX_PANE -u SESSION_WORKSPACE_CONFIG -u SESSION_WORKSPACE_HARNESS_MODE \
  SESSION_WORKSPACE_ROLE=reviewer bash "$HERE/harness-hook.sh" >"$TMPROOT/claim.out" 2>"$TMPROOT/claim.err"
CLAIM_RC=$?
if [ "$CLAIM_RC" -eq 2 ] && grep -q '^BLOCKED by session-workspace strict-v1 \[identity.reviewer\]' "$TMPROOT/claim.err"; then
  pass "claim: the hook wrapper refuses a claimed reviewer with no config (exit 2)"
else
  fail "claim: the hook wrapper refuses a claimed reviewer with no config (exit 2)" "rc=$CLAIM_RC $(cat "$TMPROOT/claim.err")"
fi
printf '%s' "$(bash_payload 'rm -rf /')" | env -u TMUX -u TMUX_PANE -u SESSION_WORKSPACE_HARNESS_MODE \
  SESSION_WORKSPACE_ROLE=reviewer SESSION_WORKSPACE_CONFIG="$OFF_CONFIG" bash "$HERE/harness-hook.sh" >"$TMPROOT/claim.out" 2>"$TMPROOT/claim.err"
CLAIM_RC=$?
if [ "$CLAIM_RC" -eq 0 ] && [ ! -s "$TMPROOT/claim.err" ] && [ ! -s "$TMPROOT/claim.out" ]; then
  pass "claim control: the hook wrapper keeps a claimed reviewer with a harness-off config a silent no-op"
else
  fail "claim control: the hook wrapper keeps a claimed reviewer with a harness-off config a silent no-op" "rc=$CLAIM_RC $(cat "$TMPROOT/claim.err")"
fi

echo "== 0.12.11 read-only test mode (--as-role / --as-cwd) =="
# run_as ROLE CWD PAYLOAD [env...]: the test mode under a deliberately wrong
# live identity, which it must ignore.
run_as() {
  local role="$1" cwd="$2" payload="$3"
  shift 3
  printf '%s' "$payload" | env SESSION_WORKSPACE_CONFIG="$CONFIG" SESSION_WORKSPACE_PROJECT_ROOT="$ROOT" \
    SESSION_WORKSPACE_PANE_NAME="$MASTER_PANE" SESSION_WORKSPACE_ROLE=master SESSION_WORKSPACE_PANE_CWD="$ROOT" \
    SESSION_WORKSPACE_HARNESS_MODE=audit CLAUDE_HOME="$FAKE_CLAUDE" CODEX_HOME="$FAKE_CODEX" "$@" \
    "$PY" "$POLICY" --decision-json --as-role "$role" --as-cwd "$cwd" 2>&1
}
as_case() {
  local label="$1" expression="$2" out
  shift 2
  out="$(run_as "$@")"
  if printf '%s' "$out" | jq -e "$expression" >/dev/null 2>&1; then pass "$label"; else fail "$label" "$out"; fi
}
AS_KEYS='keys == ["active","decision","diagnostic","mode","pane","profile","reason","role","rule","tool"]'
as_case "test mode: a listed read in the checkout is allowed as a reviewer" "$AS_KEYS and .decision == \"allow\" and .role == \"reviewer\" and .mode == \"enforce\" and .pane == \"as-role\"" reviewer "$CHILD" "$(bash_payload 'cat README.md')"
as_case "test mode: an outward read is denied as a reviewer (enforce, despite a live audit identity)" '.decision == "deny" and .rule == "reviewer.path" and .diagnostic.reason == "hook.reviewer.path"' reviewer "$CHILD" "$(bash_payload 'cat /etc/hosts')"
as_case "test mode: a bypass class is denied as a reviewer" '.decision == "deny" and .rule == "reviewer.shell"' reviewer "$CHILD" "$(bash_payload 'cat ^README.md')"
as_case "test mode: a sibling checkout is outside the given cwd" '.decision == "deny" and .rule == "reviewer.path"' reviewer "$CHILD" "$(bash_payload "cat $ROOT/component-b/x")"
as_case "test mode: the executor floor applies with --as-role executor" '.decision == "deny" and .rule == "executor.containment"' executor "$CHILD" "$(bash_payload 'touch ../component-b/x')"
as_case "test mode: an executor write inside the cwd is allowed" '.decision == "allow" and .role == "executor"' executor "$CHILD" "$(bash_payload 'touch notes.md')"
as_case "test mode: an edit tool is decided too" '.decision == "deny" and .rule == "reviewer.readonly"' reviewer "$CHILD" "$(edit_payload README.md)"
as_case "test mode: malformed payload JSON fails closed" '.decision == "deny" and .rule == "input.json"' reviewer "$CHILD" '{not json'
for bad in "--as-role orchestrator --as-cwd $CHILD" "--as-role reviewer --as-cwd $TMPROOT/missing-dir" "--as-role reviewer" \
           "--as-cwd $CHILD" "--decision-json --as-role reviewer --as-cwd $CHILD --codex-hook-output" \
           "--decision-json --as-role reviewer --as-role reviewer --as-cwd $CHILD"; do
  case "$bad" in --decision-json*) args="$bad" ;; *) args="--decision-json $bad" ;; esac
  [ "$bad" = "--as-role reviewer" ] && args="--as-role reviewer --as-cwd $CHILD"
  # shellcheck disable=SC2086
  printf '{}' | "$PY" "$POLICY" $args >"$TMPROOT/as.out" 2>"$TMPROOT/as.err"
  AS_RC=$?
  if [ "$AS_RC" -eq 2 ] && [ ! -s "$TMPROOT/as.out" ] && grep -q 'test mode' "$TMPROOT/as.err"; then
    pass "test mode: usage error, no decision: $args"
  else
    fail "test mode: usage error, no decision: $args" "rc=$AS_RC $(cat "$TMPROOT/as.out" "$TMPROOT/as.err")"
  fi
done
printf '%s' "$(bash_payload 'cat README.md')" | env SESSION_WORKSPACE_CONFIG="$CONFIG" \
  bash "$HERE/harness-hook.sh" --decision-json --as-role reviewer --as-cwd "$CHILD" >"$TMPROOT/as.out" 2>"$TMPROOT/as.err"
AS_RC=$?
if [ "$AS_RC" -eq 2 ] && [ ! -s "$TMPROOT/as.out" ] && grep -q '^BLOCKED by session-workspace strict-v1 \[runtime.args\]' "$TMPROOT/as.err"; then
  pass "test mode: the hook wrapper never reaches it (BLOCKED runtime.args, exit 2)"
else
  fail "test mode: the hook wrapper never reaches it (BLOCKED runtime.args, exit 2)" "rc=$AS_RC $(cat "$TMPROOT/as.out" "$TMPROOT/as.err")"
fi
HELP_OUT="$("$PY" "$POLICY" --help 2>&1)"
if [ "$?" -eq 0 ] && printf '%s' "$HELP_OUT" | grep -q -- '--decision-json --as-role reviewer|executor --as-cwd DIR'; then
  pass "test mode: --help documents --as-role/--as-cwd"
else
  fail "test mode: --help documents --as-role/--as-cwd" "$HELP_OUT"
fi
LIVE_BEFORE="$(run_policy reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(bash_payload 'cat README.md')")"
run_as reviewer "$CHILD" "$(bash_payload 'cat /etc/hosts')" >/dev/null
LIVE_AFTER="$(run_policy reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(bash_payload 'cat README.md')")"
if [ "$LIVE_BEFORE" = "$LIVE_AFTER" ] && printf '%s' "$LIVE_AFTER" | jq -e '.decision == "allow" and .pane == "harness-sample-component-reviewer"' >/dev/null 2>&1; then
  pass "test mode: a test-mode run leaves the live decision unchanged"
else
  fail "test mode: a test-mode run leaves the live decision unchanged" "$LIVE_BEFORE / $LIVE_AFTER"
fi

echo "== role floor report (--floor-json / --probe-json) =="
# report_policy ROLE PANE CWD CONFIG MODE FLAG [extra env...]: a read-only
# report mode in one pane identity. Reads no stdin.
report_policy() {
  local role="$1" pane="$2" cwd="$3" config="$4" mode="$5" flag="$6"
  shift 6
  env -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME \
    SESSION_WORKSPACE_CONFIG="$config" SESSION_WORKSPACE_PROJECT_ROOT="$ROOT" \
    SESSION_WORKSPACE_PANE_NAME="$pane" SESSION_WORKSPACE_ROLE="$role" \
    SESSION_WORKSPACE_PANE_CWD="$cwd" SESSION_WORKSPACE_HARNESS_MODE="$mode" \
    CLAUDE_HOME="$FAKE_CLAUDE" CODEX_HOME="$FAKE_CODEX" "$@" \
    "$PY" "$POLICY" "$flag" </dev/null
}
FLOOR_DOC="$(env -u SESSION_WORKSPACE_CONFIG "$PY" "$POLICY" --floor-json </dev/null)"
if printf '%s' "$FLOOR_DOC" | jq -e '
    .profile == "strict-v1" and .configurable == false and .current == null
    and (.roles | keys) == ["confined_orchestrator","executor","orchestrator","reviewer"]
    and all(.roles[], .all; (.text | length) > 0 and (.floors | length) > 0 and (.probes | length) > 0)' >/dev/null 2>&1; then
  pass "--floor-json: the whole strict-v1 floor table, no resolved role outside a pane"
else
  fail "--floor-json: the whole strict-v1 floor table, no resolved role outside a pane" "$FLOOR_DOC"
fi
# Every floor rule is one the policy raises, and every reviewer/executor/
# orchestrator rule the policy raises is floor or a named optional guard pack.
RAISED_RULES="$(grep -o 'PolicyFailure("[a-z_.]*"' "$POLICY" | sed 's/PolicyFailure("//; s/"$//' | sort -u | jq -R . | jq -cs .)"
if printf '%s' "$FLOOR_DOC" | jq -e --argjson raised "$RAISED_RULES" '
    ([.roles[], .all | .floors[].clauses[].rules[]] | unique) as $floor
    | ($floor - $raised) == []
    and (([$raised[] | select(test("^(reviewer|executor|orchestrator)[.]"))] - $floor - (.guard_pack_rules | keys)) == [])
    and ((.guard_pack_rules | keys) - $raised) == []' >/dev/null 2>&1; then
  pass "--floor-json: floor rules match the rules harness-policy.py raises (guard-pack rules named separately)"
else
  fail "--floor-json: floor rules match the rules harness-policy.py raises (guard-pack rules named separately)" "$(printf '%s' "$FLOOR_DOC" | jq -c --argjson raised "$RAISED_RULES" '([.roles[], .all | .floors[].clauses[].rules[]] | unique) as $f | {floor_not_raised: ($f - $raised), raised_not_listed: ([$raised[] | select(test("^(reviewer|executor|orchestrator)[.]"))] - $f - (.guard_pack_rules | keys))}')"
fi
if printf '%s' "$FLOOR_DOC" | jq -e '
    all((.roles | to_entries[] | .value), .all;
      [.probes[].rule] as $probed
      | all(.floors[].clauses[]; (.rules - (.rules - $probed)) != []))' >/dev/null 2>&1; then
  pass "--floor-json: every floor clause has a probe case for one of its rules"
else
  fail "--floor-json: every floor clause has a probe case for one of its rules" "$FLOOR_DOC"
fi
if printf '%s' "$FLOOR_DOC" | jq -e '
    [.roles.reviewer.floors[].clauses[] | select(.rules | index("reviewer.readonly")) | .tables.EDIT_TOOL_NAMES[]] | index("notebookedit") != null and index("multiedit") != null' >/dev/null 2>&1; then
  pass "--floor-json: the reviewer edit family is read from EDIT_TOOL_NAMES"
else
  fail "--floor-json: the reviewer edit family is read from EDIT_TOOL_NAMES" "$FLOOR_DOC"
fi
for floor_case in \
  "reviewer|$REVIEW_PANE|$CHILD|$CONFIG|enforce|reviewer|deny" \
  "executor|$EXEC_PANE|$CHILD|$CONFIG|enforce|executor|deny" \
  "master|$MASTER_PANE|$ROOT|$CONFIG|enforce|orchestrator|deny" \
  "executor|$EXEC_PANE|$CHILD|$AUDIT_CONFIG|audit|executor|audit"; do
  IFS='|' read -r f_role f_pane f_cwd f_config f_mode f_key f_denied <<<"$floor_case"
  F_CURRENT="$(report_policy "$f_role" "$f_pane" "$f_cwd" "$f_config" "$f_mode" --floor-json | jq -r '.current')"
  F_PROBE="$(report_policy "$f_role" "$f_pane" "$f_cwd" "$f_config" "$f_mode" --probe-json)"
  if [ "$F_CURRENT" = "$f_key" ] && printf '%s' "$F_PROBE" | jq -e --arg key "$f_key" --arg mode "$f_mode" --arg denied "$f_denied" '
      .ran == true and .floor == $key and .mode == $mode and (.cases | length) > 10
      and all(.cases[]; .ok)
      and any(.cases[]; .expect == "allow") and all(.cases[] | select(.expect == "deny"); .decision == $denied)' >/dev/null 2>&1; then
    pass "--probe-json ($f_role, $f_mode): resolves the $f_key floor and decides every case as expected"
  else
    fail "--probe-json ($f_role, $f_mode): resolves the $f_key floor and decides every case as expected" "current=$F_CURRENT $(printf '%s' "$F_PROBE" | jq -c '{ran, reason, floor, mode, bad: [.cases[]? | select(.ok | not)]}' 2>&1)"
  fi
done
F_FORGED="$(report_policy executor "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce --probe-json)"
if printf '%s' "$F_FORGED" | jq -e '.ran == false and (.reason | startswith("identity not accepted [identity.role]")) and .cases == []' >/dev/null 2>&1; then
  pass "--probe-json: a forged identity runs no case"
else
  fail "--probe-json: a forged identity runs no case" "$F_FORGED"
fi
F_PROBE_ARGS="$(printf '{}' | env -u SESSION_WORKSPACE_CONFIG "$PY" "$POLICY" --probe-json --decision-json 2>&1)"
F_PROBE_ARGS_RC=$?
if [ "$F_PROBE_ARGS_RC" -eq 2 ] && printf '%s' "$F_PROBE_ARGS" | grep -q '^Usage:'; then
  pass "report modes take no other flag (usage error otherwise)"
else
  fail "report modes take no other flag (usage error otherwise)" "rc=$F_PROBE_ARGS_RC $F_PROBE_ARGS"
fi

echo "== audit vs enforce =="
expect "audit mode reports a policy denial as audit" reviewer "$REVIEW_PANE" "$CHILD" "$AUDIT_CONFIG" audit \
  "$(edit_payload 'src/file.ts')" '.decision == "audit" and .mode == "audit" and .rule == "reviewer.readonly"'
expect "audit mode still allows an allowed action" reviewer "$REVIEW_PANE" "$CHILD" "$AUDIT_CONFIG" audit \
  "$(bash_payload 'git status')" '.decision == "allow" and .mode == "audit"'
expect "audit mode identity failure is still a deny" reviewer unknown-pane "$CHILD" "$AUDIT_CONFIG" audit \
  "$(bash_payload 'git status')" '.decision == "deny" and .rule == "identity.pane"'

echo "== hook exit behavior =="
hook_run() {
  # hook_run ROLE PANE CWD CONFIG MODE PAYLOAD STDOUT_FILE STDERR_FILE [policy args...] -> exit status
  local role="$1" pane="$2" cwd="$3" config="$4" mode="$5" payload="$6" out="$7" err="$8"
  shift 8
  printf '%s' "$payload" | env \
    -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME \
    SESSION_WORKSPACE_CONFIG="$config" SESSION_WORKSPACE_PROJECT_ROOT="$ROOT" \
    SESSION_WORKSPACE_PANE_NAME="$pane" SESSION_WORKSPACE_ROLE="$role" \
    SESSION_WORKSPACE_PANE_CWD="$cwd" SESSION_WORKSPACE_HARNESS_MODE="$mode" \
    CLAUDE_HOME="$FAKE_CLAUDE" CODEX_HOME="$FAKE_CODEX" \
    "$PY" "$POLICY" "$@" >"$out" 2>"$err"
}
hook_run_closed_stdout() {
  # hook_run_closed_stdout ROLE PANE CWD CONFIG MODE PAYLOAD STDERR_FILE [policy args...] -> exit status
  local role="$1" pane="$2" cwd="$3" config="$4" mode="$5" payload="$6" err="$7"
  shift 7
  printf '%s' "$payload" | env \
    -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME \
    SESSION_WORKSPACE_CONFIG="$config" SESSION_WORKSPACE_PROJECT_ROOT="$ROOT" \
    SESSION_WORKSPACE_PANE_NAME="$pane" SESSION_WORKSPACE_ROLE="$role" \
    SESSION_WORKSPACE_PANE_CWD="$cwd" SESSION_WORKSPACE_HARNESS_MODE="$mode" \
    CLAUDE_HOME="$FAKE_CLAUDE" CODEX_HOME="$FAKE_CODEX" \
    "$PY" "$POLICY" "$@" 1>&- 2>"$err"
}
hook_run reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(edit_payload 'src/file.ts')" "$TMPROOT/enforce.out" "$TMPROOT/enforce.err"
ENFORCE_STATUS=$?
if [ "$ENFORCE_STATUS" -eq 2 ] && grep -q '^BLOCKED by session-workspace strict-v1 \[reviewer.readonly\]' "$TMPROOT/enforce.err" && [ ! -s "$TMPROOT/enforce.out" ]; then
  pass "enforce denial exits 2 with one concise stderr reason and no stdout"
else
  fail "enforce denial exits 2 with one concise stderr reason and no stdout" "status=$ENFORCE_STATUS err=$(cat "$TMPROOT/enforce.err") out=$(cat "$TMPROOT/enforce.out")"
fi
hook_run reviewer "$REVIEW_PANE" "$CHILD" "$AUDIT_CONFIG" audit "$(edit_payload 'src/file.ts')" "$TMPROOT/audit.out" "$TMPROOT/audit.err"
AUDIT_STATUS=$?
if [ "$AUDIT_STATUS" -eq 0 ] && grep -q '^AUDIT by session-workspace strict-v1 \[reviewer.readonly\]' "$TMPROOT/audit.err" && [ ! -s "$TMPROOT/audit.out" ]; then
  pass "audit denial exits 0, reports on stderr, never blocks"
else
  fail "audit denial exits 0, reports on stderr, never blocks" "status=$AUDIT_STATUS err=$(cat "$TMPROOT/audit.err")"
fi
hook_run reviewer "$REVIEW_PANE" "$CHILD" "$AUDIT_CONFIG" audit "$(codex_bash_payload 'pwd > out')" "$TMPROOT/codex-audit.out" "$TMPROOT/codex-audit.err" --codex-hook-output
CODEX_AUDIT_STATUS=$?
if [ "$CODEX_AUDIT_STATUS" -eq 0 ] && [ ! -s "$TMPROOT/codex-audit.err" ] && \
   jq -e 'keys == ["systemMessage"] and (.systemMessage | test("^AUDIT by session-workspace strict-v1 \\[reviewer.shell\\]: .+ \\(would deny in enforce mode\\)$"))' "$TMPROOT/codex-audit.out" >/dev/null 2>&1 && \
   [ "$(wc -l < "$TMPROOT/codex-audit.out" | tr -d ' ')" -eq 1 ]; then
  pass "Codex audit rendering emits exactly one inert systemMessage JSON object on stdout"
else
  fail "Codex audit rendering emits exactly one inert systemMessage JSON object on stdout" "status=$CODEX_AUDIT_STATUS out=$(cat "$TMPROOT/codex-audit.out") err=$(cat "$TMPROOT/codex-audit.err")"
fi
hook_run_closed_stdout reviewer "$REVIEW_PANE" "$CHILD" "$AUDIT_CONFIG" audit "$(edit_payload 'src/file.ts')" "$TMPROOT/codex-audit-closed.err" --codex-hook-output
CODEX_AUDIT_CLOSED_STATUS=$?
if [ "$CODEX_AUDIT_CLOSED_STATUS" -eq 0 ] && [ ! -s "$TMPROOT/codex-audit-closed.err" ]; then
  pass "Codex audit rendering failure cannot turn audit into a block"
else
  fail "Codex audit rendering failure cannot turn audit into a block" "status=$CODEX_AUDIT_CLOSED_STATUS err=$(cat "$TMPROOT/codex-audit-closed.err")"
fi
hook_run reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(bash_payload 'git status')" "$TMPROOT/allow.out" "$TMPROOT/allow.err"
ALLOW_STATUS=$?
if [ "$ALLOW_STATUS" -eq 0 ] && [ ! -s "$TMPROOT/allow.out" ] && [ ! -s "$TMPROOT/allow.err" ]; then
  pass "allow is silent (exit 0, no stdout, no stderr)"
else
  fail "allow is silent (exit 0, no stdout, no stderr)" "status=$ALLOW_STATUS out=$(cat "$TMPROOT/allow.out") err=$(cat "$TMPROOT/allow.err")"
fi
hook_run reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(bash_payload 'git status')" "$TMPROOT/codex-allow.out" "$TMPROOT/codex-allow.err" --codex-hook-output
CODEX_ALLOW_STATUS=$?
if [ "$CODEX_ALLOW_STATUS" -eq 0 ] && [ ! -s "$TMPROOT/codex-allow.out" ] && [ ! -s "$TMPROOT/codex-allow.err" ]; then
  pass "Codex rendering keeps allow silent"
else
  fail "Codex rendering keeps allow silent" "status=$CODEX_ALLOW_STATUS out=$(cat "$TMPROOT/codex-allow.out") err=$(cat "$TMPROOT/codex-allow.err")"
fi
hook_run reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(edit_payload 'src/file.ts')" "$TMPROOT/codex-deny.out" "$TMPROOT/codex-deny.err" --codex-hook-output
CODEX_DENY_STATUS=$?
if [ "$CODEX_DENY_STATUS" -eq 2 ] && [ ! -s "$TMPROOT/codex-deny.out" ] && grep -q '^BLOCKED by session-workspace strict-v1 \[reviewer.readonly\]' "$TMPROOT/codex-deny.err"; then
  pass "Codex rendering keeps enforce denial on stderr with exit 2"
else
  fail "Codex rendering keeps enforce denial on stderr with exit 2" "status=$CODEX_DENY_STATUS out=$(cat "$TMPROOT/codex-deny.out") err=$(cat "$TMPROOT/codex-deny.err")"
fi
hook_run_closed_stdout reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(edit_payload 'src/file.ts')" "$TMPROOT/codex-deny-closed.err" --codex-hook-output
CODEX_DENY_CLOSED_STATUS=$?
if [ "$CODEX_DENY_CLOSED_STATUS" -eq 2 ] && grep -q '^BLOCKED by session-workspace strict-v1 \[reviewer.readonly\]' "$TMPROOT/codex-deny-closed.err"; then
  pass "Codex rendering failure cannot change an enforce denial exit"
else
  fail "Codex rendering failure cannot change an enforce denial exit" "status=$CODEX_DENY_CLOSED_STATUS err=$(cat "$TMPROOT/codex-deny-closed.err")"
fi
hook_run reviewer unknown-pane "$CHILD" "$AUDIT_CONFIG" audit "$(bash_payload 'git status')" "$TMPROOT/drift.out" "$TMPROOT/drift.err"
DRIFT_STATUS=$?
if [ "$DRIFT_STATUS" -eq 2 ] && grep -q '^BLOCKED' "$TMPROOT/drift.err"; then
  pass "identity failure blocks (exit 2) even in audit mode"
else
  fail "identity failure blocks (exit 2) even in audit mode" "status=$DRIFT_STATUS err=$(cat "$TMPROOT/drift.err")"
fi
hook_run reviewer unknown-pane "$CHILD" "$AUDIT_CONFIG" audit "$(bash_payload 'git status')" "$TMPROOT/codex-drift.out" "$TMPROOT/codex-drift.err" --codex-hook-output
CODEX_DRIFT_STATUS=$?
if [ "$CODEX_DRIFT_STATUS" -eq 2 ] && [ ! -s "$TMPROOT/codex-drift.out" ] && grep -q '^BLOCKED' "$TMPROOT/codex-drift.err"; then
  pass "Codex rendering keeps integrity denial blocking in audit mode"
else
  fail "Codex rendering keeps integrity denial blocking in audit mode" "status=$CODEX_DRIFT_STATUS out=$(cat "$TMPROOT/codex-drift.out") err=$(cat "$TMPROOT/codex-drift.err")"
fi
printf '%s' "$(bash_payload 'rm -rf /')" | env -u SESSION_WORKSPACE_CONFIG -u SESSION_WORKSPACE_HARNESS_MODE "$PY" "$POLICY" >"$TMPROOT/inactive.out" 2>"$TMPROOT/inactive.err"
INACTIVE_STATUS=$?
if [ "$INACTIVE_STATUS" -eq 0 ] && [ ! -s "$TMPROOT/inactive.out" ] && [ ! -s "$TMPROOT/inactive.err" ]; then
  pass "inactive hook mode is a silent exit 0"
else
  fail "inactive hook mode is a silent exit 0" "status=$INACTIVE_STATUS"
fi
OUT="$("$PY" "$POLICY" --bogus </dev/null 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && printf '%s' "$OUT" | grep -q '^Usage:'; then
  pass "unknown argument prints usage and exits 2"
else
  fail "unknown argument prints usage and exits 2" "status=$STATUS $OUT"
fi
OUT="$("$PY" "$POLICY" --codex-hook-output --codex-hook-output </dev/null 2>&1)"
STATUS=$?
if [ "$STATUS" -eq 2 ] && printf '%s' "$OUT" | grep -q '^Usage:'; then
  pass "duplicate rendering flag prints usage and exits 2"
else
  fail "duplicate rendering flag prints usage and exits 2" "status=$STATUS $OUT"
fi

# --- Tier 1.4 (strict-v1 easing H1 + H4) --------------------------------------
# H1: a quoted or backslash-escaped literal path with *?{}[ no longer raises
# path.dynamic when the RAW scanner proved the metacharacters are not shell
# globs. Git still globs pathspecs by itself, so a glob-bearing git operand is
# admitted only under a parsed global --literal-pathspecs. $ and backtick stay
# dynamic, helper operands never get the easing, and every refusal below sits
# beside an allowed valid-path control.
echo "== Tier 1.4 H1: quoted literal paths =="
H1_ALLOW='.decision == "allow"'
H1_DYN='.decision == "deny" and .rule == "path.dynamic"'
mkdir -p "$CHILD/src/app/(x)/[id]" "$CHILD/src/app/[id]" "$CHILD/src/app/i" "$CHILD/src/app/d" "$ROOT/component-b/[id]"
for f in "src/app/(x)/[id]/page.tsx" "src/app/[id]/page.tsx" "src/app/i/page.tsx" "src/app/d/page.tsx"; do printf 'x\n' > "$CHILD/$f"; done
printf 'x\n' > "$ROOT/component-b/[id]/page.tsx"
ln -s README.md "$CHILD/ok[1]"
ln -s "$ROOT/component-b" "$CHILD/lnk[1]"
ln -s "$ROOT/component-b" "$CHILD/src/app/lk"
# executor
as_exec "H1 control: executor plain literal path is allowed" "$(bash_payload "cat src/app/i/page.tsx")" "$H1_ALLOW"
as_exec "H1 executor quoted route path with ( ) and [ ] is allowed" "$(bash_payload "cat 'src/app/(x)/[id]/page.tsx'")" "$H1_ALLOW"
as_exec "H1 executor double-quoted bracket path is allowed" "$(bash_payload 'cat "src/app/[id]/page.tsx"')" "$H1_ALLOW"
as_exec "H1 executor backslash-escaped brackets are literal and allowed (scanner treats them as non-glob)" "$(bash_payload 'cat src/app/\[id\]/page.tsx')" "$H1_ALLOW"
as_exec "H1 executor absolute quoted bracket path inside cwd is allowed" "$(bash_payload "cat '$CHILD/src/app/[id]/page.tsx'")" "$H1_ALLOW"
as_exec "H1 executor later segment of a composed command may carry a quoted bracket path" "$(bash_payload "ls src && cat 'src/app/[id]/page.tsx'")" "$H1_ALLOW"
as_exec "H1 executor unquoted glob is still denied" "$(bash_payload 'cat src/*.ts')" "$H1_DYN"
as_exec "H1 executor unquoted bracket glob is still denied" "$(bash_payload 'cat src/app/[id]/page.tsx')" "$H1_DYN"
as_exec "H1 executor unquoted brace expansion is still denied" "$(bash_payload 'cat src/app/{i,d}/page.tsx')" "$H1_DYN"
as_exec "H1 executor mixed quoted and unquoted glob tokens are denied" "$(bash_payload "cat 'src/app/[id]/page.tsx' src/b*")" "$H1_DYN"
as_exec "H1 control: the same quoted token without the unquoted glob is allowed" "$(bash_payload "cat 'src/app/[id]/page.tsx' src/app/i/page.tsx")" "$H1_ALLOW"
as_exec "H1 executor single-quoted dollar path is still dynamic" "$(bash_payload "cat '\$HOME/x'")" "$H1_DYN"
as_exec "H1 executor quoted dollar plus bracket path is still dynamic" "$(bash_payload "cat '\$HOME/src/app/[id]/page.tsx'")" "$H1_DYN"
as_exec "H1 executor double-quoted dollar path is still dynamic" "$(bash_payload 'cat "$HOME/x"')" "$H1_DYN"
as_exec "H1 executor backtick text in single quotes is still dynamic for a path" "$(bash_payload "cat 'src/\`id\`/page.tsx'")" "$H1_DYN"
as_exec "H1 executor quoted bracket path outside containment is denied" "$(bash_payload "cat '$ROOT/component-b/[id]/page.tsx'")" '.decision == "deny" and .rule == "executor.containment"'
as_exec "H1 executor quoted bracket path through a symlink escape is denied" "$(bash_payload "cat 'escape-link/[id]/page.tsx'")" '.decision == "deny" and .rule == "executor.containment"'
as_exec "H1 executor quoted path through a symlink inside src escaping is denied" "$(bash_payload "cat 'src/app/lk/[id]/page.tsx'")" '.decision == "deny" and .rule == "executor.containment"'
as_exec "H1 executor bare quoted name that is an escaping symlink is denied" "$(bash_payload "cat 'lnk[1]'")" '.decision == "deny" and .rule == "executor.containment"'
as_exec "H1 control: bare quoted name that is a contained symlink is allowed" "$(bash_payload "cat 'ok[1]'")" "$H1_ALLOW"
as_exec "H1 executor quoted glob path with a .. component is denied" "$(bash_payload "cat 'src/app/*/../../README.md'")" "$H1_DYN"
as_exec "H1 control: a .. component without glob characters keeps its old allow" "$(bash_payload "cat src/app/../../README.md")" "$H1_ALLOW"
as_exec "H1 executor quoted bracket executable path is not eased" "$(bash_payload "'./src/app/[id]/run.sh'")" "$H1_DYN"
as_exec "H1 executor env --chdir with a bracket is not eased" "$(bash_payload "env --chdir='src/app/[id]' ls")" "$H1_DYN"
as_exec "H1 control: env --chdir to a plain directory is allowed" "$(bash_payload "env --chdir=src/app/i ls")" "$H1_ALLOW"
# reviewer
as_review "H1 control: reviewer plain literal read is allowed" "$(bash_payload "cat src/app/i/page.tsx")" "$H1_ALLOW"
as_review "H1 reviewer quoted route path with ( ) and [ ] is allowed" "$(bash_payload "cat 'src/app/(x)/[id]/page.tsx'")" "$H1_ALLOW"
as_review "H1 reviewer shasum of a quoted bracket path is allowed" "$(bash_payload "shasum -a 256 'src/app/[id]/page.tsx'")" "$H1_ALLOW"
as_review "H1 reviewer backslash escapes are outside the strict word form (0.12.11)" "$(bash_payload 'cat src/app/\[id\]/page.tsx')" '.decision == "deny" and .rule == "reviewer.shell"'
as_review "H1 reviewer unquoted glob is still denied" "$(bash_payload 'cat src/*.ts')" '.decision == "deny" and .rule == "reviewer.shell"'
as_review "H1 reviewer mixed quoted and unquoted glob tokens are denied" "$(bash_payload "cat 'src/app/[id]/page.tsx' src/b*")" '.decision == "deny" and .rule == "reviewer.shell"'
as_review "H1 reviewer single-quoted dollar path is still dynamic" "$(bash_payload "cat '\$HOME/x'")" "$H1_DYN"
as_review "H1 reviewer quoted bracket path through a symlink escape is denied" "$(bash_payload "cat 'escape-link/[id]/page.tsx'")" '.decision == "deny" and .rule == "reviewer.path"'
as_review "H1 reviewer quoted bracket path outside the reviewer roots is denied" "$(bash_payload "cat '$ROOT/component-b/[id]/page.tsx'")" '.decision == "deny" and .rule == "reviewer.path"'
as_review "H1 reviewer quoted glob path with a .. component is denied" "$(bash_payload "cat 'src/app/*/../../README.md'")" "$H1_DYN"
as_review "H1 reviewer rg with a quoted bracket path operand is allowed" "$(bash_payload "rg --no-config needle 'src/app/[id]/page.tsx'")" "$H1_ALLOW"
# git pathspecs: shell quoting does not make them literal
as_exec "H1 control: executor git add of a plain path needs no pathspec option" "$(bash_payload "git add -- src/app/i/page.tsx")" "$H1_ALLOW"
as_exec "H1 executor git --literal-pathspecs add of a quoted bracket path is allowed" "$(bash_payload "git --literal-pathspecs add -- 'src/app/[id]/page.tsx'")" "$H1_ALLOW"
as_exec "H1 executor git --literal-pathspecs add with a route group path is allowed" "$(bash_payload "git --literal-pathspecs add -- 'src/app/(x)/[id]/page.tsx'")" "$H1_ALLOW"
as_exec "H1 executor git -C . --literal-pathspecs add is allowed" "$(bash_payload "git -C . --literal-pathspecs add -- 'src/app/[id]/page.tsx'")" "$H1_ALLOW"
as_exec "H1 executor git --literal-pathspecs -C . add is allowed" "$(bash_payload "git --literal-pathspecs -C . add -- 'src/app/[id]/page.tsx'")" "$H1_ALLOW"
as_exec "H1 executor git --literal-pathspecs commit with a quoted bracket pathspec is allowed" "$(bash_payload "git --literal-pathspecs commit -m 'route [id]' -- 'src/app/[id]/page.tsx'")" "$H1_ALLOW"
as_exec "H1 executor git add of a quoted bracket path without --literal-pathspecs is denied" "$(bash_payload "git add -- 'src/app/[id]/page.tsx'")" "$H1_DYN"
as_exec "H1 executor git add of an escaped bracket path without --literal-pathspecs is denied" "$(bash_payload 'git add -- src/app/\[id\]/page.tsx')" "$H1_DYN"
as_exec "H1 executor git -C . add of a quoted bracket path without --literal-pathspecs is denied" "$(bash_payload "git -C . add -- 'src/app/[id]/page.tsx'")" "$H1_DYN"
as_exec "H1 executor --literal-pathspecs after the subcommand is not a global option and is denied" "$(bash_payload "git add --literal-pathspecs -- 'src/app/[id]/page.tsx'")" "$H1_DYN"
as_exec "H1 executor --literal-pathspecs given as the -C value is not the option and is denied" "$(bash_payload "git -C --literal-pathspecs add -- 'src/app/[id]/page.tsx'")" "$H1_DYN"
as_exec "H1 executor git --literal-pathspecs with --glob-pathspecs is denied" "$(bash_payload "git --literal-pathspecs --glob-pathspecs add -- 'src/app/[id]/page.tsx'")" "$H1_DYN"
as_exec "H1 executor git --glob-pathspecs then --literal-pathspecs is denied" "$(bash_payload "git --glob-pathspecs --literal-pathspecs add -- 'src/app/[id]/page.tsx'")" "$H1_DYN"
as_exec "H1 executor git --literal-pathspecs with --icase-pathspecs is denied" "$(bash_payload "git --literal-pathspecs --icase-pathspecs add -- 'src/app/[id]/page.tsx'")" "$H1_DYN"
as_exec "H1 executor git --literal-pathspecs with --noglob-pathspecs is denied" "$(bash_payload "git --literal-pathspecs --noglob-pathspecs add -- 'src/app/[id]/page.tsx'")" "$H1_DYN"
as_exec "H1 executor git --literal-pathspecs add of :(glob) magic is denied" "$(bash_payload "git --literal-pathspecs add ':(glob)src/*'")" "$H1_DYN"
as_exec "H1 executor git --literal-pathspecs add of :(icase) magic beside a bracket path is denied" "$(bash_payload "git --literal-pathspecs add -- ':(icase)src/app/i/page.tsx' 'src/app/[id]/page.tsx'")" "$H1_DYN"
as_exec "H1 executor git --literal-pathspecs add of :/ top-level magic is denied" "$(bash_payload "git --literal-pathspecs add -- ':/src/app/[id]/page.tsx'")" "$H1_DYN"
as_exec "H1 executor git --pathspec-from-file beside a bracket path is denied" "$(bash_payload "git --literal-pathspecs add --pathspec-from-file=list.txt -- 'src/app/[id]/page.tsx'")" "$H1_DYN"
as_exec "H1 executor git --pathspec-from-file value form beside a bracket path is denied" "$(bash_payload "git --literal-pathspecs add --pathspec-from-file list.txt 'src/app/[id]/page.tsx'")" "$H1_DYN"
as_exec "H1 executor git -c before --literal-pathspecs (unparsed global form) is denied" "$(bash_payload "git -c core.quotepath=off --literal-pathspecs add -- 'src/app/[id]/page.tsx'")" "$H1_DYN"
as_exec "H1 executor git --literal-pathspecs unquoted bracket glob is still denied" "$(bash_payload "git --literal-pathspecs add -- src/app/[id]/page.tsx")" "$H1_DYN"
as_exec "H1 executor git --literal-pathspecs quoted \$ path is still dynamic" "$(bash_payload "git --literal-pathspecs add -- '\$HOME/src/[id]'")" "$H1_DYN"
as_exec "H1 executor git --literal-pathspecs quoted bracket path outside containment is denied" "$(bash_payload "git --literal-pathspecs add -- '$ROOT/component-b/[id]/page.tsx'")" '.decision == "deny" and .rule == "executor.containment"'
# Round 1: a -C other than `.` now ends the grant, so this refusal moved from
# executor.containment to path.dynamic (still denied). The control keeps the
# containment rule for the same -C without a glob operand.
as_exec "H1 executor git -C outside the checkout stays denied with --literal-pathspecs" "$(bash_payload "git --literal-pathspecs -C ../component-b add -- 'x[id]/page.tsx'")" "$H1_DYN"
as_exec "H1 control: executor git -C outside the checkout with a plain pathspec is denied by containment" "$(bash_payload "git --literal-pathspecs -C ../component-b add -- x.txt")" '.decision == "deny" and .rule == "executor.containment"'
as_review "H1 control: reviewer git log of a plain path is allowed" "$(bash_payload "git log -- src/app/i/page.tsx")" "$H1_ALLOW"
as_review "H1 reviewer git --literal-pathspecs log of a quoted bracket path is allowed" "$(bash_payload "git --literal-pathspecs log --oneline -- 'src/app/[id]/page.tsx'")" "$H1_ALLOW"
as_review "H1 reviewer git -C . --literal-pathspecs diff is denied (no -C in the exact forms)" "$(bash_payload "git -C . --literal-pathspecs diff -- 'src/app/[id]/page.tsx'")" '.decision == "deny" and .rule == "reviewer.git"'
as_review "H1 reviewer git --literal-pathspecs diff of a quoted bracket path is allowed (control)" "$(bash_payload "git --literal-pathspecs diff -- 'src/app/[id]/page.tsx'")" "$H1_ALLOW"
as_review "H1 reviewer git log of a quoted bracket path without --literal-pathspecs is denied" "$(bash_payload "git log -- 'src/app/[id]/page.tsx'")" "$H1_DYN"
as_review "H1 reviewer git --literal-pathspecs --glob-pathspecs log is denied (unlisted global option)" "$(bash_payload "git --literal-pathspecs --glob-pathspecs log -- 'src/app/[id]/page.tsx'")" '.decision == "deny" and .rule == "reviewer.git"'
as_review "H1 reviewer git --literal-pathspecs log of :(glob) magic is denied" "$(bash_payload "git --literal-pathspecs log -- ':(glob)src/*.tsx'")" "$H1_DYN"
as_review "H1 reviewer git --literal-pathspecs unquoted glob is denied" "$(bash_payload "git --literal-pathspecs log -- src/*.tsx")" '.decision == "deny" and .rule == "reviewer.shell"'
as_review "H1 reviewer git --literal-pathspecs still refuses a write subcommand" "$(bash_payload "git --literal-pathspecs add -- 'src/app/[id]/page.tsx'")" '.decision == "deny" and .rule == "reviewer.git"'
as_review "H1 reviewer git --literal-pathspecs bracket path through a symlink escape is denied" "$(bash_payload "git --literal-pathspecs log -- 'escape-link/[id]/page.tsx'")" '.decision == "deny" and .rule == "reviewer.path"'
# --- Tier 1.4 round 1: grant scope (R1 -C/global options, R2 subcommands, R3 bare
# names, deviation 4 magic). Every refusal is paired with an allowed control.
echo "== Tier 1.4 H1 round 1: git grant scope =="
RG_OUT="$TMPROOT/rg-outside"
mkdir -p "$RG_OUT" "$CHILD/sub[1]"
printf 'outside secret\n' > "$RG_OUT/probe.txt"
ln -s "$RG_OUT" "$CHILD/sub[1]/leak"
printf 'local control\n' > "$CHILD/local.txt"
printf 'p\n' > "$CHILD/plain.txt"; printf 'p\n' > "$CHILD/plain2.txt"; printf 'b\n' > "$CHILD/a[1]"
# R1: -C changes the operand base; only no -C or `-C .` may use the grant.
R1P="diff --no-index -- leak/probe.txt local.txt"
for role in exec review; do
  # The reviewer's exact git forms list no -C at all (reviewer.git); the
  # executor keeps the grant-scope rules.
  if [ "$role" = exec ]; then runner=as_exec; r1_c="$H1_DYN"; r1_c_ok="$H1_ALLOW"; else
    runner=as_review; r1_c='.decision == "deny" and .rule == "reviewer.git"'; r1_c_ok="$r1_c"; fi
  "$runner" "R1 $role: --literal-pathspecs -C './sub[1]' diff --no-index through a symlink is refused" "$(bash_payload "git --literal-pathspecs -C './sub[1]' $R1P")" "$r1_c"
  "$runner" "R1 $role: -C './sub[1]' before --literal-pathspecs is refused" "$(bash_payload "git -C './sub[1]' --literal-pathspecs $R1P")" "$r1_c"
  "$runner" "R1 $role: bare -C 'sub[1]' (no slash, no --literal-pathspecs; escaped on the 1.3a baseline) is refused" "$(bash_payload "git -C 'sub[1]' $R1P")" "$r1_c"
  "$runner" "R1 $role: bare -C 'sub[1]' with --literal-pathspecs is refused" "$(bash_payload "git --literal-pathspecs -C 'sub[1]' $R1P")" "$r1_c"
  # The reviewer's strict word form refuses the attached quote first.
  if [ "$role" = exec ]; then r1_attached="$H1_DYN"; else r1_attached='.decision == "deny" and .rule == "reviewer.shell"'; fi
  "$runner" "R1 $role: attached -C'sub[1]' is refused" "$(bash_payload "git --literal-pathspecs -C'sub[1]' $R1P")" "$r1_attached"
  "$runner" "R1 $role control: --literal-pathspecs -C . diff --no-index of contained files (reviewer: no -C)" "$(bash_payload "git --literal-pathspecs -C . diff --no-index -- local.txt local.txt")" "$r1_c_ok"
  "$runner" "R1 $role control: -C . before --literal-pathspecs (reviewer: no -C)" "$(bash_payload "git -C . --literal-pathspecs diff --no-index -- local.txt local.txt")" "$r1_c_ok"
  "$runner" "R1 $role control: plain contained diff --no-index is allowed" "$(bash_payload "git diff --no-index -- local.txt local.txt")" "$H1_ALLOW"
  "$runner" "R1 $role control: -C . with a quoted bracket pathspec (reviewer: no -C)" "$(bash_payload "git --literal-pathspecs -C . diff -- 'src/app/[id]/page.tsx'")" "$r1_c_ok"
  "$runner" "R1 $role control: --literal-pathspecs with a quoted bracket pathspec is allowed" "$(bash_payload "git --literal-pathspecs diff -- 'src/app/[id]/page.tsx'")" "$H1_ALLOW"
  "$runner" "R1 $role: -C . leaves the symlink check on a bracket path through the symlink in force" "$(bash_payload "git --literal-pathspecs -C . diff --no-index -- 'sub[1]/leak/probe.txt' local.txt")" '.decision == "deny" and (.rule == "executor.containment" or .rule == "reviewer.path" or .rule == "reviewer.git")'
  for opt in "--work-tree=sub" "--git-dir=.git" "--namespace=ns" "-c core.quotepath=off" "--no-pager" "--bare"; do
    # The reviewer's exact git forms list only --no-pager among these.
    r1_extra="$H1_DYN"
    [ "$role" = exec ] || [ "$opt" = "--no-pager" ] || r1_extra='.decision == "deny" and .rule == "reviewer.git"'
    "$runner" "R1 $role: extra global option [$opt] disables the grant for a bracket pathspec" "$(bash_payload "git --literal-pathspecs $opt log -- 'a[1]'")" "$r1_extra"
  done
done
as_exec "R1 exec control: the same extra global options with a plain pathspec stay allowed" "$(bash_payload "git -c core.quotepath=off --no-pager status -- plain.txt")" "$H1_ALLOW"
as_review "R1 review control: --no-pager with a plain pathspec stays allowed" "$(bash_payload "git --no-pager log -- plain.txt")" "$H1_ALLOW"
as_exec "R1 exec: -C outside the checkout stays denied (containment of the -C value itself)" "$(bash_payload "git -C ../component-b status -- plain.txt")" '.decision == "deny" and .rule == "executor.containment"'
# R2: enumerated subcommands only, classified pathspec positions only.
BR="src/app/[id]/page.tsx"
for sub in add rm diff ls-files status restore checkout log show commit; do
  as_exec "R2 exec: git --literal-pathspecs $sub of a quoted bracket pathspec is allowed" "$(bash_payload "git --literal-pathspecs $sub -- '$BR'")" "$H1_ALLOW"
  as_exec "R2 exec: git $sub of a quoted bracket pathspec without --literal-pathspecs is refused" "$(bash_payload "git $sub -- '$BR'")" "$H1_DYN"
done
for sub in diff ls-files status log show; do
  as_review "R2 review: git --literal-pathspecs $sub of a quoted bracket pathspec is allowed" "$(bash_payload "git --literal-pathspecs $sub -- '$BR'")" "$H1_ALLOW"
  as_review "R2 review: git $sub of a quoted bracket pathspec without --literal-pathspecs is refused" "$(bash_payload "git $sub -- '$BR'")" "$H1_DYN"
done
for sub in arbitrary co mv blame ls-tree grep; do
  as_exec "R2 exec: git --literal-pathspecs $sub (not enumerated) with a bracket pathspec is refused" "$(bash_payload "git --literal-pathspecs $sub -- '$BR'")" "$H1_DYN"
  as_exec "R2 exec control: git --literal-pathspecs $sub with a plain pathspec is not refused by the grant rule" "$(bash_payload "git --literal-pathspecs $sub -- plain.txt")" "$H1_ALLOW"
done
as_exec "R2 exec: unsupported subcommand with a bare bracket operand after -- is refused" "$(bash_payload "git --literal-pathspecs arbitrary -- 'a[1]'")" "$H1_DYN"
as_review "R2 review: git --literal-pathspecs arbitrary -- bracket pathspec is denied" "$(bash_payload "git --literal-pathspecs arbitrary -- '$BR'")" '.decision == "deny"'
as_review "R2 review: git grep with a quoted regex pattern and a plain pathspec is allowed (pattern is inert)" "$(bash_payload "git grep '[a-z]+' -- plain.txt")" "$H1_ALLOW"
as_review "R2 review: git grep with a quoted regex and a bracket pathspec after -- is refused" "$(bash_payload "git grep '[a-z]+' -- 'a[1]'")" "$H1_DYN"
# classification: option/format/message/revision values are not pathspecs
as_review "R2 review: log --format='[%h]' is an attached value, outside the strict word form (0.12.11)" "$(bash_payload "git log --format='[%h]' -- plain.txt")" '.decision == "deny" and .rule == "reviewer.shell"'
as_review "R2 review: log --grep '[wip]' -- bracket pathspec with --literal-pathspecs is allowed" "$(bash_payload "git --literal-pathspecs log --grep '[wip]' -- '$BR'")" "$H1_ALLOW"
as_review "R2 review: log --grep '[wip]' -- bracket pathspec without --literal-pathspecs is refused (the pathspec, not the value)" "$(bash_payload "git log --grep '[wip]' -- '$BR'")" "$H1_DYN"
as_review "R2 review: log --grep with a separate bracket value and a plain pathspec is allowed" "$(bash_payload "git log --grep '[wip]' -- plain.txt")" "$H1_ALLOW"
as_review "R2 review: log -n 3 style separate value does not matter, revision HEAD@{1} is not a pathspec" "$(bash_payload "git log 'HEAD@{1}' -- plain.txt")" "$H1_ALLOW"
as_review "R2 review: show of a revision with brace syntax and no -- is allowed" "$(bash_payload "git show 'HEAD^{tree}'")" "$H1_ALLOW"
as_review "R2 review: a revision before -- is not a pathspec (diff 'v[1]' -- plain.txt)" "$(bash_payload "git diff 'v[1]' -- plain.txt")" "$H1_ALLOW"
as_review "R2 review: the same brace text AFTER -- is a pathspec and is refused" "$(bash_payload "git log -- 'HEAD@{1}'")" "$H1_DYN"
as_exec "R2 exec: commit -m with a bracket message and no pathspec is allowed (message is inert)" "$(bash_payload "git commit -m 'fix [id] route'")" "$H1_ALLOW"
as_exec "R2 exec: commit -m 'fix [id]' -- bracket pathspec without --literal-pathspecs is refused" "$(bash_payload "git commit -m 'fix [id]' -- '$BR'")" "$H1_DYN"
as_exec "R2 exec: commit --message=[wip] with a plain pathspec is allowed" "$(bash_payload "git commit --message='[wip]' -- plain.txt")" "$H1_ALLOW"
as_exec "R2 exec: commit -am with a bracket message and a bare bracket operand is refused" "$(bash_payload "git commit -am '[wip]' 'a[1]'")" "$H1_DYN"
# R3: a bare glob-bearing pathspec (no slash) needs --literal-pathspecs, existing or missing.
as_exec "R3 exec: git add -- 'a[1]' (existing, bare) without --literal-pathspecs is refused" "$(bash_payload "git add -- 'a[1]'")" "$H1_DYN"
as_exec "R3 exec: git add -- 'b[1]' (missing, bare) without --literal-pathspecs is refused" "$(bash_payload "git add -- 'b[1]'")" "$H1_DYN"
as_exec "R3 exec: git add 'a[1]' (no --) without --literal-pathspecs is refused" "$(bash_payload "git add 'a[1]'")" "$H1_DYN"
as_exec "R3 exec: git add -- before-and-after bare operands, one with brackets, is refused" "$(bash_payload "git add plain.txt -- 'b[1]'")" "$H1_DYN"
as_exec "R3 exec control: git --literal-pathspecs add -- 'a[1]' (existing) is allowed" "$(bash_payload "git --literal-pathspecs add -- 'a[1]'")" "$H1_ALLOW"
as_exec "R3 exec control: git --literal-pathspecs add -- 'b[1]' (missing) is allowed" "$(bash_payload "git --literal-pathspecs add -- 'b[1]'")" "$H1_ALLOW"
as_exec "R3 exec control: git --literal-pathspecs add 'a[1]' (no --) is allowed" "$(bash_payload "git --literal-pathspecs add 'a[1]'")" "$H1_ALLOW"
as_exec "R3 exec control: plain names are allowed without the option" "$(bash_payload "git add -- plain.txt plain2.txt")" "$H1_ALLOW"
as_exec "R3 exec control: plain names are allowed with the option" "$(bash_payload "git --literal-pathspecs add -- plain.txt plain2.txt")" "$H1_ALLOW"
as_exec "R3 exec: a bare bracket name that is an escaping symlink is still contained-checked under the grant" "$(bash_payload "git --literal-pathspecs add -- 'lnk[1]'")" '.decision == "deny" and .rule == "executor.containment"'
as_exec "R3 exec control: a bare bracket name that is a contained symlink is allowed under the grant" "$(bash_payload "git --literal-pathspecs add -- 'ok[1]'")" "$H1_ALLOW"
as_review "R3 review: git log -- 'a[1]' (existing, bare) without --literal-pathspecs is refused" "$(bash_payload "git log -- 'a[1]'")" "$H1_DYN"
as_review "R3 review: git log -- 'b[1]' (missing, bare) without --literal-pathspecs is refused" "$(bash_payload "git log -- 'b[1]'")" "$H1_DYN"
as_review "R3 review: git status 'a[1]' (no --) without --literal-pathspecs is refused" "$(bash_payload "git status 'a[1]'")" "$H1_DYN"
as_review "R3 review control: git --literal-pathspecs log -- 'a[1]' (existing) is allowed" "$(bash_payload "git --literal-pathspecs log -- 'a[1]'")" "$H1_ALLOW"
as_review "R3 review control: git --literal-pathspecs log -- 'b[1]' (missing) is allowed" "$(bash_payload "git --literal-pathspecs log -- 'b[1]'")" "$H1_ALLOW"
as_review "R3 review control: plain names are allowed without the option" "$(bash_payload "git log -- plain.txt plain2.txt")" "$H1_ALLOW"
as_review "R3 review: a bare bracket name that is an escaping symlink is denied under the grant" "$(bash_payload "git --literal-pathspecs log -- 'lnk[1]'")" '.decision == "deny" and .rule == "reviewer.path"'
# Deviation 4: pathspec magic is refused inside the grant even with no glob character.
as_exec "D4 exec: --literal-pathspecs add -- ':(icase)README.md' is refused" "$(bash_payload "git --literal-pathspecs add -- ':(icase)README.md'")" "$H1_DYN"
as_exec "D4 exec: --literal-pathspecs add ':/README.md' (no --) is refused" "$(bash_payload "git --literal-pathspecs add ':/README.md'")" "$H1_DYN"
as_exec "D4 exec control: --literal-pathspecs add -- README.md is allowed" "$(bash_payload "git --literal-pathspecs add -- README.md")" "$H1_ALLOW"
as_review "D4 review: --literal-pathspecs log -- ':(icase)README.md' is refused" "$(bash_payload "git --literal-pathspecs log -- ':(icase)README.md'")" "$H1_DYN"
as_review "D4 review control: --literal-pathspecs log -- README.md is allowed" "$(bash_payload "git --literal-pathspecs log -- README.md")" "$H1_ALLOW"
for conflict in --glob-pathspecs --icase-pathspecs --noglob-pathspecs; do
  as_exec "D4 exec: --literal-pathspecs $conflict with a bare bracket pathspec is refused" "$(bash_payload "git --literal-pathspecs $conflict add -- 'a[1]'")" "$H1_DYN"
done
as_exec "D4 exec: --pathspec-from-file beside a bare bracket pathspec is refused" "$(bash_payload "git --literal-pathspecs add --pathspec-from-file=list.txt -- 'a[1]'")" "$H1_DYN"
# Real-git premise for R1: the escape exists for real, and `-C .` has none.
GIT_ENV=(env -i HOME="$TMPROOT" PATH="$PATH" GIT_CONFIG_NOSYSTEM=1)
mkdir -p "$TMPROOT/rg-real/sub[1]" && printf 'local control\n' > "$TMPROOT/rg-real/local.txt" && ln -s "$RG_OUT" "$TMPROOT/rg-real/sub[1]/leak"
GOT="$(cd "$TMPROOT/rg-real" && "${GIT_ENV[@]}" git --literal-pathspecs -C './sub[1]' diff --no-index -- leak/probe.txt ../local.txt 2>/dev/null)"
if printf '%s' "$GOT" | grep -q 'outside secret'; then pass "R1 real git: -C './sub[1]' diff --no-index really reads through the symlink (premise)"; else fail "R1 real git: -C './sub[1]' diff --no-index really reads through the symlink (premise)" "$GOT"; fi
GOT="$(cd "$TMPROOT/rg-real" && "${GIT_ENV[@]}" git --literal-pathspecs -C . diff --no-index -- local.txt local.txt 2>&1; echo "rc=$?")"
if [ "$GOT" = "rc=0" ]; then pass "R1 real git control: -C . diff --no-index of a contained file reads nothing outside"; else fail "R1 real git control: -C . diff --no-index of a contained file reads nothing outside" "$GOT"; fi

# helper operands never get the easing (control: an existing prompt file is allowed)
printf 'prompt\n' > "$TMPROOT/prompt-ok.md"
mkdir -p "$TMPROOT/br[1]" && printf 'prompt\n' > "$TMPROOT/br[1]/prompt.md"
as_exec "H1 control: executor dispatch of an existing prompt file is allowed" "$(bash_payload "bash $DISPATCH $MASTER_PANE $TMPROOT/prompt-ok.md")" "$H1_ALLOW"
as_exec "H1 executor dispatch prompt operand with brackets is not eased" "$(bash_payload "bash $DISPATCH $MASTER_PANE '$TMPROOT/br[1]/prompt.md'")" "$H1_DYN"
as_review "H1 reviewer dispatch prompt operand with brackets is not eased" "$(bash_payload "bash $DISPATCH $MASTER_PANE '$TMPROOT/br[1]/prompt.md'")" "$H1_DYN"
as_review "H1 reviewer pr-status snapshot operand with brackets is not eased" "$(bash_payload "bash $CLAUDE_CACHE/session-workspace/3.0.0/scripts/pr-status.sh --snapshot '$TMPROOT/br[1]/prompt.md'")" '.decision == "deny"'

# Real-git evidence for the premise: without --literal-pathspecs the quoted
# pathspec globs and stages the sibling directories i and d too; with it, only
# the directory literally named [id]. The decisions above are policy-level only;
# this block runs plain git in a throwaway repository and does not exercise the hook.
echo "== Tier 1.4 H1: literal pathspec staging (real git) =="
make_pathspec_repo() {
  local dir="$1"
  rm -rf "$dir" && mkdir -p "$dir/src/app/[id]" "$dir/src/app/i" "$dir/src/app/d"
  printf 'x\n' > "$dir/src/app/[id]/page.tsx"; printf 'x\n' > "$dir/src/app/i/page.tsx"; printf 'x\n' > "$dir/src/app/d/page.tsx"
  env -i HOME="$TMPROOT" PATH="$PATH" GIT_CONFIG_NOSYSTEM=1 git -C "$dir" init -q
}
staged_after() { # staged_after DIR GIT-ARGS...
  local dir="$1"; shift
  env -i HOME="$TMPROOT" PATH="$PATH" GIT_CONFIG_NOSYSTEM=1 git -C "$dir" "$@" >/dev/null 2>&1
  env -i HOME="$TMPROOT" PATH="$PATH" GIT_CONFIG_NOSYSTEM=1 git -C "$dir" diff --cached --name-only 2>/dev/null | sort | tr '\n' ' '
}
make_pathspec_repo "$TMPROOT/pathspec-literal"
GOT="$(staged_after "$TMPROOT/pathspec-literal" --literal-pathspecs add -- 'src/app/[id]/page.tsx')"
if [ "$GOT" = "src/app/[id]/page.tsx " ]; then pass "H1 real git: --literal-pathspecs stages only the directory named [id]"; else fail "H1 real git: --literal-pathspecs stages only the directory named [id]" "staged: $GOT"; fi
make_pathspec_repo "$TMPROOT/pathspec-glob"
GOT="$(staged_after "$TMPROOT/pathspec-glob" add -- 'src/app/[id]/page.tsx')"
if [ "$GOT" = "src/app/[id]/page.tsx src/app/d/page.tsx src/app/i/page.tsx " ]; then pass "H1 real git control: without --literal-pathspecs the quoted pathspec also stages i and d"; else fail "H1 real git control: without --literal-pathspecs the quoted pathspec also stages i and d" "staged: $GOT"; fi

# --- Tier 1.4 H4: inert note and message text may mention a cache path ---------
echo "== Tier 1.4 H4: inert free text vs cache-path substring =="
H4_ARGV='.decision == "deny" and .rule == "helper.argv"'
CP='/x/plugins/cache/foo/scripts/h.sh'
as_review "H4 control: reviewer task-block with a plain reason is allowed" "$(bash_payload "bash $SCHED/task-block.sh t-1234 'blocked by hook'")" "$H1_ALLOW"
as_review "H4 reviewer task-block reason naming a cache path is allowed" "$(bash_payload "bash $SCHED/task-block.sh t-1234 'blocked by hook at $CP'")" "$H1_ALLOW"
as_review "H4 reviewer task-done note naming a cache path is allowed" "$(bash_payload "bash $SCHED/task-done.sh t-1234 'approved; see /x/plugins/cache/y'")" "$H1_ALLOW"
as_exec "H4 executor task-review note naming a cache path is allowed" "$(bash_payload "bash $SCHED/task-review.sh t-1234 'ready; hook $CP'")" "$H1_ALLOW"
as_review "H4 contracted --generation note naming /plugins/cache/ is allowed" "$(bash_payload "bash $SCHED/task-done.sh ct-good --generation 2 'note mentions /plugins/cache/'")" "$H1_ALLOW"
as_review "H4 control: contracted --generation without a cache path is allowed" "$(bash_payload "bash $SCHED/task-done.sh ct-good --generation 2 'note mentions nothing'")" "$H1_ALLOW"
as_review "H4 a single quoted note that merely starts with --force text is inert and allowed" "$(bash_payload "bash $SCHED/task-done.sh t-1234 '--force /x/plugins/cache/z'")" "$H1_ALLOW"
as_review "H4 unquoted --force before a cache-path note is still denied" "$(bash_payload "bash $SCHED/task-done.sh t-1234 --force /x/plugins/cache/z")" "$H4_ARGV"
as_review "H4 unquoted multi-word note (more than one note operand) is still denied by the grammar" "$(bash_payload "bash $SCHED/task-block.sh t-1234 blocked by hook at $CP")" "$H4_ARGV"
as_review "H4 flag-like first note word after --generation is still denied" "$(bash_payload "bash $SCHED/task-done.sh ct-good --generation 2 '--evil $CP'")" "$H4_ARGV"
as_review "H4 task id naming a cache path is denied" "$(bash_payload "bash $SCHED/task-block.sh /x/plugins/cache/z 'reason'")" "$H4_ARGV"
as_review "H4 cache path in --generation value is denied" "$(bash_payload "bash $SCHED/task-done.sh ct-good --generation /x/plugins/cache/z 'note'")" "$H4_ARGV"
as_review "H4 --note-file naming a cache path is denied" "$(bash_payload "bash $SCHED/task-done.sh t-1234 --note-file /x/plugins/cache/y/verdict.md")" "$H4_ARGV"
as_review "H4 control: --note-file own draft is still allowed" "$(bash_payload "bash $SCHED/task-done.sh t-1234 --note-file $NF_DIR/verdict.md")" "$H1_ALLOW"
as_review "H4 note with a newline naming a cache path is denied" "$(bash_payload "bash $SCHED/task-block.sh t-1234 'line one
$CP'")" "$H4_ARGV"
as_review "H4 note with a newline and no cache path is denied (newline rule is independent)" "$(bash_payload "bash $SCHED/task-block.sh t-1234 'line one
line two'")" "$H4_ARGV"
as_review "H4 reviewer send-message body naming a cache path is allowed" "$(bash_payload "bash $SEND $MASTER_PANE 'see /x/plugins/cache/y'")" "$H1_ALLOW"
as_review "H4 control: reviewer send-message plain body is allowed" "$(bash_payload "bash $SEND $MASTER_PANE 'see the notes'")" "$H1_ALLOW"
as_review "H4 send-message multi-word body naming a cache path is allowed" "$(bash_payload "bash $SEND $MASTER_PANE see /x/plugins/cache/y here")" "$H1_ALLOW"
as_review "H4 send-message body with --reply-to present is allowed" "$(bash_payload "bash $SEND --reply-to cafe1234 $MASTER_PANE 'see /x/plugins/cache/y'")" "$H1_ALLOW"
as_review "H4 send-message body with --task present is allowed" "$(bash_payload "bash $SEND --task t-1234 $MASTER_PANE 'see /x/plugins/cache/y'")" "$H1_ALLOW"
as_exec "H4 send-message body with all options present is allowed" "$(bash_payload "bash $SEND --priority high --ttl 5 --reply-to cafe1234 --task t-1234 $MASTER_PANE 'see /x/plugins/cache/y'")" "$H1_ALLOW"
as_review "H4 send-message flag-like body words after the target are message text and allowed" "$(bash_payload "bash $SEND $MASTER_PANE --force /x/plugins/cache/z")" "$H1_ALLOW"
as_review "H4 send-message cache path in --reply-to value is denied" "$(bash_payload "bash $SEND --reply-to /x/plugins/cache/y $MASTER_PANE hi")" "$H4_ARGV"
as_review "H4 send-message cache path in --task value is denied" "$(bash_payload "bash $SEND --task /x/plugins/cache/y $MASTER_PANE hi")" "$H4_ARGV"
as_review "H4 send-message cache path as the target is denied" "$(bash_payload "bash $SEND /x/plugins/cache/y hi")" "$H4_ARGV"
as_review "H4 send-message option-looking value after the body is not an option and stays message text" "$(bash_payload "bash $SEND $MASTER_PANE hi --reply-to /x/plugins/cache/y")" "$H1_ALLOW"
mkdir -p "$TMPROOT/stage/plugins/cache"
printf 'prompt\n' > "$TMPROOT/stage/plugins/cache/evil.md"; printf 'prompt\n' > "$TMPROOT/stage/ok.md"
as_review "H4 control: dispatch of an existing prompt file outside any cache path is allowed" "$(bash_payload "bash $DISPATCH $MASTER_PANE $TMPROOT/stage/ok.md")" "$H1_ALLOW"
as_review "H4 dispatch prompt-file operand under a cache path is denied although the file exists" "$(bash_payload "bash $DISPATCH $MASTER_PANE $TMPROOT/stage/plugins/cache/evil.md")" "$H4_ARGV"
as_exec "H4 dispatch of a nonexistent cache-path prompt is denied" "$(bash_payload "bash $DISPATCH $MASTER_PANE /x/plugins/cache/y/evil.md")" "$H4_ARGV"
as_review "H4 control: message-search plain pattern is allowed" "$(bash_payload "bash $CLAUDE_CACHE/session-chat/1.2.3/scripts/message-search.sh needle")" "$H1_ALLOW"
as_review "H4 helper without an inert slot (message-search) is denied for a cache-path pattern" "$(bash_payload "bash $CLAUDE_CACHE/session-chat/1.2.3/scripts/message-search.sh /x/plugins/cache/y")" "$H4_ARGV"
as_master "H4 control: list-sessions all is allowed" "$(bash_payload "bash $SM/list-sessions.sh all")" "$H1_ALLOW"
as_master "H4 helper without an inert slot (list-sessions) is denied for an installed-script operand" "$(bash_payload "bash $SM/list-sessions.sh $SEND")" "$H4_ARGV"
as_master "H4 orchestrator task-new name naming a cache path is denied (no inert slot)" "$(bash_payload "bash $SCHED/task-new.sh 'name /x/plugins/cache/y'")" "$H4_ARGV"
as_master "H4 control: orchestrator task-new plain name is allowed" "$(bash_payload "bash $SCHED/task-new.sh 'plain name'")" "$H1_ALLOW"

# Native hook shapes for both easings: the real wrapper (exit code + stderr)
# and a Codex-shaped payload through the decision path.
echo "== Tier 1.4: native hook shapes =="
h1_hook_run() { # h1_hook_run ROLE PANE OUTFILE ERRFILE PAYLOAD
  printf '%s' "$5" | env \
    SESSION_WORKSPACE_CONFIG="$CONFIG" SESSION_WORKSPACE_PROJECT_ROOT="$ROOT" \
    SESSION_WORKSPACE_PANE_NAME="$2" SESSION_WORKSPACE_ROLE="$1" \
    SESSION_WORKSPACE_PANE_CWD="$CHILD" SESSION_WORKSPACE_HARNESS_MODE=enforce \
    CLAUDE_HOME="$FAKE_CLAUDE" CODEX_HOME="$FAKE_CODEX" bash "$HERE/harness-hook.sh" >"$3" 2>"$4"
}
h1_hook_run executor "$EXEC_PANE" "$TMPROOT/h1.out" "$TMPROOT/h1.err" "$(bash_payload "git --literal-pathspecs add -- 'src/app/[id]/page.tsx'")"
if [ $? -eq 0 ] && [ ! -s "$TMPROOT/h1.err" ]; then pass "H1 hook wrapper: executor git --literal-pathspecs quoted bracket add exits 0 silently"; else fail "H1 hook wrapper: executor git --literal-pathspecs quoted bracket add exits 0 silently" "$(cat "$TMPROOT/h1.err")"; fi
h1_hook_run executor "$EXEC_PANE" "$TMPROOT/h2.out" "$TMPROOT/h2.err" "$(bash_payload "git add -- 'src/app/[id]/page.tsx'")"
H2=$?
if [ "$H2" -eq 2 ] && grep -q '^BLOCKED by session-workspace strict-v1 \[path.dynamic\]' "$TMPROOT/h2.err"; then pass "H1 hook wrapper: executor git add of a bracket pathspec without --literal-pathspecs is blocked"; else fail "H1 hook wrapper: executor git add of a bracket pathspec without --literal-pathspecs is blocked" "status=$H2 $(cat "$TMPROOT/h2.err")"; fi
h1_hook_run reviewer "$REVIEW_PANE" "$TMPROOT/h3.out" "$TMPROOT/h3.err" "$(bash_payload "cat 'src/app/(x)/[id]/page.tsx'")"
if [ $? -eq 0 ] && [ ! -s "$TMPROOT/h3.err" ]; then pass "H1 hook wrapper: reviewer quoted route path read exits 0 silently"; else fail "H1 hook wrapper: reviewer quoted route path read exits 0 silently" "$(cat "$TMPROOT/h3.err")"; fi
h1_hook_run reviewer "$REVIEW_PANE" "$TMPROOT/h4.out" "$TMPROOT/h4.err" "$(bash_payload 'cat src/app/[id]/page.tsx')"
H4S=$?
if [ "$H4S" -eq 2 ] && grep -q '^BLOCKED by session-workspace strict-v1 \[reviewer.shell\]' "$TMPROOT/h4.err"; then pass "H1 hook wrapper: reviewer unquoted bracket glob is blocked"; else fail "H1 hook wrapper: reviewer unquoted bracket glob is blocked" "status=$H4S $(cat "$TMPROOT/h4.err")"; fi
h1_hook_run reviewer "$REVIEW_PANE" "$TMPROOT/h5.out" "$TMPROOT/h5.err" "$(bash_payload "bash $SCHED/task-block.sh t-1234 'blocked by hook at $CP'")"
if [ $? -eq 0 ] && [ ! -s "$TMPROOT/h5.err" ]; then pass "H4 hook wrapper: reviewer task-block note naming a cache path exits 0 silently"; else fail "H4 hook wrapper: reviewer task-block note naming a cache path exits 0 silently" "$(cat "$TMPROOT/h5.err")"; fi
h1_hook_run reviewer "$REVIEW_PANE" "$TMPROOT/h6.out" "$TMPROOT/h6.err" "$(bash_payload "bash $DISPATCH $MASTER_PANE $TMPROOT/stage/plugins/cache/evil.md")"
H6=$?
if [ "$H6" -eq 2 ] && grep -q '^BLOCKED by session-workspace strict-v1 \[helper.argv\]' "$TMPROOT/h6.err"; then pass "H4 hook wrapper: dispatch prompt operand under a cache path is blocked"; else fail "H4 hook wrapper: dispatch prompt operand under a cache path is blocked" "status=$H6 $(cat "$TMPROOT/h6.err")"; fi
expect "H1 Codex-shaped payload: executor quoted bracket path under --literal-pathspecs is allowed" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(codex_bash_payload "git --literal-pathspecs add -- 'src/app/[id]/page.tsx'")" "$H1_ALLOW"
expect "H1 Codex-shaped payload: executor bracket pathspec without the option is denied" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(codex_bash_payload "git add -- 'src/app/[id]/page.tsx'")" "$H1_DYN"
expect "H1 Codex argv-list payload: reviewer quoted bracket path is allowed" reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce '{"tool_name":"shell","tool_input":{"command":["cat","src/app/[id]/page.tsx"]}}' "$H1_ALLOW"

echo "== knowledge docs validators: [docs-directory] [days-threshold] inside the pane cwd =="
# validate-links.sh / check-todos.sh [docs-directory] and check-freshness.sh
# [docs-directory] [days-threshold]. The directory must resolve inside the
# pane's own cwd: the workspace root for the orchestrator, the checkout for
# executors and reviewers.
mkdir -p "$ROOT/docs/decisions" "$CHILD/docs/guides" "$TMPROOT/outside-docs"
printf '# decision\n' > "$ROOT/docs/decisions/0001-example.md"
printf '# guide\n' > "$CHILD/docs/guides/setup.md"
printf '# outside\n' > "$TMPROOT/outside-docs/secret.md"
ln -s "$TMPROOT/outside-docs" "$ROOT/docs/outside-link"
ln -s "$TMPROOT/outside-docs" "$CHILD/docs/outside-link"
ln -s "$CHILD/docs/guides" "$CHILD/docs/guides-link"
DOCS_ALLOW='.decision == "allow"'
DOCS_ARGV='.decision == "deny" and .rule == "helper.argv"'
DOCS_SEGMENT='.decision == "deny" and .rule == "helper.segment"'
for h in validate-links.sh check-todos.sh check-freshness.sh; do
  as_master "orchestrator $h with no argument is allowed" "$(bash_payload "bash $KNOW/$h")" "$DOCS_ALLOW"
  as_master "orchestrator $h on an absolute docs subdirectory is allowed" "$(bash_payload "bash $KNOW/$h $ROOT/docs/decisions")" "$DOCS_ALLOW"
  as_master "orchestrator $h on a relative docs directory with a trailing slash is allowed" "$(bash_payload "bash $KNOW/$h docs/")" "$DOCS_ALLOW"
  as_master "orchestrator $h on a child checkout's docs (inside the workspace root) is allowed" "$(bash_payload "bash $KNOW/$h $CHILD/docs")" "$DOCS_ALLOW"
  as_master "orchestrator $h on a directory outside the workspace root is denied" "$(bash_payload "bash $KNOW/$h $TMPROOT/outside-docs")" "$DOCS_ARGV"
  as_master "orchestrator $h with ../ traversal out of the workspace is denied" "$(bash_payload "bash $KNOW/$h ../outside-docs")" "$DOCS_ARGV"
  as_master "orchestrator $h with a .. component that stays inside is denied" "$(bash_payload "bash $KNOW/$h $ROOT/docs/../docs")" "$DOCS_ARGV"
  as_master "orchestrator $h on a symlink pointing outside the workspace is denied" "$(bash_payload "bash $KNOW/$h $ROOT/docs/outside-link")" "$DOCS_ARGV"
  as_master "orchestrator $h on a file instead of a directory is denied" "$(bash_payload "bash $KNOW/$h $ROOT/AGENTS.md")" "$DOCS_ARGV"
  as_master "orchestrator $h on a missing directory is denied" "$(bash_payload "bash $KNOW/$h $ROOT/docs/missing")" "$DOCS_ARGV"
  as_master "orchestrator $h with two directories is denied" "$(bash_payload "bash $KNOW/$h docs docs/decisions")" "$DOCS_ARGV"
  as_master "orchestrator $h with a find-expression value (-delete) is denied" "$(bash_payload "bash $KNOW/$h -delete")" "$DOCS_ARGV"
  as_master "orchestrator $h with an option-looking value (--help) is denied" "$(bash_payload "bash $KNOW/$h --help")" "$DOCS_ARGV"
  as_master "orchestrator $h with an empty directory value is denied" "$(bash_payload "bash $KNOW/$h ''")" "$DOCS_ARGV"
  as_master "orchestrator $h with a quoted ~ path is denied" "$(bash_payload "bash $KNOW/$h '~/docs'")" "$DOCS_ARGV"
  as_master "orchestrator $h with a quoted glob is denied" "$(bash_payload "bash $KNOW/$h 'docs/*'")" "$DOCS_ARGV"
  as_master "orchestrator $h with an unquoted glob is denied" "$(bash_payload "bash $KNOW/$h docs/*")" "$DOCS_ARGV"
  as_master "orchestrator $h with a variable directory is denied" "$(bash_payload "bash $KNOW/$h \"\$HOME/docs\"")" "$DOCS_SEGMENT"
  as_master "orchestrator $h composed with && is denied" "$(bash_payload "bash $KNOW/$h docs && rm -rf docs")" "$DOCS_SEGMENT"
  as_master "orchestrator $h composed with a pipe is denied" "$(bash_payload "bash $KNOW/$h docs | tee docs/out.md")" "$DOCS_SEGMENT"
  as_master "orchestrator $h with a command substitution is denied" "$(bash_payload "bash $KNOW/$h \$(pwd)/docs")" "$DOCS_SEGMENT"
  for role in exec review; do
    case "$role" in exec) run=as_exec; who=executor ;; review) run=as_review; who=reviewer ;; esac
    "$run" "$who $h with no argument is allowed" "$(bash_payload "bash $KNOW/$h")" "$DOCS_ALLOW"
    "$run" "$who $h on its own checkout's absolute docs directory is allowed" "$(bash_payload "bash $KNOW/$h $CHILD/docs")" "$DOCS_ALLOW"
    "$run" "$who $h on a relative docs subdirectory is allowed" "$(bash_payload "bash $KNOW/$h docs/guides")" "$DOCS_ALLOW"
    "$run" "$who $h on a symlink that stays inside its checkout is allowed" "$(bash_payload "bash $KNOW/$h docs/guides-link")" "$DOCS_ALLOW"
    "$run" "$who $h on the workspace root's docs (outside its checkout) is denied" "$(bash_payload "bash $KNOW/$h $ROOT/docs")" "$DOCS_ARGV"
    "$run" "$who $h on a directory outside the workspace is denied" "$(bash_payload "bash $KNOW/$h $TMPROOT/outside-docs")" "$DOCS_ARGV"
    "$run" "$who $h with ../ traversal to a sibling checkout is denied" "$(bash_payload "bash $KNOW/$h ../component-b")" "$DOCS_ARGV"
    "$run" "$who $h on a symlink to a sibling checkout is denied" "$(bash_payload "bash $KNOW/$h escape-link")" "$DOCS_ARGV"
    "$run" "$who $h on a symlink pointing outside the workspace is denied" "$(bash_payload "bash $KNOW/$h docs/outside-link")" "$DOCS_ARGV"
    "$run" "$who $h on a file instead of a directory is denied" "$(bash_payload "bash $KNOW/$h README.md")" "$DOCS_ARGV"
    "$run" "$who $h with two directories is denied" "$(bash_payload "bash $KNOW/$h docs docs/guides")" "$DOCS_ARGV"
    "$run" "$who $h with a find-expression value (-delete) is denied" "$(bash_payload "bash $KNOW/$h -delete")" "$DOCS_ARGV"
    "$run" "$who $h composed with ; is denied" "$(bash_payload "bash $KNOW/$h docs; cat /etc/hosts")" "$DOCS_SEGMENT"
  done
done
for h in validate-links.sh check-todos.sh; do
  as_master "orchestrator $h with a trailing threshold is denied (no threshold slot)" "$(bash_payload "bash $KNOW/$h docs 30")" "$DOCS_ARGV"
  as_exec "executor $h with a trailing threshold is denied (no threshold slot)" "$(bash_payload "bash $KNOW/$h docs 30")" "$DOCS_ARGV"
done
FRESH="$KNOW/check-freshness.sh"
as_master "orchestrator check-freshness with a docs directory and threshold is allowed" "$(bash_payload "bash $FRESH $ROOT/docs/decisions 30")" "$DOCS_ALLOW"
as_master "orchestrator check-freshness with the lowest threshold (1) is allowed" "$(bash_payload "bash $FRESH docs 1")" "$DOCS_ALLOW"
as_master "orchestrator check-freshness with the highest threshold (3650) is allowed" "$(bash_payload "bash $FRESH docs 3650")" "$DOCS_ALLOW"
as_exec "executor check-freshness with a docs directory and threshold is allowed" "$(bash_payload "bash $FRESH docs 90")" "$DOCS_ALLOW"
as_review "reviewer check-freshness with a docs directory and threshold is allowed" "$(bash_payload "bash $FRESH $CHILD/docs 30")" "$DOCS_ALLOW"
as_master "orchestrator check-freshness with threshold 0 is denied" "$(bash_payload "bash $FRESH docs 0")" "$DOCS_ARGV"
as_master "orchestrator check-freshness with threshold 3651 is denied" "$(bash_payload "bash $FRESH docs 3651")" "$DOCS_ARGV"
as_exec "executor check-freshness with a five-digit threshold is denied" "$(bash_payload "bash $FRESH docs 99999")" "$DOCS_ARGV"
as_review "reviewer check-freshness with a non-numeric threshold is denied" "$(bash_payload "bash $FRESH docs abc")" "$DOCS_ARGV"
as_master "orchestrator check-freshness with a zero-padded threshold is denied" "$(bash_payload "bash $FRESH docs 030")" "$DOCS_ARGV"
as_master "orchestrator check-freshness with a negative threshold is denied" "$(bash_payload "bash $FRESH docs -5")" "$DOCS_ARGV"
as_exec "executor check-freshness with a date-expression threshold is denied" "$(bash_payload "bash $FRESH docs '30 days'")" "$DOCS_ARGV"
as_master "orchestrator check-freshness with an empty threshold is denied" "$(bash_payload "bash $FRESH docs ''")" "$DOCS_ARGV"
as_master "orchestrator check-freshness with an extra argument after the threshold is denied" "$(bash_payload "bash $FRESH docs 30 extra")" "$DOCS_ARGV"
as_master "orchestrator check-freshness with a threshold but no directory is denied" "$(bash_payload "bash $FRESH 30")" "$DOCS_ARGV"
as_review "reviewer check-freshness with an outside directory and a valid threshold is denied" "$(bash_payload "bash $FRESH $TMPROOT/outside-docs 30")" "$DOCS_ARGV"
expect "Codex-shaped payload: executor validate-links on its docs directory is allowed" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(codex_bash_payload "bash $KNOW/validate-links.sh $CHILD/docs")" "$DOCS_ALLOW"
expect "Codex argv-list payload: executor check-todos on a relative docs directory is allowed" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(jq -cn --arg h "$KNOW/check-todos.sh" '{tool_name:"shell",tool_input:{command:["bash",$h,"docs"]}}')" "$DOCS_ALLOW"
expect "Codex argv-list payload: executor check-todos on a symlink escape is denied" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(jq -cn --arg h "$KNOW/check-todos.sh" '{tool_name:"shell",tool_input:{command:["bash",$h,"docs/outside-link"]}}')" "$DOCS_ARGV"

echo "== hook wrapper (harness-hook.sh) =="
WRAP="$HERE/harness-hook.sh"
printf '%s' "$(bash_payload 'rm -rf /')" | env -u SESSION_WORKSPACE_CONFIG -u SESSION_WORKSPACE_HARNESS_MODE bash "$WRAP" >"$TMPROOT/w1.out" 2>"$TMPROOT/w1.err"
if [ $? -eq 0 ] && [ ! -s "$TMPROOT/w1.out" ] && [ ! -s "$TMPROOT/w1.err" ]; then
  pass "wrapper: no SESSION_WORKSPACE_CONFIG is a silent exit 0"
else
  fail "wrapper: no SESSION_WORKSPACE_CONFIG is a silent exit 0" "$(cat "$TMPROOT/w1.err")"
fi
printf '%s' "$(bash_payload 'rm -rf /')" | env -u SESSION_WORKSPACE_HARNESS_MODE SESSION_WORKSPACE_CONFIG="$V1_CONFIG" bash "$WRAP" >"$TMPROOT/w2.out" 2>"$TMPROOT/w2.err"
if [ $? -eq 0 ] && [ ! -s "$TMPROOT/w2.out" ] && [ ! -s "$TMPROOT/w2.err" ]; then
  pass "wrapper: schema v1 config is a silent exit 0"
else
  fail "wrapper: schema v1 config is a silent exit 0" "$(cat "$TMPROOT/w2.err")"
fi
printf '%s' "$(bash_payload 'rm -rf /')" | env -u SESSION_WORKSPACE_HARNESS_MODE SESSION_WORKSPACE_CONFIG="$OFF_CONFIG" bash "$WRAP" >"$TMPROOT/w3.out" 2>"$TMPROOT/w3.err"
if [ $? -eq 0 ] && [ ! -s "$TMPROOT/w3.err" ]; then
  pass "wrapper: schema v2 enabled=false is a silent exit 0"
else
  fail "wrapper: schema v2 enabled=false is a silent exit 0" "$(cat "$TMPROOT/w3.err")"
fi
NOPY="$TMPROOT/nopy-bin"
mkdir -p "$NOPY"
for tool in bash jq env cat printf grep dirname; do
  ln -s "$(command -v "$tool")" "$NOPY/$tool"
done
printf '%s' "$(edit_payload 'src/file.ts')" | env PATH="$NOPY" SESSION_WORKSPACE_CONFIG="$CONFIG" SESSION_WORKSPACE_HARNESS_MODE=enforce bash "$WRAP" >"$TMPROOT/w4.out" 2>"$TMPROOT/w4.err"
W4=$?
if [ "$W4" -eq 2 ] && grep -q 'requires python3' "$TMPROOT/w4.err"; then
  pass "wrapper: active harness without python3 fails closed (exit 2)"
else
  fail "wrapper: active harness without python3 fails closed (exit 2)" "status=$W4 $(cat "$TMPROOT/w4.err")"
fi
printf '%s' "$(edit_payload 'src/file.ts')" | env -u SESSION_WORKSPACE_HARNESS_MODE PATH="$NOPY" SESSION_WORKSPACE_CONFIG="$V1_CONFIG" bash "$WRAP" >"$TMPROOT/w5.out" 2>"$TMPROOT/w5.err"
if [ $? -eq 0 ] && [ ! -s "$TMPROOT/w5.err" ]; then
  pass "wrapper: inactive config without python3 stays a no-op"
else
  fail "wrapper: inactive config without python3 stays a no-op" "$(cat "$TMPROOT/w5.err")"
fi
printf '%s' "$(edit_payload 'src/file.ts')" | env \
  SESSION_WORKSPACE_CONFIG="$CONFIG" SESSION_WORKSPACE_PROJECT_ROOT="$ROOT" \
  SESSION_WORKSPACE_PANE_NAME="$REVIEW_PANE" SESSION_WORKSPACE_ROLE=reviewer \
  SESSION_WORKSPACE_PANE_CWD="$CHILD" SESSION_WORKSPACE_HARNESS_MODE=enforce \
  CLAUDE_HOME="$FAKE_CLAUDE" CODEX_HOME="$FAKE_CODEX" bash "$WRAP" >"$TMPROOT/w6.out" 2>"$TMPROOT/w6.err"
W6=$?
if [ "$W6" -eq 2 ] && grep -q '^BLOCKED' "$TMPROOT/w6.err"; then
  pass "wrapper: active harness delegates to the policy (reviewer edit blocked)"
else
  fail "wrapper: active harness delegates to the policy (reviewer edit blocked)" "status=$W6 $(cat "$TMPROOT/w6.err")"
fi

printf '\n-----------------------------------------------\n'
printf 'harness-policy tests (%s): %d passed, %d failed\n' "$PY" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailures:\n'
  for item in "${FAILURES[@]}"; do printf '  - %s\n' "$item"; done
  exit 1
fi
exit 0
