#!/usr/bin/env bash
# config.sh — .agent-workspace/workspace.json discovery, parsing, and token
# interpolation. This module is load-only: it does not enforce the schema or
# any cross-field rule (see validate-config.sh for that). Every consumer
# (workspace-plan.sh, validate-config.sh, and later phases) sources this file.
#
# Discovery order (resolve_project_config_path):
#   1. an explicit --config PATH passed in by the caller
#   2. $SESSION_WORKSPACE_CONFIG
#   3. an upward directory walk from $PWD for .agent-workspace/workspace.json
#   4. a clear error with init guidance
#
# Interpolation (load_workspace_config_raw): the ONLY supported tokens are
#   - a literal "${PROJECT_ROOT}" PREFIX on a string value, replaced with the
#     config's canonicalized project root
#   - a literal "${PROJECT_ID}" substring anywhere in a string value, replaced
#     with project.id (used for session/pane name templating, e.g.
#     "${PROJECT_ID}-development", and memory shard strip_prefix)
# No other interpolation, env-var expansion, or shell substitution is
# performed. Any other "${...}" text in a value is left byte-for-byte as-is.
set -uo pipefail

# Resolve this library's own directory from ${BASH_SOURCE[0]}, never $0:
# this file is SOURCED, so $0 belongs to the caller — and for a `bash -c`
# or `bash -s` caller $0 is literally "bash", which resolved the sibling
# library against $PWD and broke depending on the working directory.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# resolve_project_config_path [OVERRIDE_PATH]
# Prints the resolved config path on stdout, or prints a guidance error to
# stderr and returns 1.
resolve_project_config_path() {
  local override="${1:-}"

  if [ -n "$override" ]; then
    if [ -f "$override" ]; then
      printf '%s\n' "$override"
      return 0
    fi
    echo "ERROR: --config path not found: $override" >&2
    return 1
  fi

  if [ -n "${SESSION_WORKSPACE_CONFIG:-}" ]; then
    if [ -f "$SESSION_WORKSPACE_CONFIG" ]; then
      printf '%s\n' "$SESSION_WORKSPACE_CONFIG"
      return 0
    fi
    echo "ERROR: \$SESSION_WORKSPACE_CONFIG points to a missing file: $SESSION_WORKSPACE_CONFIG" >&2
    return 1
  fi

  local dir
  dir="$(pwd -P)"
  while :; do
    if [ -f "$dir/.agent-workspace/workspace.json" ]; then
      printf '%s\n' "$dir/.agent-workspace/workspace.json"
      return 0
    fi
    [ "$dir" = "/" ] && break
    dir="$(dirname "$dir")"
  done

  cat >&2 <<'EOF'
ERROR: no session-workspace config found.

Searched, in order:
  1. --config PATH
  2. $SESSION_WORKSPACE_CONFIG
  3. .agent-workspace/workspace.json in the current directory and each parent

To initialize this project, create .agent-workspace/workspace.json (schema_version 1)
at the project root. See workspace.schema.json in this plugin's scripts/ directory
for the accepted shape, or copy one of the fixtures/ examples as a starting point.
EOF
  return 1
}

# config_base_dir CONFIG_PATH
# Prints the directory project.root is resolved against ("the config file's
# parent", per the schema doc). In the standard layout the config lives at
# <PROJECT_ROOT>/.agent-workspace/workspace.json, so "parent" means the
# project root itself — the directory *containing* .agent-workspace/, not
# .agent-workspace/ itself. Any other config location (e.g. a bare fixture
# loaded via --config) falls back to the config file's own immediate parent
# directory.
#
# The test keys on the CONTAINING DIRECTORY only, never on the config's
# filename: an alternate config inside .agent-workspace/ (a variant passed via
# --config, or a SESSION_WORKSPACE_CONFIG override) must resolve the same
# project root as workspace.json does. Keying on the filename made root
# silently become .agent-workspace/ itself for any other name, which then
# failed every pane's cwd-containment check for non-obvious reasons.
config_base_dir() {
  local path="$1" dir parent
  dir="$(cd "$(dirname "$path")" && pwd -P)" || { echo ""; return 1; }
  parent="$(basename "$dir")"
  if [ "$parent" = ".agent-workspace" ]; then
    (cd "$dir/.." && pwd -P)
  else
    printf '%s\n' "$dir"
  fi
}

# load_workspace_config_raw CONFIG_PATH
# Prints the config as compact, token-interpolated JSON on stdout. Does not
# validate the config against the schema or any business rule — callers that
# need a trustworthy config MUST run it through validate-config.sh first (see
# require_valid_workspace_config below).
load_workspace_config_raw() {
  local path="$1"

  if [ ! -f "$path" ]; then
    echo "ERROR: config file not found: $path" >&2
    return 1
  fi

  local raw
  if ! raw="$(jq -c '.' "$path" 2>&1)"; then
    echo "ERROR: config file is not valid JSON: $path" >&2
    printf '%s\n' "$raw" >&2
    return 1
  fi

  local pid proot_rel proot_abs cfg_dir
  pid="$(printf '%s' "$raw" | jq -r '.project.id // empty')"
  proot_rel="$(printf '%s' "$raw" | jq -r '.project.root // empty')"
  [ -z "$proot_rel" ] && proot_rel="."
  cfg_dir="$(config_base_dir "$path")"
  proot_abs="$(canonicalize_dir "$cfg_dir/$proot_rel")"
  # project.root may not exist on disk yet (e.g. a not-yet-cloned optional
  # child repo) or may be malformed — fall back to an uncanonicalized join so
  # ${PROJECT_ROOT} interpolation still yields a deterministic string.
  # validate-config.sh's filesystem checks are what actually fail the config
  # in that case, not this loader.
  [ -z "$proot_abs" ] && proot_abs="$cfg_dir/$proot_rel"

  printf '%s' "$raw" | jq -c --arg pid "$pid" --arg root "$proot_abs" '
    def interp:
      if type == "string" then
        (if $root != "" and startswith("${PROJECT_ROOT}")
         then ($root + .[("${PROJECT_ROOT}" | length):])
         else . end)
        | (if $pid != "" then gsub("\\$\\{PROJECT_ID\\}"; $pid) else . end)
      elif type == "object" then with_entries(.value |= interp)
      elif type == "array" then map(interp)
      else . end;
    interp
  '
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  library_not_executable "config.sh"
fi
