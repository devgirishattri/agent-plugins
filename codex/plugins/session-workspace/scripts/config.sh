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
#
# Worker names (schema v5, 0.16.0): an executor or reviewer pane in an
# environment's development session may leave out `name`. The loader then
# names it <project.id>-<environment id>-<executor|reviewer>, plus
# -<label> when the environment has a label in the project state file
# labels.json (written only by workspace-label.sh, under the project lock,
# while that environment's workers are stopped). Every consumer therefore
# sees concrete names; a name written in the config is never changed.
#
# Peer orchestrators (schema v6 with `peers`, 0.17.0): the engine records the
# extra orchestrator sessions and the worker panes it started in the project
# state file instances.json. The loader expands that file into concrete
# sessions and panes (sw_apply_instances), so validation, plan, lifecycle and
# the policy hook all read one expanded config. A raw config must not carry
# those fields itself: they are engine state.
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

  if printf '%s' "$raw" | jq -e '
       .schema_version == 6 and ((.sessions // []) | type) == "array"
       and any(.sessions[]; type == "object" and (has("instance") or (((.panes // []) | type) == "array" and any(.panes[]; type == "object" and has("worker")))))
     ' >/dev/null 2>&1; then
    echo "ERROR: $path: sessions[].instance and panes[].worker are engine state; remove them from the config" >&2
    return 1
  fi

  local interpolated
  interpolated="$(printf '%s' "$raw" | jq -c --arg pid "$pid" --arg root "$proot_abs" '
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
  ')" || return 1
  # A third argument replaces the stored instances in the same way. The state
  # file is read only for a peers config, so every other config never looks
  # at the state directory for it.
  local instances="${3:-}" expanded
  if [ -z "$instances" ]; then
    if printf '%s' "$interpolated" | jq -e '.schema_version == 6 and has("peers")' >/dev/null 2>&1; then
      instances="$(sw_read_instances "$pid")"
    else
      instances='{}'
    fi
  fi
  expanded="$(sw_apply_instances "$interpolated" "$instances")" || return 1
  # A second argument replaces the stored labels (workspace-label.sh checks a
  # candidate label this way before it writes one).
  sw_apply_worker_names "$expanded" "${2:-$(sw_read_worker_labels "$pid")}"
}

# sw_worker_labels_path PROJECT_ID — the project state file holding each
# environment's worker label ({"<environment id>": "<label>"}).
sw_worker_labels_path() {
  printf '%s/session-workspace/%s/labels.json\n' "${XDG_STATE_HOME:-$HOME/.local/state}" "$1"
}

SW_WORKER_LABEL_RE='^[a-z0-9][a-z0-9-]{0,23}$'

# sw_read_worker_labels PROJECT_ID — the valid entries of labels.json as one
# JSON object; {} when the file is missing, unreadable or not an object.
sw_read_worker_labels() {
  local pid="$1" path
  case "$pid" in
    ''|*/*|.|..) printf '{}'; return 0 ;;
  esac
  path="$(sw_worker_labels_path "$pid")"
  if [ ! -f "$path" ] || [ -L "$path" ]; then
    printf '{}'
    return 0
  fi
  jq -c --arg re "$SW_WORKER_LABEL_RE" '
    if type == "object" then with_entries(select((.value | type) == "string" and (.value | test($re)))) else {} end
  ' "$path" 2>/dev/null || printf '{}'
}

# sw_state_home — the state home the peers engine uses: $XDG_STATE_HOME when it
# is absolute, else $HOME/.local/state (a relative value is ignored, as the XDG
# spec says). Every pane of a peers workspace is launched with this value, so
# the engine and the hook in any cwd read one instances.json.
sw_state_home() {
  case "${XDG_STATE_HOME:-}" in
    /*) printf '%s\n' "$XDG_STATE_HOME" ;;
    *) printf '%s\n' "$HOME/.local/state" ;;
  esac
}

# sw_instances_path PROJECT_ID — the project state file holding the peer
# orchestrators and the workers the engine started (see the header).
sw_instances_path() {
  printf '%s/session-workspace/%s/instances.json\n' "$(sw_state_home)" "$1"
}

# sw_read_instances PROJECT_ID — the shape-valid records of instances.json as
# {"version":1,"orchestrators":[{index}],"workers":[{checkout,role,label,owner,visible}]}.
# A missing, symlinked, unreadable or malformed file gives the empty form, and
# a record keeps only its known keys, so nothing else passes through.
sw_read_instances() {
  local pid="$1" path empty='{"version":1,"orchestrators":[],"workers":[]}'
  case "$pid" in
    ''|*/*|.|..) printf '%s' "$empty"; return 0 ;;
  esac
  path="$(sw_instances_path "$pid")"
  if [ ! -f "$path" ] || [ -L "$path" ]; then
    printf '%s' "$empty"
    return 0
  fi
  jq -c --arg re "$SW_WORKER_LABEL_RE" '
    if type == "object" then
      {version: 1,
       orchestrators: [((.orchestrators // []) | arrays | .[])
         | select(type == "object" and (.index | type) == "number" and .index == (.index | floor) and .index >= 2 and .index <= 999)
         | {index}],
       workers: [((.workers // []) | arrays | .[])
         | select(type == "object"
             and (.checkout | type) == "string" and (.owner | type) == "string"
             and (.role == "executor" or .role == "reviewer")
             and (.["label"] | type) == "string" and (.["label"] == "" or (.["label"] | test($re)))
             and (.visible | type) == "boolean")
         | {checkout, role, "label": .["label"], owner, visible}]}
    else {version: 1, orchestrators: [], workers: []} end
  ' "$path" 2>/dev/null || printf '%s' "$empty"
}

# sw_apply_instances CONFIG_JSON INSTANCES_JSON — expand a schema-v6 peers
# config: the declared peers session becomes instance 1, each recorded
# orchestrator index gets a copy of it (id, name and pane names suffixed -N),
# and each recorded worker becomes an on-demand pane in its owner's session.
# A record of the wrong shape (the same rules as sw_read_instances, so a
# candidate passed by the engine is judged as the stored file is), or one that
# names an unknown checkout or owner, or repeats a worker, is skipped
# silently. Any other config is returned unchanged.
sw_apply_instances() {
  printf '%s' "$1" | jq -c --argjson inst "${2:-"{}"}" --arg re "$SW_WORKER_LABEL_RE" '
    . as $original
    | try ((.peers.session // null) as $ps
      | if .schema_version == 6 and ((.peers // null) | type) == "object" and ($ps | type) == "string"
         and ((.sessions // null) | type) == "array" and any(.sessions[]; type == "object" and .id == $ps)
         and ((.harness.roles // null) | type) == "object" and ((.environments // null) | type) == "array"
      then
        .project.id as $pid
        | .harness.roles as $roles
        | ([.environments[] | select(type == "object" and (.id | type) == "string" and (.cwd | type) == "string") | {key: .id, value: .cwd}] | from_entries) as $cwds
        | ([.sessions[] | select(type == "object" and .id == $ps)][0]) as $decl
        | ([($inst.orchestrators // [])[]? | select(type == "object") | .index
            | select(type == "number" and . == floor and . >= 2 and . <= 999)] | unique) as $indexes
        | .sessions |= [.[] | if type == "object" and .id == $ps then
            (. + {instance: {of: $ps, index: 1}}),
            ($indexes[] as $n | $decl
              | .id = (.id + "-" + ($n | tostring))
              | .name = (.name + "-" + ($n | tostring))
              | .panes |= map(.name = (.name + "-" + ($n | tostring)))
              | .instance = {of: $ps, index: $n})
          else . end]
        | ([.sessions[] | select(type == "object") | .id as $sid | (.panes // [])[] | select(.role == $roles.orchestrator) | {key: .name, value: $sid}] | from_entries) as $owners
        | (reduce (($inst.workers // [])[]? | select(type == "object")) as $w ({seen: [], sessions: .sessions};
            ("worker:" + ([$w.checkout, $w.role, $w["label"]] | tojson)) as $key
            | if ($w.checkout | type) == "string" and ($cwds[$w.checkout] // null) != null
                 and ($w.role == "executor" or $w.role == "reviewer")
                 and ($w["label"] | type) == "string" and ($w["label"] == "" or ($w["label"] | test($re)))
                 and ($w.owner | type) == "string" and ($owners[$w.owner] // null) != null
                 and ($w.visible | type) == "boolean"
                 and (.seen | index($key)) == null
              then
                .seen += [$key]
                | .sessions |= map(if type == "object" and .id == $owners[$w.owner] then
                    .panes += [{
                      name: ($pid + "-" + $w.checkout + "-" + $w.role + (if $w["label"] == "" then "" else "-" + $w["label"] end)),
                      role: $roles[$w.role],
                      cwd: $cwds[$w.checkout],
                      launch: "on_demand",
                      worker: {checkout: $w.checkout, role: $w.role, "label": $w["label"], owner: $w.owner, visible: $w.visible}
                    }]
                  else . end)
              else . end))
          as $built
        | .sessions = $built.sessions
        | .environments |= map(if type == "object" and (has("development") | not) then . + {development: []} else . end)
      else . end)
      # A config too malformed to expand is passed on unchanged, so validation reports it.
      catch $original
  '
}

# sw_apply_worker_names CONFIG_JSON LABELS_JSON — fill the name of every
# unnamed executor/reviewer pane of a schema-v5 or v6 environment's development
# sessions. Anything else is returned unchanged; an unnamed pane elsewhere
# stays unnamed and fails validation as before.
sw_apply_worker_names() {
  printf '%s' "$1" | jq -c --argjson labels "${2:-"{}"}" '
    if (.schema_version == 5 or .schema_version == 6) and ((.project.id // "") | type) == "string" and (.project.id // "") != ""
       and ((.harness.roles // null) | type) == "object" and ((.environments // null) | type) == "array" then
      .project.id as $pid
      | .harness.roles as $roles
      | [.environments[] | select(type == "object") | {id, development: (.development // [])}] as $envs
      | .sessions |= ((. // []) | map(
          . as $session
          | ([$envs[] | select((.development | type) == "array" and (.development | index($session.id)) != null)][0]) as $env
          | if $env == null or ($env.id | type) != "string" then .
            else .panes |= ((. // []) | map(
              if type != "object" or has("name") then .
              elif .role == $roles.executor or .role == $roles.reviewer then
                .name = ($pid + "-" + $env.id + "-" + (if .role == $roles.executor then "executor" else "reviewer" end)
                         + (($labels[$env.id] // "") | if . == "" then "" else "-" + . end))
              else . end))
            end))
    else . end
  '
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  library_not_executable "config.sh"
fi
