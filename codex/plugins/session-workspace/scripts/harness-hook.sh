#!/usr/bin/env bash
# Thin hook boundary: preserve a zero-cost/no-Python inactive path, while an
# engine-marked active harness fails closed if its policy runtime disappears.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SESSION_WORKSPACE_CONFIG:-}"
MODE="${SESSION_WORKSPACE_HARNESS_MODE:-}"

# Drain the hook payload before any early exit: the runner writes a full
# tool-input JSON (a large Edit can exceed the pipe buffer) and an instant
# exit would SIGPIPE it. Nothing in the payload is needed on the no-op paths.
if [ -z "$CONFIG" ]; then
  cat >/dev/null 2>&1 || true
  exit 0
fi

if [ -z "$MODE" ]; then
  # jq is already a hard dependency of session-workspace. A v1 config or an
  # explicit v2/v3 enabled=false config is a true hook no-op.
  if [ ! -f "$CONFIG" ] || ! command -v jq >/dev/null 2>&1 || \
     ! jq -e '(.schema_version == 2 or .schema_version == 3) and (.harness.enabled // false)' "$CONFIG" >/dev/null 2>&1; then
    cat >/dev/null 2>&1 || true
    exit 0
  fi
fi

if ! command -v python3 >/dev/null 2>&1; then
  cat >/dev/null 2>&1 || true
  echo "BLOCKED by session-workspace strict-v1 [runtime.python]: active harness requires python3" >&2
  exit 2
fi

exec python3 "$HERE/harness-policy.py" "$@"
