#!/usr/bin/env bash
# Schema-v3/v4 Stop diagnostics. Feature-off/unlaunched sessions exit before jq
# or Python so this global plugin hook is free for non-adopters.
set -uo pipefail

CODEX_OUTPUT=0
if [ "${1:-}" = "--codex-hook-output" ]; then
  CODEX_OUTPUT=1
  shift
fi
[ $# -eq 0 ] || exit 0

CONFIG="${SESSION_WORKSPACE_CONFIG:-}"
GUARDS="${SESSION_WORKSPACE_GUARDS_JSON:-}"
[ -n "$CONFIG" ] && [ -n "$GUARDS" ] || exit 0
[ -r "$CONFIG" ] || exit 0
CONFIG_TEXT="$(<"$CONFIG")"
[[ "$CONFIG_TEXT" =~ \"schema_version\"[[:space:]]*:[[:space:]]*(3|4)[[:space:]]*([,}]) ]] || exit 0
case "$GUARDS" in
  *'"warn_root_dirty":true'*|*'"warn_missing_panes":true'*|*'"branch_ahead":'*) : ;;
  *) exit 0 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || exit 0
if [ "$CODEX_OUTPUT" -eq 1 ]; then
  exec python3 "$HERE/guard-health.py" --codex-hook-output
fi
exec python3 "$HERE/guard-health.py"
