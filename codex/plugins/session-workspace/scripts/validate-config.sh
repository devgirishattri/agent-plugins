#!/usr/bin/env bash
# validate-config.sh — full validation of .agent-workspace/workspace.json.
#
# Two halves:
#   1. validate-structural.jq — pure-jq structural checks (unknown/missing
#      keys, argv-vs-string commands, name uniqueness/charset, split_tree
#      node/pane_order rules, env var name/value rules, coordination-var
#      rejection, grants-vs-pin, per-pane memory naming, permission_mode
#      allowlist). See that file for the full rule list.
#   2. this script — filesystem-dependent checks a pure jq filter cannot do:
#      cwd path/symlink escape and the secrets.env_file gates (location,
#      mode, ownership, symlink, git-ignore).
#
# Usage: validate-config.sh [--config PATH] [--json]
#   Exit 0 and (on success) prints nothing (or `{"valid":true,"errors":[]}`
#   with --json). Exit 1 with every violation printed to stderr (or on
#   stdout as JSON with --json).
#
# Library use: source this file, then call
#   validate_workspace_config "$INTERPOLATED_JSON" "$CONFIG_PATH"
# which populates the VALIDATION_ERRORS bash array and returns 0/1.
set -uo pipefail

# Resolve this library's own directory from ${BASH_SOURCE[0]}, never $0:
# this file is SOURCED, so $0 belongs to the caller — and for a `bash -c`
# or `bash -s` caller $0 is literally "bash", which resolved the sibling
# library against $PWD and broke depending on the working directory.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

VALIDATION_ERRORS=()

_add_error() { VALIDATION_ERRORS+=("$1"); }

print_validation_errors() {
  local e
  for e in "${VALIDATION_ERRORS[@]}"; do
    echo "  - $e" >&2
  done
}

# _resolve_cwd_within_root PROJECT_ROOT_ABS CWD_REL_OR_ABS
# Prints the canonicalized cwd on stdout if it exists AND resolves (through
# any symlinks) to a path inside PROJECT_ROOT_ABS. Prints nothing and
# returns 1 otherwise. Uses `cd ... && pwd -P` (never realpath, per the
# defect list: realpath is absent on older stock macOS) so both plain
# path-escape ("../../etc") and symlink-escape ("looks-local -> /etc") are
# caught the same way: pwd -P always returns the physically resolved path.
_resolve_cwd_within_root() {
  local root_abs="$1" cwd_raw="$2" candidate resolved
  case "$cwd_raw" in
    /*) candidate="$cwd_raw" ;;
    *) candidate="$root_abs/$cwd_raw" ;;
  esac
  resolved="$(canonicalize_dir "$candidate")" || return 1
  [ -n "$resolved" ] || return 1
  case "$resolved" in
    "$root_abs") printf '%s\n' "$resolved"; return 0 ;;
    "$root_abs"/*) printf '%s\n' "$resolved"; return 0 ;;
    *) return 1 ;;
  esac
}

# _validate_cwds JSON PROJECT_ROOT_ABS
# Every pane's cwd (when present) must resolve inside the project root.
# Missing directories are reported unless the pane is optional=true (an
# optional child repo that has not been cloned yet is not a config error).
_validate_cwds() {
  local json="$1" root_abs="$2"
  local rows pane_name cwd_rel optional resolved
  rows="$(printf '%s' "$json" | jq -r '
    (.sessions // [])[] | (.panes // [])[]
    | select(has("cwd"))
    | [(.name // "?"), .cwd, ((.optional // false) | tostring)]
    | @tsv
  ')"
  [ -z "$rows" ] && return 0
  while IFS=$'\t' read -r pane_name cwd_rel optional; do
    [ -z "$pane_name" ] && continue
    if resolved="$(_resolve_cwd_within_root "$root_abs" "$cwd_rel")"; then
      continue
    fi
    if [ "$optional" = "true" ]; then
      continue
    fi
    _add_error "pane $pane_name: cwd \"$cwd_rel\" does not resolve inside the project root ($root_abs) -- it is missing, or escapes the root via \"..\" or a symlink"
  done <<<"$rows"
}

# _validate_harness_resolved_cwds JSON PROJECT_ROOT_ABS
# Structural validation rejects a literal "." for executor/reviewer panes.
# This filesystem half closes the alias/symlink form of the same hole: an
# apparently non-dot child cwd must not canonicalize back to the project root.
_validate_harness_resolved_cwds() {
  local json="$1" root_abs="$2"
  if ! printf '%s' "$json" | jq -e '.schema_version == 2 and (.harness.enabled // false)' >/dev/null; then
    return 0
  fi

  local executor_role reviewer_role rows pane_name role_name cwd_raw resolved
  executor_role="$(printf '%s' "$json" | jq -r '.harness.roles.executor')"
  reviewer_role="$(printf '%s' "$json" | jq -r '.harness.roles.reviewer')"
  rows="$(printf '%s' "$json" | jq -r --arg executor "$executor_role" --arg reviewer "$reviewer_role" '
    .sessions[] | .panes[]
    | select(.role == $executor or .role == $reviewer)
    | [(.name // "?"), .role, (.cwd // "")] | @tsv
  ')"
  while IFS=$'\t' read -r pane_name role_name cwd_raw; do
    [ -z "$pane_name" ] && continue
    if resolved="$(_resolve_cwd_within_root "$root_abs" "$cwd_raw")" && [ "$resolved" = "$root_abs" ]; then
      _add_error "harness $role_name pane $pane_name: cwd \"$cwd_raw\" resolves to the project root; executor/reviewer panes require a distinct child cwd"
    fi
  done <<<"$rows"
}

# _lexical_normalize_path BASE_ABS RAW -> prints an absolute path with every
# "." and ".." segment collapsed TEXTUALLY (no filesystem access), for RAW
# interpreted relative to BASE_ABS when RAW is not itself absolute. Unlike
# _resolve_cwd_within_root, this never requires the result to exist -- a
# coordination store directory (stores.base, stores.overrides.*,
# stores.memory.root) is routinely created lazily, on first write, by
# another plugin (session-chat/session-scheduler/knowledge), so requiring
# existence at validate time would reject every fresh project. This alone
# already rejects a lexical escape like "../../.." or an absolute override
# outside the root, even before anything on disk exists.
_lexical_normalize_path() {
  local base_abs="$1" raw="$2" combined
  case "$raw" in
    /*) combined="$raw" ;;
    *) combined="$base_abs/$raw" ;;
  esac
  local part
  local stack=()
  local old_ifs="$IFS"
  IFS='/'
  for part in $combined; do
    case "$part" in
      '' | '.') continue ;;
      '..')
        if [ "${#stack[@]}" -gt 0 ]; then
          unset "stack[$(( ${#stack[@]} - 1 ))]"
          stack=("${stack[@]}")
        fi
        ;;
      *) stack+=("$part") ;;
    esac
  done
  IFS="$old_ifs"
  local out="" seg
  for seg in "${stack[@]:-}"; do
    [ -n "$seg" ] && out="$out/$seg"
  done
  [ -z "$out" ] && out="/"
  printf '%s\n' "$out"
}

# _resolve_store_path_within_root ROOT_ABS RAW
# Containment check for a coordination-store path that may not exist yet
# (see _lexical_normalize_path). Two layers must both agree the result stays
# inside ROOT_ABS:
#   1. Lexical (always) -- rejects "../../.." and any absolute path outside
#      root outright, with no filesystem access.
#   2. Physical, for whichever leading portion currently exists on disk --
#      canonicalized with `cd ... && pwd -P` (never realpath, same primitive
#      as _resolve_cwd_within_root), so a symlink planted at any EXISTING
#      ancestor cannot smuggle the store outside root either. The
#      non-existent trailing segments were already lexically clean (no ".."
#      survives step 1), so they cannot reintroduce an escape once created.
# Prints the normalized path and returns 0, or returns 1 with nothing printed.
_resolve_store_path_within_root() {
  local root_abs="$1" raw="$2" normalized
  normalized="$(_lexical_normalize_path "$root_abs" "$raw")" || return 1
  case "$normalized" in
    "$root_abs") : ;;
    "$root_abs"/*) : ;;
    *) return 1 ;;
  esac

  local probe="$normalized"
  while [ ! -d "$probe" ] && [ "$probe" != "/" ]; do
    probe="$(dirname "$probe")"
  done
  [ -d "$probe" ] || return 1

  local phys
  phys="$(canonicalize_dir "$probe")" || return 1
  [ -n "$phys" ] || return 1
  case "$phys" in
    "$root_abs") : ;;
    "$root_abs"/*) : ;;
    *) return 1 ;;
  esac

  printf '%s\n' "$normalized"
  return 0
}

# _validate_stores JSON PROJECT_ROOT_ABS
# stores.base, every stores.overrides.* value, and stores.memory.root must
# all resolve inside the project root -- they become SESSION_*_HOME exports
# and --add-dir grants (the agent's filesystem authorization boundary), so an
# unchecked "../../.." or an absolute override outside root would grant
# access far beyond the project.
_validate_stores() {
  local json="$1" root_abs="$2"

  local base
  base="$(printf '%s' "$json" | jq -r '.stores.base // ".tmp"')"
  if ! _resolve_store_path_within_root "$root_abs" "$base" >/dev/null; then
    _add_error "stores.base (\"$base\") does not resolve inside the project root ($root_abs) -- it escapes via \"..\" or an absolute path/symlink outside the root"
  fi

  local rows store_name override_path
  rows="$(printf '%s' "$json" | jq -r '.stores.overrides // {} | to_entries[] | [.key, .value] | @tsv')"
  if [ -n "$rows" ]; then
    while IFS=$'\t' read -r store_name override_path; do
      [ -z "$store_name" ] && continue
      if ! _resolve_store_path_within_root "$root_abs" "$override_path" >/dev/null; then
        _add_error "stores.overrides.$store_name (\"$override_path\") does not resolve inside the project root ($root_abs) -- it escapes via \"..\" or an absolute path/symlink outside the root"
      fi
    done <<<"$rows"
  fi

  local mem_root
  mem_root="$(printf '%s' "$json" | jq -r '.stores.memory.root // empty')"
  if [ -n "$mem_root" ]; then
    if ! _resolve_store_path_within_root "$root_abs" "$mem_root" >/dev/null; then
      _add_error "stores.memory.root (\"$mem_root\") does not resolve inside the project root ($root_abs) -- it escapes via \"..\" or an absolute path/symlink outside the root"
    fi
  fi
}

# _validate_secrets_file JSON PROJECT_ROOT_ABS CONFIG_DIR
# secrets.env_file (when set) must: resolve inside root, be mode 0600,
# be owned by the current user, not be a symlink, and be git-ignored.
_validate_secrets_file() {
  local json="$1" root_abs="$2"
  local env_file
  env_file="$(printf '%s' "$json" | jq -r '.secrets.env_file // empty')"
  [ -z "$env_file" ] && return 0

  local candidate resolved_parent base full
  case "$env_file" in
    /*) full="$env_file" ;;
    *) full="$root_abs/$env_file" ;;
  esac
  base="$(basename "$full")"
  candidate="$(dirname "$full")"

  if [ -L "$full" ]; then
    _add_error "secrets.env_file ($env_file) must not be a symlink"
    return 0
  fi
  if [ ! -f "$full" ]; then
    _add_error "secrets.env_file ($env_file) does not exist at $full"
    return 0
  fi

  resolved_parent="$(canonicalize_dir "$candidate")"
  if [ -z "$resolved_parent" ]; then
    _add_error "secrets.env_file ($env_file): containing directory does not resolve"
    return 0
  fi
  local resolved_full="$resolved_parent/$base"
  case "$resolved_full" in
    "$root_abs"/*|"$root_abs") ;;
    *) _add_error "secrets.env_file ($env_file) must resolve inside the project root ($root_abs)" ;;
  esac

  local mode
  # GNU-first: GNU stat's -f is a FILESYSTEM report, so a BSD-first probe can
  # emit report text before the fallback runs and corrupt the substitution.
  # BSD stat rejects -c cleanly on macOS, so this order is safe on both.
  mode="$(stat -c '%a' "$full" 2>/dev/null || stat -f '%Lp' "$full" 2>/dev/null)"
  if [ "$mode" != "600" ]; then
    _add_error "secrets.env_file ($env_file) must be mode 0600 (got: ${mode:-unknown})"
  fi

  local owner_uid
  owner_uid="$(stat -c '%u' "$full" 2>/dev/null || stat -f '%u' "$full" 2>/dev/null)"
  if [ -n "$owner_uid" ] && [ "$owner_uid" != "$(id -u)" ]; then
    _add_error "secrets.env_file ($env_file) must be owned by the current user (uid $(id -u)), got uid $owner_uid"
  fi

  if command -v git >/dev/null 2>&1 && git -C "$root_abs" rev-parse --git-dir >/dev/null 2>&1; then
    local rel_to_root="${resolved_full#"$root_abs"/}"
    if ! git -C "$root_abs" check-ignore -q -- "$rel_to_root" 2>/dev/null; then
      _add_error "secrets.env_file ($env_file) must be git-ignored (add it to .gitignore)"
    fi
  else
    _add_error "secrets.env_file ($env_file) could not be checked for git-ignore status -- project root ($root_abs) is not a git repository"
  fi
}

# validate_workspace_config JSON CONFIG_PATH
# JSON must already be token-interpolated (see config.sh's
# load_workspace_config_raw). Populates VALIDATION_ERRORS; returns 0 if
# empty, 1 otherwise.
validate_workspace_config() {
  local json="$1" config_path="$2"
  VALIDATION_ERRORS=()

  if ! printf '%s' "$json" | jq empty >/dev/null 2>&1; then
    _add_error "config is not valid JSON"
    return 1
  fi

  local here structural_out rc
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  structural_out="$(printf '%s' "$json" | jq -c -f "$here/validate-structural.jq" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    _add_error "structural validation crashed: $structural_out"
    return 1
  fi
  if [ -n "$structural_out" ] && [ "$structural_out" != "[]" ]; then
    local msg
    while IFS= read -r msg; do
      [ -n "$msg" ] && _add_error "$msg"
    done < <(printf '%s' "$structural_out" | jq -r '.[]')
  fi

  # Filesystem-dependent checks need an on-disk project root. project.root
  # was already interpolated relative to the config file's directory by
  # config.sh; recompute it here defensively in case validate-config.sh is
  # invoked with raw (non-interpolated) JSON in a future caller.
  local cfg_dir root_rel root_abs
  cfg_dir="$(config_base_dir "$config_path")"
  root_rel="$(printf '%s' "$json" | jq -r '.project.root // "."')"
  root_abs="$(canonicalize_dir "$cfg_dir/$root_rel")"
  if [ -z "$root_abs" ]; then
    _add_error "project.root (\"$root_rel\") does not resolve to an existing directory relative to $cfg_dir"
  else
    _validate_cwds "$json" "$root_abs"
    _validate_harness_resolved_cwds "$json" "$root_abs"
    _validate_stores "$json" "$root_abs"
    _validate_secrets_file "$json" "$root_abs"
  fi

  [ "${#VALIDATION_ERRORS[@]}" -eq 0 ]
}

_run_cli() {
  local config_override="" json_mode=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --config) config_override="${2:-}"; shift 2 ;;
      --json) json_mode=1; shift ;;
      -h|--help)
        echo "Usage: validate-config.sh [--config PATH] [--json]"
        return 0
        ;;
      *)
        echo "ERROR: unknown argument: $1" >&2
        return 1
        ;;
    esac
  done

  ensure_jq

  local path json
  path="$(resolve_project_config_path "$config_override")" || return 1
  json="$(load_workspace_config_raw "$path")" || return 1

  local ok=0
  validate_workspace_config "$json" "$path" || ok=1

  if [ "$json_mode" -eq 1 ]; then
    local errs_json
    errs_json="$(printf '%s\n' "${VALIDATION_ERRORS[@]:-}" | jq -R -s 'split("\n") | map(select(length > 0))')"
    jq -n --argjson valid "$([ $ok -eq 0 ] && echo true || echo false)" --argjson errors "$errs_json" --arg config "$path" \
      '{valid: $valid, config: $config, errors: $errors}'
  else
    if [ "$ok" -eq 0 ]; then
      echo "OK: $path is valid (schema_version $(printf '%s' "$json" | jq -r '.schema_version'))"
    else
      echo "ERROR: $path failed validation:" >&2
      print_validation_errors
    fi
  fi

  return "$ok"
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  _run_cli "$@"
  exit $?
fi
