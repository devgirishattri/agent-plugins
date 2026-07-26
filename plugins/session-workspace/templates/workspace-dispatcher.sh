#!/usr/bin/env bash
# workspace-dispatcher.sh — MACHINE-WIDE entry point for the session-workspace
# plugin. Install it once, on PATH, as `workspace`:
#
#     cp templates/workspace-dispatcher.sh ~/.local/bin/workspace
#     chmod +x ~/.local/bin/workspace
#
# Unlike templates/workspace.sh (the per-project bootstrap shim), NOTHING is
# copied into a project. A project is adopted purely by creating
# .agent-workspace/workspace.json; from then on `workspace <verb>` run anywhere
# inside it — including any subdirectory — routes to the engine, because the
# engine resolves its config by walking up from $PWD.
#
# Config resolution is left entirely to the engine, in its documented order:
#   1. --config PATH
#   2. $SESSION_WORKSPACE_CONFIG
#   3. an upward walk from $PWD for .agent-workspace/workspace.json
# This dispatcher deliberately does NOT pin (2): pinning would tie the config to
# wherever this file lives, which for a machine-wide entry point is nowhere in
# particular. Outside any configured project the engine prints its own
# discovery error naming all three options.
set -uo pipefail

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
