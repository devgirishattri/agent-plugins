#!/usr/bin/env bash
# workspace.sh — project-local bootstrap shim for the session-workspace
# plugin. Copied verbatim into a project as <project-root>/workspace.sh.
# Contains ZERO project-specific logic: it only finds the installed engine
# and hands off to it. All real behavior lives in the plugin's
# scripts/workspace.sh, driven by .agent-workspace/workspace.json.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
export SESSION_WORKSPACE_CONFIG="$PROJECT_DIR/.agent-workspace/workspace.json"

CONTRACT="session-workspace-cli 1"

contract_ok() {
  local out
  out="$(bash "$1/scripts/workspace.sh" --contract 2>/dev/null)" || return 1
  [ "$out" = "$CONTRACT" ]
}

# Newest-first, contract-checked search of one provider's plugin cache:
# <base>/<marketplace>/session-workspace/<version>/. No literal version is
# ever hardcoded here — versions are discovered and sorted with `sort -V`.
newest_compatible() {
  local base="$1" versions ver path
  [ -d "$base" ] || return 1
  versions="$(find "$base" -mindepth 3 -maxdepth 3 -type d \
    -path '*/session-workspace/*' -exec basename {} \; 2>/dev/null | sort -u | sort -Vr)"
  [ -n "$versions" ] || return 1
  while IFS= read -r ver; do
    [ -n "$ver" ] || continue
    for path in "$base"/*/session-workspace/"$ver"; do
      [ -d "$path" ] || continue
      if contract_ok "$path"; then
        printf '%s' "$path"
        return 0
      fi
    done
  done <<EOF
$versions
EOF
  return 1
}

ROOT="${SESSION_WORKSPACE_PLUGIN_ROOT:-}"
if [ -z "$ROOT" ]; then
  ROOT="$(newest_compatible "$HOME/.codex/plugins/cache")" || \
  ROOT="$(newest_compatible "$HOME/.claude/plugins/cache")" || {
    echo "ERROR: no compatible session-workspace plugin install found." >&2
    echo "Install it for Codex:  codex plugin add session-workspace@girishattri-plugins" >&2
    echo "Install it for Claude: claude plugin install session-workspace@girishattri-plugins" >&2
    echo "Or set SESSION_WORKSPACE_PLUGIN_ROOT to an explicit checkout." >&2
    exit 1
  }
fi

exec bash "$ROOT/scripts/workspace.sh" "$@"
