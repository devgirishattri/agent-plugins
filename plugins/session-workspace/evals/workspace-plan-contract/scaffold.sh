#!/usr/bin/env bash
# Fixture only. $1 = workspace path (Codex runner); defaults to PWD (Claude runner).
set -euo pipefail
cd "${1:-$PWD}"
mkdir -p .agent-workspace
git init -q 2>/dev/null || true
cat > .agent-workspace/workspace.json <<'JSON'
{"schema_version":1,"project":{"id":"fixture","root":"."},"runtimes":{"claude":{"program":"claude"}},
"roles":{"orchestrator":{"runtime":"claude","env_group":"dev"}},"stores":{"pin":[]},
"sessions":[{"id":"fixture-main","name":"fixture-main","panes":[{"name":"orchestrator","role":"orchestrator","cwd":"."}]}]}
JSON
