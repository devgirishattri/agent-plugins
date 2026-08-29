#!/usr/bin/env bash
# lib.sh — Shared functions for the session-workspace plugin.
# Source this file: source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# Supported platforms: macOS, Linux

# State, lock, and config files this engine creates hold project-local
# coordination data (workspace plans, layout snapshots, adoption records)
# that must stay private to this user. Force owner-only perms on everything
# created here. This is process-local (each session-workspace script runs in
# its own subprocess), so it never tightens the user's interactive umask.
# Mirrors plugins/session-chat/scripts/lib.sh:15.
umask 077

# The bootstrap shim (templates/workspace.sh) resolves the newest compatible
# plugin install by asking `workspace.sh --contract` for this exact string.
# Bump the trailing integer only on a breaking CLI contract change.
# shellcheck disable=SC2034  # consumed by workspace.sh after sourcing this file
SESSION_WORKSPACE_CLI_CONTRACT="session-workspace-cli 1"

# library_not_executable FILE — the guard a SOURCE-ONLY file calls when it is
# executed directly instead of sourced (config.sh does this). It is not a
# "not implemented yet" marker: every verb of this engine is implemented, and
# the only thing wrong in this situation is the way the file was invoked.
library_not_executable() {
  local file="$1"
  echo "ERROR: '$file' is a library and must not be executed directly." >&2
  echo "Source it from an engine script instead: source \"\$HERE/$file\"" >&2
  echo "The user-facing entrypoint is workspace.sh (see: workspace.sh --help)." >&2
  exit 1
}

ensure_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is not installed." >&2
    echo "Install with: brew install jq (macOS) or apt install jq (Ubuntu)" >&2
    exit 1
  fi
}

ensure_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "ERROR: tmux is not installed." >&2
    echo "Install with: brew install tmux (macOS) or apt install tmux (Ubuntu)" >&2
    exit 1
  fi
}

# Persistent Chrome profiles are derived from the validated project id, never
# from a project-committed absolute home path. This keeps cookies isolated and
# makes one workspace config portable across machines.
sw_browser_profile_dir() {
  printf '%s/session-workspace/chrome/%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}" "$1"
}

sw_browser_probe() {
  local port="$1" payload
  command -v curl >/dev/null 2>&1 || return 2
  payload="$(curl -fsS --max-time 1 "http://127.0.0.1:${port}/json/version" 2>/dev/null)" || return 1
  printf '%s' "$payload" | jq -e '(.Browser | type == "string") and (.webSocketDebuggerUrl | type == "string")' >/dev/null 2>&1
}

sw_browser_wait_ready() {
  local port="$1" attempts="${2:-50}" i=0
  while [ "$i" -lt "$attempts" ]; do
    sw_browser_probe "$port" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Cross-project allocation registry. The directory lock is machine-global for
# this user, so two projects cannot simultaneously claim the same DevTools
# port. A stale claim is reclaimed only when its endpoint is no longer a live
# DevTools browser.
sw_browser_claim_port() {
  local project_id="$1" port="$2" root lock owner_file owner="" waited=0
  root="${XDG_STATE_HOME:-$HOME/.local/state}/session-workspace/browser-ports"
  mkdir -p "$root" || return 1
  lock="$root/.lock"
  while ! mkdir "$lock" 2>/dev/null; do
    [ "$waited" -ge 50 ] && { echo "ERROR: timed out acquiring browser-port allocation lock" >&2; return 1; }
    sleep 0.1
    waited=$((waited + 1))
  done
  owner_file="$root/$port"
  [ -f "$owner_file" ] && owner="$(sed -n '1p' "$owner_file")"
  if [ -n "$owner" ] && [ "$owner" != "$project_id" ] && sw_browser_probe "$port"; then
    rmdir "$lock" 2>/dev/null || true
    echo "ERROR: browser port $port is owned by project '$owner' and its DevTools endpoint is live" >&2
    return 1
  fi
  printf '%s\n' "$project_id" >"$owner_file"
  rmdir "$lock" 2>/dev/null || true
  return 0
}

sw_browser_release_port() {
  local project_id="$1" port="$2" owner_file owner=""
  owner_file="${XDG_STATE_HOME:-$HOME/.local/state}/session-workspace/browser-ports/$port"
  [ -f "$owner_file" ] || return 0
  owner="$(sed -n '1p' "$owner_file")"
  [ "$owner" = "$project_id" ] && rm -f "$owner_file"
}

# ============================================================================
# Sibling-plugin resolution — shared by workspace-doctor.sh (which REPORTS
# whether a helper resolves) and workspace-start.sh (which GATES on it per
# behavior.session_chat_helper.on_missing). Defined once, here, so the two can
# never disagree about what "resolves" means.
# ============================================================================

# sw_version_ge A B — true when version A >= B. `sort -V` handles the
# ordering, including tmux's "3.6b"-style suffix.
sw_version_ge() {
  [ "$1" = "$2" ] && return 0
  local lowest
  lowest="$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)"
  [ "$lowest" = "$2" ]
}

# sw_plugin_manifest_version ROOT — best-effort version of an installed or
# source-checkout plugin. A cached install dir is named by its version; a
# source checkout carries it in the (claude- or codex-flavored) manifest.
# grep, not jq, so this still works when jq is the missing dependency.
sw_plugin_manifest_version() {
  local root="$1" base ver mf
  base="$(basename "$root")"
  case "$base" in
    [0-9]*.[0-9]*.[0-9]*)
      printf '%s' "$base"
      return 0
      ;;
  esac
  for mf in "$root/.claude-plugin/plugin.json" "$root/.codex-plugin/plugin.json"; do
    [ -f "$mf" ] || continue
    ver="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$mf" 2>/dev/null \
      | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
    [ -n "$ver" ] && { printf '%s' "$ver"; return 0; }
  done
  return 1
}

# sw_newest_cache_root NAME — newest installed cache root for a plugin, across
# both provider caches. Prints the path, or nothing.
sw_newest_cache_root() {
  local name="$1" base d ver best_ver="" best_path=""
  for base in "$HOME/.codex/plugins/cache" "$HOME/.claude/plugins/cache"; do
    [ -d "$base" ] || continue
    for d in "$base"/*/"$name"/*; do
      [ -d "$d" ] || continue
      ver="$(basename "$d")"
      case "$ver" in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) continue ;;
      esac
      if [ -z "$best_ver" ] || sw_version_ge "$ver" "$best_ver"; then
        best_ver="$ver"
        best_path="$d"
      fi
    done
  done
  [ -n "$best_path" ] && printf '%s' "$best_path"
  return 0
}

# sw_source_tree_root NAME — this engine's sibling plugin directory in the
# source tree it was launched from (plugins/<name> or codex/plugins/<name>).
# Resolved from ${BASH_SOURCE[0]} (this file lives in <plugin>/scripts/), never
# from the caller's $0 or $HERE, so it is correct for every sourcing script.
# $SESSION_WORKSPACE_SOURCE_TREE_DIR overrides the sibling directory; it
# exists so the test suite can point the drift comparison at a fixture tree
# instead of the developer's real checkout (whose versions move constantly).
sw_source_tree_root() {
  local name="$1" siblings
  if [ -n "${SESSION_WORKSPACE_SOURCE_TREE_DIR:-}" ]; then
    siblings="$SESSION_WORKSPACE_SOURCE_TREE_DIR"
  else
    siblings="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)" || return 1
  fi
  [ -d "$siblings/$name" ] || return 1
  printf '%s' "$siblings/$name"
}

# sw_session_chat_helper_root — prints the resolved session-chat plugin root
# and returns 0, or prints nothing and returns 1 when the helper cannot be
# resolved at all. "Resolvable" means: a newest-version cache install or the
# sibling source tree that actually carries scripts/lib.sh (the helper file
# every session-chat integration point sources).
# Each candidate is checked in turn (rather than only the first that EXISTS),
# so an installed-but-incomplete cache dir does not mask a perfectly usable
# source checkout.
sw_session_chat_helper_root() {
  local root
  root="$(sw_newest_cache_root "session-chat")"
  if [ -n "$root" ] && [ -f "$root/scripts/lib.sh" ]; then
    printf '%s' "$root"
    return 0
  fi
  root="$(sw_source_tree_root "session-chat")" || return 1
  [ -n "$root" ] && [ -f "$root/scripts/lib.sh" ] || return 1
  printf '%s' "$root"
}

# Canonicalize a path without relying on realpath (absent on older stock
# macOS) — see docs/... defect #9. Prints nothing and returns non-zero if the
# directory does not exist.
canonicalize_dir() {
  local dir="$1"
  (cd "$dir" 2>/dev/null && pwd -P)
}

# _parse_env_file_value PATH KEY
# Parses PATH as literal KEY=value lines (never sourced/eval'd — a malicious
# "$(rm -rf ~)" value must stay inert text). Only a strict
# ^[A-Za-z_][A-Za-z0-9_]*=... line shape is recognized; the last matching line
# wins (shell-like semantics). Prints the value (unquoted, raw) or nothing.
# Shared by adapters.sh and workspace-doctor.sh so delivery and diagnosis can
# never disagree about which line supplies a configured key.
_parse_env_file_value() {
  local path="$1" key="$2" line k v found="" matched=0
  [ -f "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$line" in
      [A-Za-z_]*=*)
        k="${line%%=*}"
        v="${line#*=}"
        if [ "$k" = "$key" ]; then
          found="$v"
          matched=1
        fi
        ;;
    esac
  done <"$path"
  [ "$matched" -eq 1 ] || return 1
  printf '%s' "$found"
  return 0
}
