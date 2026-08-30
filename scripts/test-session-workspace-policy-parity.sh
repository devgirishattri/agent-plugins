#!/usr/bin/env bash
# Compare normalized strict-v1 policy decisions across provider adapters.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CODEX_POLICY="$ROOT_DIR/codex/plugins/session-workspace/scripts/harness-policy.py"
CLAUDE_POLICY="$ROOT_DIR/plugins/session-workspace/scripts/harness-policy.py"
FIXTURE="$ROOT_DIR/codex/plugins/session-workspace/scripts/fixtures/valid/harness-v2.json"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/session-workspace-policy-parity.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
FAILURES=()
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("$1: $2"); printf '  FAIL  %s — %s\n' "$1" "$2"; }

PROJECT="$TMPROOT/project"
mkdir -p "$PROJECT/.agent-workspace" "$PROJECT/component-a/src" "$PROJECT/component-a/safe" \
  "$PROJECT/component-a/src/inside" "$PROJECT/component-a/src/repeat-safe" \
  "$PROJECT/component-b" "$PROJECT/wrap/repeat-child" "$PROJECT/safe/nested" \
  "$TMPROOT/executor-outside"
PROJECT="$(cd "$PROJECT" && pwd -P)"
CONFIG="$PROJECT/.agent-workspace/workspace.json"
cp "$FIXTURE" "$CONFIG"
AUDIT_CONFIG="$PROJECT/.agent-workspace/audit.json"
jq '.harness.mode = "audit"' "$CONFIG" > "$AUDIT_CONFIG"
CHILD="$PROJECT/component-a"
OUTSIDE_SECRET="$TMPROOT/outside-secret.txt"
printf 'outside\n' > "$OUTSIDE_SECRET"
ln -s "$OUTSIDE_SECRET" "$CHILD/escape-link"
ln -s "$OUTSIDE_SECRET" "$CHILD/escape link"
ln -s "$TMPROOT/executor-outside" "$CHILD/src/safe"
ln -s "$CHILD" "$PROJECT/wrap/safe"
ln -s "$TMPROOT/executor-outside" "$CHILD/repeat-safe"
ln -s "$CHILD" "$PROJECT/repeat-child"

MASTER_PANE=harness-sample-master
EXEC_PANE=harness-sample-component-executor
REVIEW_PANE=harness-sample-component-reviewer

payload_bash() { jq -cn --arg command "$1" '{tool_name:"Bash",tool_input:{command:$command}}'; }
payload_edit() { jq -cn --arg path "$1" '{tool_name:"apply_patch",tool_input:{path:$path}}'; }

decision() {
  local policy="$1" role="$2" pane="$3" cwd="$4" config="$5" mode="$6" payload="$7"
  printf '%s' "$payload" | env \
    -u SESSION_CHAT_PANE_NAME -u KNOWLEDGE_PANE_NAME \
    SESSION_WORKSPACE_CONFIG="$config" \
    SESSION_WORKSPACE_PROJECT_ROOT="$PROJECT" \
    SESSION_WORKSPACE_PANE_NAME="$pane" \
    SESSION_WORKSPACE_ROLE="$role" \
    SESSION_WORKSPACE_PANE_CWD="$cwd" \
    SESSION_WORKSPACE_HARNESS_MODE="$mode" \
    CODEX_HOME="$TMPROOT/empty-codex" \
    CLAUDE_CONFIG_DIR="$TMPROOT/empty-claude" \
    python3 "$policy" --decision-json
}

normalize_decision() {
  jq -cS '{
    active: .active,
    mode: (if .active then .mode else "inactive" end),
    role: (if .active then (if (.role // "") == "" then "unknown" else .role end) else "inactive" end),
    decision: (if .decision == "audit" then "deny" else .decision end),
    effective_decision: (
      if has("effective_decision") then .effective_decision
      elif .decision == "audit" then "allow"
      else .decision
      end
    ),
    rule: .rule
  }'
}

compare_case() {
  local label="$1" role="$2" pane="$3" cwd="$4" config="$5" mode="$6" payload="$7" expected_decision="${8:-}"
  local codex claude codex_normalized claude_normalized actual_decision
  codex="$(decision "$CODEX_POLICY" "$role" "$pane" "$cwd" "$config" "$mode" "$payload" 2>&1)"
  claude="$(decision "$CLAUDE_POLICY" "$role" "$pane" "$cwd" "$config" "$mode" "$payload" 2>&1)"
  if ! printf '%s' "$codex" | jq -e . >/dev/null 2>&1; then
    fail "$label" "Codex did not emit JSON: $codex"
  elif ! printf '%s' "$claude" | jq -e . >/dev/null 2>&1; then
    fail "$label" "Claude did not emit JSON: $claude"
  else
    codex_normalized="$(printf '%s' "$codex" | normalize_decision)"
    claude_normalized="$(printf '%s' "$claude" | normalize_decision)"
    actual_decision="$(printf '%s' "$codex_normalized" | jq -r '.decision')"
    if [ "$codex_normalized" != "$claude_normalized" ]; then
      fail "$label" "codex=$codex_normalized claude=$claude_normalized"
    elif [ -n "$expected_decision" ] && [ "$actual_decision" != "$expected_decision" ]; then
      fail "$label" "providers agree on $actual_decision; expected $expected_decision ($codex_normalized)"
    else
      pass "$label"
    fi
  fi
}

echo "== normalized cross-provider strict-v1 decisions =="
compare_case "executor edit inside child" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_edit 'src/file.ts')"
compare_case "executor edit traversal" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_edit '../component-b/file.ts')"
compare_case "executor absolute Bash path escape" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'rm /tmp/outside')"
EXEC_WORKDIR_ESCAPE="$(jq -cn --arg workdir "$PROJECT/component-b" '{tool_name:"Bash",tool_input:{command:"pwd",workdir:$workdir}}')"
compare_case "executor tool workdir escape" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$EXEC_WORKDIR_ESCAPE"
compare_case "executor inline interpreter escape" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash "python3 -c 'open(\"/tmp/x\",\"w\")'")"
compare_case "executor cd traversal before sibling mutation" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'cd .. && rm component-b/secret.ts')" deny
compare_case "executor unknown previous cwd transition" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'cd - && rm component-b/secret.ts')" deny
compare_case "executor pushd traversal before sibling mutation" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'pushd .. && rm component-b/secret.ts')" deny
compare_case "executor popd unknown cwd transition" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'popd && rm component-b/secret.ts')" deny
compare_case "executor wrapped cwd transition" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'command cd .. && rm component-b/secret.ts')" deny
compare_case "executor env chdir escape" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'env --chdir=.. rm component-b/secret.ts')" deny
compare_case "executor unresolved variable operand" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'rm "$TARGET"')" deny
compare_case "executor quoted outside path containing spaces" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'rm "/tmp/outside file"')" deny
compare_case "executor bare relative symlink escape" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'cat escape-link')" deny
compare_case "executor bare spaced symlink escape" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'cat "escape link"')" deny
compare_case "executor command-wrapped cd symlink write" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'command cd . && truncate -s 0 escape-link')" deny
compare_case "executor builtin-wrapped cd symlink write" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'builtin cd . && truncate -s 0 escape-link')" deny
compare_case "executor redirection through bare symlink" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'printf x > escape-link')" deny
compare_case "executor output redirection outside cwd" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'printf x > /tmp/session-workspace-outside')" deny
compare_case "executor input redirection outside cwd" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'cat < /tmp/session-workspace-outside')" deny
compare_case "executor append redirection through bare symlink" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'printf x >> escape-link')" deny
compare_case "executor unquoted glob symlink escape" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'cat escape-*')" deny
compare_case "executor attached Git cwd escape" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'git -C.. clean -fd')" deny
compare_case "executor attached make cwd escape" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'make -C.. clean')" deny
compare_case "executor attached env cwd escape" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'env -C.. rm component-b/secret.ts')" deny
compare_case "executor separated env cwd escape" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'env -C .. rm component-b/secret.ts')" deny
compare_case "executor separated long env cwd escape" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'env --chdir .. rm component-b/secret.ts')" deny
compare_case "executor nested env cwd symlink escape" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'env -C src env -C safe truncate -s 0 target')" deny
compare_case "executor nested env cwd inside control" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'env -C src env -C inside pwd')" allow
compare_case "executor repeated separated env cwd options" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'env -C src -C repeat-safe truncate -s 0 target')" deny
compare_case "executor repeated attached env cwd options" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'env -Csrc -Crepeat-safe truncate -s 0 target')" deny
compare_case "executor repeated mixed env cwd options" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'env --chdir src -Crepeat-safe truncate -s 0 target')" deny
compare_case "executor Codex sandbox bypass flag" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'codex --dangerously-bypass-approvals-and-sandbox')" deny
compare_case "executor sudo cwd escape" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'sudo -D .. rm component-b/secret.ts')" deny
compare_case "executor sudo routing bypass" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'sudo -u root tmux send-keys -t peer work')" deny
compare_case "executor doas routing bypass" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'doas -u root tmux send-keys -t peer work')" deny
compare_case "executor su privilege wrapper" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash "su -c 'tmux send-keys -t peer work'")" deny
compare_case "executor runuser privilege wrapper" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'runuser -u root tmux send-keys -t peer work')" deny
compare_case "executor pkexec privilege wrapper" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'pkexec tmux send-keys -t peer work')" deny
compare_case "executor exec argv-zero routing bypass" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'exec -a fake tmux send-keys -t peer work')" deny
compare_case "executor exec login routing bypass" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'exec -l tmux send-keys -t peer work')" deny
compare_case "executor nohup routing bypass" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'nohup -- tmux send-keys -t peer work')" deny
compare_case "executor env split-string routing bypass" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash "env -S 'tmux send-keys -t peer work'")" deny
compare_case "executor env long split-string routing bypass" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash "env --split-string='tmux send-keys -t peer work'")" deny
compare_case "executor env missing unset value" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'env --unset= tmux send-keys -t peer work')" deny
compare_case "executor unsupported command option" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'command -p tmux send-keys -t peer work')" deny
compare_case "executor unsupported builtin option" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'builtin -a tmux send-keys -t peer work')" deny
compare_case "reviewer read-only Git" reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'git status --short')"
compare_case "reviewer sibling read escape" reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'cat ../component-b/README.md')"
compare_case "reviewer bare parent read escape" reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'ls ..')" deny
compare_case "reviewer Git parent cwd escape" reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'git -C .. status')" deny
compare_case "reviewer quoted outside path containing spaces" reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'cat "/tmp/outside file"')" deny
compare_case "reviewer bare relative symlink escape" reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'cat escape-link')" deny
compare_case "reviewer bare spaced symlink escape" reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'cat "escape link"')" deny
compare_case "reviewer edit denial" reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(payload_edit 'src/file.ts')"
compare_case "reviewer unknown mutation" reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'touch file')"
compare_case "reviewer Git mutation" reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'git config user.email reviewer@example.test')"
compare_case "reviewer Git branch creation" reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'git branch reviewer-branch')"
compare_case "reviewer Git remote mutation" reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'git remote set-url origin https://example.invalid/repo.git')"
compare_case "reviewer environment wrapper" reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash "GIT_PAGER='touch reviewer-file' git log -1")"
compare_case "reviewer sed mutation" reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'sed -i s/a/b/ file')"
compare_case "reviewer redirection" reviewer "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'git status > out')"
compare_case "orchestrator root edit" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_edit 'AGENTS.md')"
compare_case "orchestrator child edit" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_edit 'component-a/src/file.ts')"
compare_case "orchestrator child read" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash 'cat component-a/README.md')"
compare_case "orchestrator child mutation" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash 'rm component-a/src/file.ts')"
MASTER_CHILD_WORKDIR="$(jq -cn --arg workdir "$CHILD" '{tool_name:"Bash",tool_input:{command:"pwd",workdir:$workdir}}')"
compare_case "orchestrator tool workdir" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$MASTER_CHILD_WORKDIR"
compare_case "orchestrator attached env child cwd mutation" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash 'env -Ccomponent-a npm test')" deny
compare_case "orchestrator nested env cwd child symlink mutation" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash 'env -C wrap env -C safe npm test')" deny
compare_case "orchestrator nested env root-local read control" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash 'env -C safe env -C nested git status')" allow
compare_case "orchestrator repeated env cwd options landing in child" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash 'env -C wrap -C repeat-child npm test')" deny
compare_case "orchestrator attached Git child cwd mutation" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash 'git -Ccomponent-a clean -fd')" deny
compare_case "orchestrator attached make child cwd mutation" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash 'make -Ccomponent-a clean')" deny
compare_case "orchestrator command-wrapped child cd mutation" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash 'command cd component-a && npm test')" deny
compare_case "orchestrator builtin-wrapped child cd mutation" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash 'builtin cd component-a && npm test')" deny
compare_case "orchestrator command-wrapped child pushd mutation" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash 'command pushd component-a && npm test')" deny
compare_case "orchestrator Git push" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash 'git -C . push origin main')" deny
compare_case "orchestrator env-wrapped Git push" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash 'env git push origin main')" deny
compare_case "orchestrator command-wrapped Git push" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash 'command git push origin main')" deny
compare_case "orchestrator assignment-prefixed Git push" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash 'GIT_CONFIG_NOSYSTEM=1 git push origin main')" deny
compare_case "orchestrator sudo-wrapped Git push" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash 'sudo -u root git push origin main')" deny
compare_case "orchestrator doas-wrapped Git push" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash 'doas -u root git push origin main')" deny
compare_case "orchestrator pkexec-wrapped Git push" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash 'pkexec git push origin main')" deny
compare_case "orchestrator exec argv-zero Git push" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash 'exec -a fake git push origin main')" deny
compare_case "orchestrator exec login Git push" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash 'exec -l git push origin main')" deny
compare_case "orchestrator nohup Git push" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash 'nohup -- git push origin main')" deny
compare_case "orchestrator env split-string Git push" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash "env -S 'git push origin main'")" deny
compare_case "orchestrator env long split-string Git push" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash "env --split-string='git push origin main'")" deny
compare_case "orchestrator time-output Git push" master "$MASTER_PANE" "$PROJECT" "$CONFIG" enforce "$(payload_bash '/usr/bin/time -o timing.txt git push origin main')" deny
compare_case "executor direct tmux routing bypass" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash "tmux send-keys -t $REVIEW_PANE work")"
compare_case "forged role" executor "$REVIEW_PANE" "$CHILD" "$CONFIG" enforce "$(payload_bash 'git status')"
compare_case "unknown pane" executor unknown-pane "$CHILD" "$CONFIG" enforce "$(payload_bash 'pwd')"
compare_case "mode drift" executor "$EXEC_PANE" "$CHILD" "$CONFIG" audit "$(payload_bash 'pwd')"
compare_case "audit effective allow" reviewer "$REVIEW_PANE" "$CHILD" "$AUDIT_CONFIG" audit "$(payload_edit 'src/file.ts')"
compare_case "audit identity drift remains blocked" reviewer "$EXEC_PANE" "$CHILD" "$AUDIT_CONFIG" audit "$(payload_bash 'pwd')"
compare_case "audit malformed input remains blocked" executor "$EXEC_PANE" "$CHILD" "$AUDIT_CONFIG" audit '{bad'
compare_case "malformed input" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce '{bad'

PATCH_PAYLOAD="$(jq -cn --arg patch $'*** Begin Patch\n*** Update File: src/file.ts\n@@\n-old\n+new\n*** End Patch' '{tool_name:"apply_patch",tool_input:{patch:$patch}}')"
compare_case "decoded apply_patch path" executor "$EXEC_PANE" "$CHILD" "$CONFIG" enforce "$PATCH_PAYLOAD"

CODEX_INACTIVE="$(printf '%s' "$(payload_bash 'rm -rf /')" | env -u SESSION_WORKSPACE_CONFIG -u SESSION_WORKSPACE_HARNESS_MODE python3 "$CODEX_POLICY" --decision-json 2>&1)"
CLAUDE_INACTIVE="$(printf '%s' "$(payload_bash 'rm -rf /')" | env -u SESSION_WORKSPACE_CONFIG -u SESSION_WORKSPACE_HARNESS_MODE python3 "$CLAUDE_POLICY" --decision-json 2>&1)"
if [ "$(printf '%s' "$CODEX_INACTIVE" | normalize_decision 2>/dev/null)" = "$(printf '%s' "$CLAUDE_INACTIVE" | normalize_decision 2>/dev/null)" ] && \
   printf '%s' "$CODEX_INACTIVE" | jq -e '.active == false and .decision == "allow"' >/dev/null 2>&1; then
  pass "no-env inactive no-op"
else
  fail "no-env inactive no-op" "codex=$CODEX_INACTIVE claude=$CLAUDE_INACTIVE"
fi

printf '\n-----------------------------------------------\n'
printf 'session-workspace policy parity: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\nFailures:\n'
  for item in "${FAILURES[@]}"; do printf '  - %s\n' "$item"; done
  exit 1
fi
