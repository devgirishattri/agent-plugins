#!/usr/bin/env bash
# Thin hook boundary: preserve a zero-cost/no-Python inactive path, while an
# engine-marked active harness fails closed if its policy runtime disappears.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SESSION_WORKSPACE_CONFIG:-}"
MODE="${SESSION_WORKSPACE_HARNESS_MODE:-}"

# hooks.json passes nothing (Claude) or --codex-hook-output (Codex). Any other
# argument would reach a policy test mode (--decision-json, --as-role), which
# always exits 0, so the hook refuses it instead of forwarding it.
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--codex-hook-output" ]; }; then
  cat >/dev/null 2>&1 || true
  echo "BLOCKED by session-workspace strict-v1 [runtime.args]: the hook accepts only --codex-hook-output" >&2
  printf '%s\n' 'DIAG {"schema":"diag/1","emitter":"workspace-hook","helper":null,"version":null,"subject":"admission","phase":"admission","reason":"hook.runtime.args","outcome":"refused","state_committed":false,"notification":null,"task":null,"generation":null,"event":null,"request":null,"also":[],"also_truncated":false}' >&2 || true
  exit 2
fi

# A pane whose engine role, engine pane name or tmux @name says "reviewer"
# never takes a no-op path below: harness-policy.py decides it, and refuses it
# when no readable config backs it (identity.reviewer). Bash 3.2 safe, and
# needs no external tool (the no-python3 path runs with a bare PATH).
claims_reviewer() {
  local value claim='(^|[^a-zA-Z0-9])[rR][eE][vV][iI][eE][wW][eE][rR]([^a-zA-Z0-9]|$)'
  for value in "${SESSION_WORKSPACE_ROLE:-}" "${SESSION_WORKSPACE_PANE_NAME:-}"; do
    [[ "$value" =~ $claim ]] && return 0
  done
  [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1 || return 1
  value="$(tmux display-message -p -t "$TMUX_PANE" '#{@name}' 2>/dev/null)"
  [[ "$value" =~ $claim ]]
}

# Drain the hook payload before any early exit: the runner writes a full
# tool-input JSON (a large Edit can exceed the pipe buffer) and an instant
# exit would SIGPIPE it. Nothing in the payload is needed on the no-op paths.
if [ -z "$CONFIG" ] && ! claims_reviewer; then
  cat >/dev/null 2>&1 || true
  exit 0
fi

if [ -n "$CONFIG" ] && [ -z "$MODE" ]; then
  # jq is already a hard dependency of session-workspace. A v1 config or an
  # explicit v2+ enabled=false config is a true hook no-op.
  if [ ! -f "$CONFIG" ] || ! command -v jq >/dev/null 2>&1 || \
     ! jq -e '(.schema_version == 2 or .schema_version == 3 or .schema_version == 4 or .schema_version == 5) and (.harness.enabled // false)' "$CONFIG" >/dev/null 2>&1; then
    if ! claims_reviewer; then
      cat >/dev/null 2>&1 || true
      exit 0
    fi
  fi
fi

if ! command -v python3 >/dev/null 2>&1; then
  cat >/dev/null 2>&1 || true
  echo "BLOCKED by session-workspace strict-v1 [runtime.python]: active harness requires python3" >&2
  # Fixed diag/1 record: no Python, no jq, and no input interpolation.
  printf '%s\n' 'DIAG {"schema":"diag/1","emitter":"workspace-hook","helper":null,"version":null,"subject":"admission","phase":"admission","reason":"hook.runtime.python","outcome":"refused","state_committed":false,"notification":null,"task":null,"generation":null,"event":null,"request":null,"also":[],"also_truncated":false}' >&2 || true
  exit 2
fi

exec python3 "$HERE/harness-policy.py" "$@"
