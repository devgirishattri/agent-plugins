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
POLICY="$HERE/harness-policy.py"
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
SCHED_HELPERS="task-status.sh task-board.sh task-review.sh task-done.sh task-block.sh task-new.sh task-assign.sh tasks-clean.sh scheduler-doctor.sh"
KNOW_HELPERS="save-context.sh load-context.sh list-contexts.sh share-context.sh search-contexts.sh memory-search.sh memory-remember.sh docs-write.sh doctor.sh memory-lint.sh memory-backlinks.sh memory-write.sh memory-index.sh init.sh remove-context.sh memory-auto-capture.sh"
WS_HELPERS="workspace.sh workspace-status.sh harness-status.sh workspace-start.sh workspace-stop.sh workspace-restart.sh workspace-reconcile.sh workspace-install.sh workspace-browser-config.sh"
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

bash_payload() { jq -cn --arg command "$1" '{tool_name:"Bash",tool_input:{command:$command}}'; }
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

echo "== decision object shape =="
OUT="$(run_policy reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(edit_payload src/file.ts)")"
if printf '%s' "$OUT" | jq -e 'keys == ["active","decision","mode","pane","profile","reason","role","rule","tool"]' >/dev/null 2>&1; then
  pass "decision JSON has exactly the fixed sorted key set"
else
  fail "decision JSON has exactly the fixed sorted key set" "$OUT"
fi
EXPECT_JSON="$(jq -cn --arg pane "$REVIEW_PANE" '{active:true,decision:"deny",mode:"enforce",pane:$pane,profile:"strict-v1",reason:"reviewer panes cannot edit, write, patch, move, or delete files",role:"reviewer",rule:"reviewer.readonly",tool:"Edit"}')"
if [ "$OUT" = "$EXPECT_JSON" ]; then
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

echo "== inactive contract (true no-op) =="
OUT="$(printf '%s' "$(bash_payload 'rm -rf /')" | env -u SESSION_WORKSPACE_CONFIG -u SESSION_WORKSPACE_HARNESS_MODE "$PY" "$POLICY" --decision-json)"
if [ "$OUT" = '{"active":false,"decision":"allow","mode":"","pane":"","profile":"","reason":"harness is not active","role":"","rule":"inactive","tool":""}' ]; then
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
as_exec "executor shell operand outside its cwd is denied (dispatch files are read via the Read tool)" "$(bash_payload "cat $FAKE_CLAUDE/messages/task.md")" '.decision == "deny" and .rule == "executor.containment"'
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
as_review "reviewer git -C .. status is denied" "$(bash_payload 'git -C .. status')" '.decision == "deny" and .rule == "reviewer.path"'
as_review "reviewer cat absolute path containing spaces outside its roots is denied" "$(bash_payload "cat \"$TMPROOT/some dir/file.ts\"")" '.decision == "deny" and .rule == "reviewer.path"'
as_review "reviewer cat path containing spaces inside its checkout is allowed" "$(bash_payload "cat \"$CHILD/sub dir/file.ts\"")" '.decision == "allow"'
as_review "reviewer cd is not a read-only command" "$(bash_payload 'cd .. && ls')" '.decision == "deny" and .rule == "reviewer.shell"'
as_review "reviewer reading a GRANTED coordination store is allowed" "$(bash_payload "cat $ROOT/.tmp/messages/note.md")" '.decision == "allow"'
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
as_review "reviewer cat of a bare escaping symlink WITH whitespace is denied" "$(bash_payload 'cat "escape link"')" '.decision == "deny" and .rule == "reviewer.path"'
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
as_review "reviewer unquoted glob is denied" "$(bash_payload 'cat escape-*')" '.decision == "deny" and .rule == "path.dynamic"'
as_review "reviewer git -C.. (attached) is denied" "$(bash_payload 'git -C.. status')" '.decision == "deny" and (.rule == "reviewer.path" or .rule == "reviewer.git")'
as_review "reviewer quoted glob pattern in grep is allowed" "$(bash_payload "grep -rn 'x*y' src")" '.decision == "allow"'
as_master "orchestrator redirect write into a child is denied" "$(bash_payload 'echo x > component-a/generated.ts')" '.decision == "deny" and .rule == "orchestrator.child_write"'
as_master "orchestrator redirect write at its root is allowed" "$(bash_payload 'echo x > notes.txt')" '.decision == "allow"'
as_master "orchestrator input redirect from a child is a read and allowed" "$(bash_payload 'wc -l < component-a/README.md')" '.decision == "allow"'

echo "== trusted helpers: exact selected provenance (Claude cache) =="
as_exec "executor selected helper send to orchestrator is allowed" "$(bash_payload "bash $SEND $MASTER_PANE 'done: abc123'")" '.decision == "allow"'
as_exec "executor helper send to a sibling reviewer is denied (child routing is master-only)" "$(bash_payload "bash $SEND $REVIEW_PANE hi")" '.decision == "deny" and .rule == "routing.master"'
as_exec "executor helper send with reply correlation is allowed" "$(bash_payload "bash $SEND --reply-to deadbeef $MASTER_PANE 'ack'")" '.decision == "allow"'
as_exec "executor helper with unknown option is denied" "$(bash_payload "bash $SEND --loud $MASTER_PANE hi")" '.decision == "deny" and .rule == "helper.argv"'
as_exec "executor helper with malformed reply id is denied" "$(bash_payload "bash $SEND --reply-to xyz $MASTER_PANE hi")" '.decision == "deny" and .rule == "helper.argv"'
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
as_exec "helper naming another installed script as an argument is denied" "$(bash_payload "bash $SEND $MASTER_PANE $STALE_SEND")" '.decision == "deny" and .rule == "helper.argv"'
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
as_review "reviewer git diff against a ref is allowed" "$(bash_payload 'git diff HEAD~1 -- src/file.ts')" '.decision == "allow"'
as_review "reviewer git -C inside its cwd is allowed" "$(bash_payload "git -C $CHILD log -n 3")" '.decision == "allow"'
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
as_review "reviewer git -C sibling checkout is denied" "$(bash_payload "git -C $ROOT/component-b log")" '.decision == "deny" and .rule == "reviewer.path"'
as_review "reviewer cat outside the workspace/trusted roots is denied" "$(bash_payload 'cat /etc/hosts')" '.decision == "deny" and .rule == "reviewer.path"'
as_review "reviewer reading a dispatch file in the provider messages dir is allowed" "$(bash_payload "cat $FAKE_CLAUDE/messages/task.md")" '.decision == "allow"'
as_review "reviewer reading a selected plugin cache file is allowed (operand, not execution)" "$(bash_payload "cat $SEND")" '.decision == "allow"'
as_review "reviewer rg inside cwd is allowed" "$(bash_payload 'rg -n TODO src')" '.decision == "allow"'
as_review "reviewer rg --pre is denied" "$(bash_payload 'rg --pre ./x TODO')" '.decision == "deny" and .rule == "reviewer.search"'
as_review "reviewer find -exec is denied" "$(bash_payload 'find . -exec sh -c true ;')" '.decision == "deny"'
as_review "reviewer find -delete is denied" "$(bash_payload 'find . -name x -delete')" '.decision == "deny" and .rule == "reviewer.find"'
as_review "reviewer tail -f is denied" "$(bash_payload 'tail -f log.txt')" '.decision == "deny" and .rule == "reviewer.tail"'
as_review "reviewer sort -o is denied" "$(bash_payload 'sort -o out in')" '.decision == "deny" and .rule == "reviewer.sort"'
as_review "reviewer sed is denied outright (even read-only forms)" "$(bash_payload 'sed -n 1p README.md')" '.decision == "deny" and .rule == "reviewer.sed"'
as_review "reviewer sed -i is denied" "$(bash_payload 'sed -i s/a/b/ file')" '.decision == "deny" and .rule == "reviewer.sed"'
as_review "reviewer awk is denied" "$(bash_payload "awk '{print}' README.md")" '.decision == "deny" and .rule == "reviewer.sed"'
as_review "reviewer touch is denied" "$(bash_payload 'touch file')" '.decision == "deny" and .rule == "reviewer.command"'
as_review "reviewer pipeline is denied" "$(bash_payload 'git log | head')" '.decision == "deny" and .rule == "reviewer.shell"'
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
as_review "reviewer task-status is allowed" "$(bash_payload "bash $SCHED/task-status.sh --mine")" '.decision == "allow"'
as_review "reviewer task-board is allowed" "$(bash_payload "bash $SCHED/task-board.sh")" '.decision == "allow"'
as_review "reviewer memory write (remember) is denied" "$(bash_payload "bash $KNOW/memory-remember.sh --staged x")" '.decision == "deny" and .rule == "coordination.write"'
as_review "reviewer docs write is denied" "$(bash_payload "bash $KNOW/docs-write.sh docs/x.md")" '.decision == "deny" and .rule == "coordination.write"'
as_review "reviewer context load is allowed" "$(bash_payload "bash $KNOW/load-context.sh review_arc")" '.decision == "allow"'
as_review "reviewer context save of an existing snapshot file is allowed" "$(bash_payload "bash $KNOW/save-context.sh review_arc $CHILD/README.md --handoff --expires 2026-12-31T00:00:00Z")" '.decision == "allow"'
as_review "reviewer context save with a bad --expires is denied" "$(bash_payload "bash $KNOW/save-context.sh review_arc $CHILD/README.md --expires tomorrow")" '.decision == "deny" and .rule == "helper.argv"'
as_review "reviewer context share to the orchestrator is allowed" "$(bash_payload "bash $KNOW/share-context.sh $MASTER_PANE review_arc")" '.decision == "allow"'
as_review "reviewer context share to the executor is denied" "$(bash_payload "bash $KNOW/share-context.sh $EXEC_PANE review_arc")" '.decision == "deny" and .rule == "routing.master"'
as_review "reviewer memory search is allowed" "$(bash_payload "bash $KNOW/memory-search.sh --limit 5 harness policy")" '.decision == "allow"'
as_review "reviewer memory search with --store override is denied" "$(bash_payload "bash $KNOW/memory-search.sh --store /tmp/x harness")" '.decision == "deny" and .rule == "helper.argv"'
as_review "reviewer workspace read verb via dispatcher is allowed" "$(bash_payload "bash $WS/workspace.sh harness-status --json")" '.decision == "allow"'
as_review "reviewer workspace start via dispatcher is denied" "$(bash_payload "bash $WS/workspace.sh start")" '.decision == "deny" and .rule == "coordination.write"'
as_review "reviewer harness-status.sh is allowed" "$(bash_payload "bash $WS/harness-status.sh --json")" '.decision == "allow"'
as_review "reviewer harness-status.sh --config pointing elsewhere is denied" "$(bash_payload "bash $WS/harness-status.sh --config /tmp/other.json")" '.decision == "deny" and .rule == "helper.argv"'
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
as_master "orchestrator memory-lint --fix is allowed" "$(bash_payload "bash $KNOW/memory-lint.sh --fix")" '.decision == "allow"'
as_master "orchestrator docs-write inside the workspace is allowed" "$(bash_payload "bash $KNOW/docs-write.sh --repo $ROOT")" '.decision == "allow"'
as_master "orchestrator docs-write outside the workspace is denied" "$(bash_payload "bash $KNOW/docs-write.sh --repo /tmp")" '.decision == "deny" and .rule == "helper.argv"'
as_master "orchestrator auto-capture helper (hook-only) is denied" "$(bash_payload "bash $KNOW/memory-auto-capture.sh")" '.decision == "deny" and .rule == "helper.allowlist"'
as_master "orchestrator workspace-stop --confirmed is allowed" "$(bash_payload "bash $WS/workspace-stop.sh development --confirmed")" '.decision == "allow"'
as_master "orchestrator workspace.sh start via dispatcher is allowed" "$(bash_payload "bash $WS/workspace.sh start --no-attach")" '.decision == "allow"'
as_master "orchestrator workspace start with a foreign --config is denied" "$(bash_payload "bash $WS/workspace-start.sh --config /tmp/other.json")" '.decision == "deny" and .rule == "helper.argv"'
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

echo "== audit vs enforce =="
expect "audit mode reports a policy denial as audit" reviewer "$REVIEW_PANE" "$CHILD" "$AUDIT_CONFIG" audit \
  "$(edit_payload 'src/file.ts')" '.decision == "audit" and .mode == "audit" and .rule == "reviewer.readonly"'
expect "audit mode still allows an allowed action" reviewer "$REVIEW_PANE" "$CHILD" "$AUDIT_CONFIG" audit \
  "$(bash_payload 'git status')" '.decision == "allow" and .mode == "audit"'
expect "audit mode identity failure is still a deny" reviewer unknown-pane "$CHILD" "$AUDIT_CONFIG" audit \
  "$(bash_payload 'git status')" '.decision == "deny" and .rule == "identity.pane"'

echo "== hook exit behavior =="
hook_run() {
  # hook_run ROLE PANE CWD CONFIG MODE PAYLOAD STDOUT_FILE STDERR_FILE -> exit status
  local role="$1" pane="$2" cwd="$3" config="$4" mode="$5" payload="$6" out="$7" err="$8"
  printf '%s' "$payload" | env \
    -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME \
    SESSION_WORKSPACE_CONFIG="$config" SESSION_WORKSPACE_PROJECT_ROOT="$ROOT" \
    SESSION_WORKSPACE_PANE_NAME="$pane" SESSION_WORKSPACE_ROLE="$role" \
    SESSION_WORKSPACE_PANE_CWD="$cwd" SESSION_WORKSPACE_HARNESS_MODE="$mode" \
    CLAUDE_HOME="$FAKE_CLAUDE" CODEX_HOME="$FAKE_CODEX" \
    "$PY" "$POLICY" >"$out" 2>"$err"
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
hook_run reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(bash_payload 'git status')" "$TMPROOT/allow.out" "$TMPROOT/allow.err"
ALLOW_STATUS=$?
if [ "$ALLOW_STATUS" -eq 0 ] && [ ! -s "$TMPROOT/allow.out" ] && [ ! -s "$TMPROOT/allow.err" ]; then
  pass "allow is silent (exit 0, no stdout, no stderr)"
else
  fail "allow is silent (exit 0, no stdout, no stderr)" "status=$ALLOW_STATUS out=$(cat "$TMPROOT/allow.out") err=$(cat "$TMPROOT/allow.err")"
fi
hook_run reviewer unknown-pane "$CHILD" "$AUDIT_CONFIG" audit "$(bash_payload 'git status')" "$TMPROOT/drift.out" "$TMPROOT/drift.err"
DRIFT_STATUS=$?
if [ "$DRIFT_STATUS" -eq 2 ] && grep -q '^BLOCKED' "$TMPROOT/drift.err"; then
  pass "identity failure blocks (exit 2) even in audit mode"
else
  fail "identity failure blocks (exit 2) even in audit mode" "status=$DRIFT_STATUS err=$(cat "$TMPROOT/drift.err")"
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
