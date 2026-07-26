#!/usr/bin/env bash
# workspace-doctor.sh — session-workspace 'doctor' verb (Phase F).
#
# STRICTLY READ-ONLY. This script diagnoses; it never repairs, creates,
# moves, or kills anything. It must not create the state directory, must not
# start/stop/attach a tmux session, must not touch the coordination stores,
# and must not write anywhere in the project tree or the plugin tree. Every
# probe below is a stat, a directory listing, or a `command -v` — this file
# never executes a config-supplied program (see check_runtimes: only
# `command -v` resolution is reported, never `"$program" --version`, because
# runtimes.<key>.program is fully config-controlled and ungated -- only the
# runtime *key* is a case-matched literal, not the program path itself).
#
# Every check after config.validation additionally requires that config
# validation actually PASSED ($CONFIG_VALID = 1): a config that failed
# validation cannot be trusted to drive filesystem-touching or command
# probes (a malformed stores.base, an unresolved project.root, etc.), so
# every post-config check is skipped rather than run against unvalidated
# data.
#
# Checks (each reports OK / INFO / WARN / ERROR):
#   tooling.tmux        tmux present, and >= 3.2 (the floor this engine has
#                       always required; `respawn-pane -e` per-pane secret
#                       delivery and `-l <pct>%` splits both need it)
#   tooling.jq          jq present
#   tooling.git         git present (needed for the secrets git-ignore gate)
#   config.discovery    a config was found via --config / $SESSION_WORKSPACE_CONFIG
#                       / the upward directory walk
#   config.validation   full validate-config.sh passes; every error surfaced
#   plugins.<name>      knowledge / session-chat / session-scheduler are
#                       installed at or above their required version, and the
#                       installed cache does not drift from the source tree.
#                       (session-context is deliberately NOT checked — that
#                       plugin no longer exists; it was absorbed into
#                       knowledge.)
#   panes.cwd           every configured pane's cwd resolves inside the project
#                       root; a missing `optional: true` dir is INFO, not ERROR
#   secrets.env_file    presence, mode 0600, owner, non-symlink, git-ignored.
#                       NEVER reads or prints a secret VALUE — only metadata.
#   state.dir           the project state dir is writable with owner-only perms
#   runtime.<name>      each configured runtime's program is on PATH
#   stores.drift        ledger-shaped files under a coordination base OTHER
#                       than the configured one (probes the tmp/ and .tmp/
#                       siblings) — the generalized form of the one-off
#                       stale-default migration
#   integrations.session_chat_helper
#                       whether the session-chat helper resolves, its version,
#                       and whether behavior.session_chat_helper.on_missing
#                       would fail or warn
#
# Usage: workspace-doctor.sh [--config PATH] [--json]
# Exit status: non-zero if any check is ERROR. WARN alone exits 0.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"

usage() {
  echo "Usage: workspace-doctor.sh [--config PATH] [--json]" >&2
}

CONFIG_OVERRIDE=""
JSON_MODE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_OVERRIDE="${2:-}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

# ============================================================================
# Check accumulator — Bash 3.2 has no associative arrays, so these are six
# parallel arrays indexed together. CHECK_DETAILS holds newline-separated
# lines for one check.
# ============================================================================
CHECK_IDS=()
CHECK_LABELS=()
CHECK_STATUSES=()
CHECK_MESSAGES=()
CHECK_REMEDIATIONS=()
CHECK_DETAILS=()

ERROR_COUNT=0
WARN_COUNT=0

# add_check ID LABEL STATUS MESSAGE [REMEDIATION] [DETAILS]
add_check() {
  CHECK_IDS+=("$1")
  CHECK_LABELS+=("$2")
  CHECK_STATUSES+=("$3")
  CHECK_MESSAGES+=("$4")
  CHECK_REMEDIATIONS+=("${5:-}")
  CHECK_DETAILS+=("${6:-}")
  case "$3" in
    ERROR) ERROR_COUNT=$((ERROR_COUNT + 1)) ;;
    WARN) WARN_COUNT=$((WARN_COUNT + 1)) ;;
  esac
}

_status_rank() {
  case "$1" in
    OK) echo 0 ;;
    INFO) echo 1 ;;
    WARN) echo 2 ;;
    ERROR) echo 3 ;;
    *) echo 0 ;;
  esac
}

# worse A B — prints the more severe of two statuses (OK < INFO < WARN < ERROR).
worse() {
  if [ "$(_status_rank "$1")" -ge "$(_status_rank "$2")" ]; then
    printf '%s' "$1"
  else
    printf '%s' "$2"
  fi
}

# ============================================================================
# 1. Required tooling
# ============================================================================

# tmux >= 3.2 is the floor this engine requires: `respawn-pane -e` (per-pane
# secret delivery straight into the new process's environment, never via
# send-keys and never via session-scope `set-environment`, which is reserved
# for the NON-secret env.groups.*.pin_to_session mirror) and `-l <pct>%`
# splits.
TMUX_MIN_VERSION="3.2"

check_tooling_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    add_check "tooling.tmux" "tmux" "ERROR" "tmux is not on PATH" \
      "Install tmux: brew install tmux (macOS) or apt install tmux (Ubuntu)"
    return 0
  fi
  local raw ver
  raw="$(tmux -V 2>/dev/null)"
  # "tmux 3.6b" -> "3.6b"
  ver="${raw##* }"
  if [ -z "$ver" ] || [ "$ver" = "$raw" ]; then
    add_check "tooling.tmux" "tmux" "WARN" \
      "tmux is installed but its version could not be read (tmux -V said: ${raw:-nothing})" \
      "Run 'tmux -V' by hand; session-workspace needs >= $TMUX_MIN_VERSION for per-pane secret delivery and non-deprecated splits"
    return 0
  fi
  if sw_version_ge "$ver" "$TMUX_MIN_VERSION"; then
    add_check "tooling.tmux" "tmux" "OK" "tmux $ver (>= $TMUX_MIN_VERSION)"
  else
    add_check "tooling.tmux" "tmux" "ERROR" \
      "tmux $ver is below the required >= $TMUX_MIN_VERSION" \
      "Upgrade tmux to >= $TMUX_MIN_VERSION."
  fi
}

check_tooling_jq() {
  if command -v jq >/dev/null 2>&1; then
    local ver
    ver="$(jq --version 2>/dev/null)"
    add_check "tooling.jq" "jq" "OK" "${ver:-jq present}"
    return 0
  fi
  add_check "tooling.jq" "jq" "ERROR" "jq is not on PATH" \
    "Install jq: brew install jq (macOS) or apt install jq (Ubuntu). The engine parses workspace.json with jq; nothing else works without it."
}

check_tooling_git() {
  if command -v git >/dev/null 2>&1; then
    local ver
    ver="$(git --version 2>/dev/null)"
    add_check "tooling.git" "git" "OK" "${ver:-git present}"
    return 0
  fi
  add_check "tooling.git" "git" "WARN" "git is not on PATH" \
    "Install git. Without it the secrets.env_file git-ignore gate cannot be verified."
}

# ============================================================================
# 2. Plugin dependencies and versions
# ============================================================================

# Required floors. session-context is deliberately absent from this list: it
# no longer exists as a plugin (absorbed into knowledge).
REQUIRED_PLUGIN_NAMES=(knowledge session-chat session-scheduler)
REQUIRED_PLUGIN_VERSIONS=(0.3.2 0.17.0 0.5.0)

# Sibling-plugin resolution (sw_newest_cache_root / sw_source_tree_root /
# sw_plugin_manifest_version / sw_session_chat_helper_root) lives in lib.sh:
# workspace-start.sh GATES on the same resolution this file REPORTS on, and a
# second copy here could drift from it.

check_plugin_deps() {
  local i n name required cache_root cache_ver src_root src_ver
  local status message remediation details effective
  n="${#REQUIRED_PLUGIN_NAMES[@]}"
  i=0
  while [ "$i" -lt "$n" ]; do
    name="${REQUIRED_PLUGIN_NAMES[$i]}"
    required="${REQUIRED_PLUGIN_VERSIONS[$i]}"
    i=$((i + 1))

    cache_root="$(sw_newest_cache_root "$name")"
    cache_ver=""
    [ -n "$cache_root" ] && cache_ver="$(sw_plugin_manifest_version "$cache_root")"
    src_root="$(sw_source_tree_root "$name")" || src_root=""
    src_ver=""
    [ -n "$src_root" ] && src_ver="$(sw_plugin_manifest_version "$src_root")"

    details=""
    [ -n "$cache_root" ] && details="installed: ${cache_ver:-unknown} ($cache_root)"
    if [ -n "$src_root" ]; then
      [ -n "$details" ] && details="$details
"
      details="${details}source tree: ${src_ver:-unknown} ($src_root)"
    fi

    if [ -z "$cache_ver" ] && [ -z "$src_ver" ]; then
      add_check "plugins.$name" "$name" "ERROR" \
        "$name is not installed (required >= $required)" \
        "Install it: claude plugin install $name@girishattri-plugins  (or: codex plugin add $name@girishattri-plugins)" \
        "$details"
      continue
    fi

    effective="$cache_ver"
    [ -z "$effective" ] && effective="$src_ver"

    status="OK"
    message="$name $effective (required >= $required)"
    remediation=""
    if ! sw_version_ge "$effective" "$required"; then
      status="ERROR"
      message="$name $effective is BELOW the required >= $required"
      remediation="Update $name to >= $required."
    fi

    # Drift: an installed cache that disagrees with the source checkout this
    # engine was launched from means panes will run a different version than
    # the tree being edited.
    if [ -n "$cache_ver" ] && [ -n "$src_ver" ] && [ "$cache_ver" != "$src_ver" ]; then
      status="$(worse "$status" "WARN")"
      message="$message; installed cache ($cache_ver) drifts from source tree ($src_ver)"
      if [ -z "$remediation" ]; then
        remediation="Reinstall $name so the cached install matches the source tree, or ignore if the drift is intentional."
      fi
    fi

    add_check "plugins.$name" "$name" "$status" "$message" "$remediation" "$details"
  done
}

# ============================================================================
# 3. Config discovery + validation (needs jq)
# ============================================================================
CONFIG_PATH=""
CONFIG_JSON=""
ROOT_ABS=""
# 1 only once config discovery AND full validate_workspace_config both
# succeed. Every check after config.validation gates on this, not merely on
# "$CONFIG_JSON is non-empty" -- a config that failed validation may still
# parse as JSON (CONFIG_JSON non-empty) but must not drive any further
# filesystem/command probe.
CONFIG_VALID=0

check_config() {
  if ! command -v jq >/dev/null 2>&1; then
    add_check "config.discovery" "config discovery" "ERROR" \
      "skipped — jq is not installed, so the config cannot be parsed" \
      "Install jq, then re-run workspace-doctor."
    return 0
  fi

  # config.sh / validate-config.sh are sourced lazily so a missing jq still
  # produces a useful tooling report instead of a hard failure.
  source "$HERE/config.sh"
  source "$HERE/validate-config.sh"

  local resolved discovery_err
  if ! resolved="$(resolve_project_config_path "$CONFIG_OVERRIDE" 2>/dev/null)"; then
    discovery_err="$(resolve_project_config_path "$CONFIG_OVERRIDE" 2>&1 >/dev/null)"
    add_check "config.discovery" "config discovery" "ERROR" \
      "no session-workspace config found" \
      "Pass --config PATH, set \$SESSION_WORKSPACE_CONFIG, or create .agent-workspace/workspace.json at the project root." \
      "$discovery_err"
    return 0
  fi
  CONFIG_PATH="$resolved"
  add_check "config.discovery" "config discovery" "OK" "$CONFIG_PATH"

  local load_err
  if ! CONFIG_JSON="$(load_workspace_config_raw "$CONFIG_PATH" 2>/dev/null)"; then
    load_err="$(load_workspace_config_raw "$CONFIG_PATH" 2>&1 >/dev/null)"
    CONFIG_JSON=""
    add_check "config.validation" "config validation" "ERROR" \
      "config could not be loaded" \
      "Fix the JSON syntax in $CONFIG_PATH." \
      "$load_err"
    return 0
  fi

  if validate_workspace_config "$CONFIG_JSON" "$CONFIG_PATH"; then
    CONFIG_VALID=1
    add_check "config.validation" "config validation" "OK" \
      "$CONFIG_PATH is valid (schema_version 1)"
  else
    local joined="" e
    for e in "${VALIDATION_ERRORS[@]}"; do
      [ -n "$joined" ] && joined="$joined
"
      joined="$joined$e"
    done
    add_check "config.validation" "config validation" "ERROR" \
      "${#VALIDATION_ERRORS[@]} validation error(s)" \
      "Fix every error listed above in $CONFIG_PATH; validate-config.sh prints the same list." \
      "$joined"
  fi

  local root_rel cfg_dir
  cfg_dir="$(config_base_dir "$CONFIG_PATH")"
  root_rel="$(printf '%s' "$CONFIG_JSON" | jq -r '.project.root // "."')"
  ROOT_ABS="$(canonicalize_dir "$cfg_dir/$root_rel")"
}

# ============================================================================
# 4. Pane cwds
# ============================================================================
check_pane_cwds() {
  [ -n "$CONFIG_JSON" ] || return 0
  [ "$CONFIG_VALID" -eq 1 ] || return 0
  if [ -z "$ROOT_ABS" ]; then
    add_check "panes.cwd" "pane cwds" "ERROR" \
      "project.root does not resolve to an existing directory" \
      "Fix project.root in $CONFIG_PATH."
    return 0
  fi

  local rows status="OK" details="" pane_name cwd_rel optional
  local n_ok=0 n_skip=0 n_bad=0 remediation=""
  rows="$(printf '%s' "$CONFIG_JSON" | jq -r '
    (.sessions // [])[] | (.panes // [])[]
    | select(has("cwd"))
    | [(.name // "?"), .cwd, ((.optional // false) | tostring)]
    | @tsv
  ')"

  if [ -z "$rows" ]; then
    add_check "panes.cwd" "pane cwds" "OK" "no pane declares a cwd"
    return 0
  fi

  while IFS=$'\t' read -r pane_name cwd_rel optional; do
    [ -z "$pane_name" ] && continue
    if _resolve_cwd_within_root "$ROOT_ABS" "$cwd_rel" >/dev/null; then
      n_ok=$((n_ok + 1))
      continue
    fi
    [ -n "$details" ] && details="$details
"
    if [ "$optional" = "true" ]; then
      n_skip=$((n_skip + 1))
      details="${details}INFO  $pane_name: optional cwd \"$cwd_rel\" is absent — that pane will be skipped"
      status="$(worse "$status" "INFO")"
    else
      n_bad=$((n_bad + 1))
      details="${details}ERROR $pane_name: cwd \"$cwd_rel\" does not resolve inside the project root ($ROOT_ABS)"
      status="$(worse "$status" "ERROR")"
    fi
  done <<<"$rows"

  [ "$n_bad" -gt 0 ] && remediation="Create the missing directory, correct the cwd, or mark the pane \"optional\": true if it is a child repo that may be absent."
  add_check "panes.cwd" "pane cwds" "$status" \
    "$n_ok resolved, $n_skip optional-absent, $n_bad broken" "$remediation" "$details"
}

# ============================================================================
# 5. Secrets file gates — reads the file's METADATA only. This function never
#    opens the file, so no secret value can reach the report.
# ============================================================================
check_secrets() {
  [ -n "$CONFIG_JSON" ] || return 0
  [ "$CONFIG_VALID" -eq 1 ] || return 0

  local env_file
  env_file="$(printf '%s' "$CONFIG_JSON" | jq -r '.secrets.env_file // empty')"
  if [ -z "$env_file" ]; then
    add_check "secrets.env_file" "secrets file" "OK" "no secrets.env_file configured — nothing to gate"
    return 0
  fi
  if [ -z "$ROOT_ABS" ]; then
    add_check "secrets.env_file" "secrets file" "ERROR" \
      "cannot gate secrets.env_file — project.root does not resolve" \
      "Fix project.root in $CONFIG_PATH."
    return 0
  fi

  local full
  case "$env_file" in
    /*) full="$env_file" ;;
    *) full="$ROOT_ABS/$env_file" ;;
  esac

  if [ -L "$full" ]; then
    add_check "secrets.env_file" "secrets file" "ERROR" \
      "$env_file is a symlink" \
      "Replace the symlink with a regular, owner-only file inside the project root." \
      "path: $full"
    return 0
  fi
  if [ ! -f "$full" ]; then
    local on_missing
    on_missing="$(printf '%s' "$CONFIG_JSON" | jq -r '.secrets.on_missing // "warn"')"
    if [ "$on_missing" = "fail" ]; then
      add_check "secrets.env_file" "secrets file" "ERROR" \
        "$env_file does not exist (secrets.on_missing: fail)" \
        "Create $full with mode 0600, or set secrets.on_missing to \"warn\"." \
        "path: $full"
    else
      add_check "secrets.env_file" "secrets file" "WARN" \
        "$env_file does not exist (secrets.on_missing: warn)" \
        "Create $full with mode 0600 if any pane needs those keys." \
        "path: $full"
    fi
    return 0
  fi

  local status="OK" details="path: $full" remediation="" mode owner_uid

  # GNU-first stat probes: GNU stat's -f is a FILESYSTEM report, so a
  # BSD-first probe can emit report text before the fallback runs and corrupt
  # the substitution. BSD stat rejects -c cleanly on macOS.
  mode="$(stat -c '%a' "$full" 2>/dev/null || stat -f '%Lp' "$full" 2>/dev/null)"
  if [ "$mode" = "600" ]; then
    details="$details
mode: 0600"
  else
    status="$(worse "$status" "ERROR")"
    details="$details
ERROR mode is ${mode:-unknown}, must be 0600"
    remediation="chmod 600 \"$full\""
  fi

  owner_uid="$(stat -c '%u' "$full" 2>/dev/null || stat -f '%u' "$full" 2>/dev/null)"
  if [ -n "$owner_uid" ] && [ "$owner_uid" != "$(id -u)" ]; then
    status="$(worse "$status" "ERROR")"
    details="$details
ERROR owner uid is $owner_uid, must be $(id -u)"
    [ -n "$remediation" ] && remediation="$remediation; "
    remediation="${remediation}chown $(id -u) \"$full\""
  else
    details="$details
owner: uid ${owner_uid:-unknown} (current user)"
  fi

  if command -v git >/dev/null 2>&1 && git -C "$ROOT_ABS" rev-parse --git-dir >/dev/null 2>&1; then
    local rel_to_root="${full#"$ROOT_ABS"/}"
    if git -C "$ROOT_ABS" check-ignore -q -- "$rel_to_root" 2>/dev/null; then
      details="$details
git-ignored: yes"
    else
      status="$(worse "$status" "ERROR")"
      details="$details
ERROR not git-ignored"
      [ -n "$remediation" ] && remediation="$remediation; "
      remediation="${remediation}add \"$rel_to_root\" to .gitignore"
    fi
  else
    status="$(worse "$status" "WARN")"
    details="$details
WARN git-ignore status unverifiable (project root is not a git repository, or git is missing)"
    [ -n "$remediation" ] && remediation="$remediation; "
    remediation="${remediation}verify by hand that $env_file can never be committed"
  fi

  local message="all gates pass"
  [ "$status" = "WARN" ] && message="gates pass, with a caveat"
  [ "$status" = "ERROR" ] && message="one or more gates FAIL"
  add_check "secrets.env_file" "secrets file" "$status" "$env_file: $message" "$remediation" "$details"
}

# ============================================================================
# 6. State dir — probed WITHOUT creating it (doctor is read-only; creating
#    the dir is workspace-start's job).
# ============================================================================
check_state_dir() {
  [ -n "$CONFIG_JSON" ] || return 0
  [ "$CONFIG_VALID" -eq 1 ] || return 0
  local project_id state_dir
  project_id="$(printf '%s' "$CONFIG_JSON" | jq -r '.project.id // empty')"
  if [ -z "$project_id" ]; then
    add_check "state.dir" "state dir" "ERROR" \
      "project.id is missing, so the state dir cannot be located" \
      "Set project.id in $CONFIG_PATH."
    return 0
  fi
  state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/session-workspace/$project_id"

  if [ ! -d "$state_dir" ]; then
    local probe="$state_dir"
    while [ ! -d "$probe" ] && [ "$probe" != "/" ]; do
      probe="$(dirname "$probe")"
    done
    if [ -w "$probe" ]; then
      add_check "state.dir" "state dir" "INFO" \
        "$state_dir does not exist yet; it will be created (0700) on first start" "" \
        "nearest existing ancestor: $probe (writable)"
    else
      add_check "state.dir" "state dir" "ERROR" \
        "$state_dir does not exist and cannot be created — $probe is not writable" \
        "Fix permissions on $probe, or point \$XDG_STATE_HOME at a writable location."
    fi
    return 0
  fi

  local status="OK" details="" remediation="" mode
  if [ ! -w "$state_dir" ]; then
    status="ERROR"
    details="ERROR not writable"
    remediation="chmod u+rwx \"$state_dir\""
  fi
  mode="$(stat -c '%a' "$state_dir" 2>/dev/null || stat -f '%Lp' "$state_dir" 2>/dev/null)"
  if [ -n "$mode" ] && [ "$mode" != "700" ]; then
    status="$(worse "$status" "WARN")"
    [ -n "$details" ] && details="$details
"
    details="${details}WARN mode is $mode; the umask 077 pattern expects 0700"
    [ -n "$remediation" ] && remediation="$remediation; "
    remediation="${remediation}chmod 700 \"$state_dir\""
  fi
  add_check "state.dir" "state dir" "$status" "$state_dir (mode ${mode:-unknown})" "$remediation" "$details"
}

# ============================================================================
# 7. Runtime capability — PATH resolution only, via `command -v`. NEVER
#    executes the resolved program (no `--version`, no probe of any kind):
#    runtimes.<key>.program is fully config-controlled and ungated (only the
#    runtime *key*, e.g. "claude"/"codex", is a case-matched literal — the
#    program PATH itself is arbitrary, attacker-controlled input in the
#    general case), so running it at all — even with `--version` — would
#    violate this file's strictly-read-only contract.
# ============================================================================
check_runtimes() {
  [ -n "$CONFIG_JSON" ] || return 0
  [ "$CONFIG_VALID" -eq 1 ] || return 0
  local rows rt_name program resolved message
  rows="$(printf '%s' "$CONFIG_JSON" | jq -r '
    (.runtimes // {}) | to_entries[] | [.key, (.value.program // "")] | @tsv
  ')"
  if [ -z "$rows" ]; then
    add_check "runtime" "runtimes" "WARN" "no runtimes are declared" \
      "Declare at least one runtime in $CONFIG_PATH."
    return 0
  fi
  while IFS=$'\t' read -r rt_name program; do
    [ -z "$rt_name" ] && continue
    if [ -z "$program" ]; then
      add_check "runtime.$rt_name" "runtime $rt_name" "ERROR" "no program configured" \
        "Set runtimes.$rt_name.program in $CONFIG_PATH."
      continue
    fi
    if ! resolved="$(command -v -- "$program" 2>/dev/null)" || [ -z "$resolved" ]; then
      add_check "runtime.$rt_name" "runtime $rt_name" "ERROR" \
        "program \"$program\" is not on PATH" \
        "Install \"$program\", or point runtimes.$rt_name.program at its absolute path."
      continue
    fi
    message="$program -> $resolved"
    add_check "runtime.$rt_name" "runtime $rt_name" "OK" "$message"
  done <<<"$rows"
}

# ============================================================================
# 8. Coordination-base drift — the generalized form of the one-off migration.
#    WARN when ledger-shaped files live under a coordination base OTHER than
#    the configured one. Probes the tmp/ and .tmp/ siblings.
# ============================================================================
COORD_BASE_CANDIDATES=(tmp .tmp)
COORD_STORE_NAMES=(scheduler messages contexts)

# _sw_normalize_relpath PATH — strips a leading "./" (repeatedly, so "././x"
# also collapses), purely textually. Used to compare a configured
# stores.base like "./.tmp" against the fixed candidate literal ".tmp"
# without treating them as different bases.
_sw_normalize_relpath() {
  local p="$1"
  while :; do
    case "$p" in
      ./*) p="${p#./}" ;;
      *) break ;;
    esac
  done
  printf '%s' "$p"
}

check_stores_drift() {
  [ -n "$CONFIG_JSON" ] || return 0
  [ "$CONFIG_VALID" -eq 1 ] || return 0
  [ -n "$ROOT_ABS" ] || return 0

  local configured configured_norm cand store dir count total=0 details=""
  configured="$(printf '%s' "$CONFIG_JSON" | jq -r '.stores.base // ".tmp"')"
  configured_norm="$(_sw_normalize_relpath "$configured")"

  for cand in "${COORD_BASE_CANDIDATES[@]}"; do
    [ "$cand" = "$configured_norm" ] && continue
    for store in "${COORD_STORE_NAMES[@]}"; do
      # A store whose stores.overrides entry already resolves to THIS
      # candidate/store path is not drift -- it is exactly where the project
      # deliberately pointed it.
      local override override_abs
      override="$(printf '%s' "$CONFIG_JSON" | jq -r --arg s "$store" '.stores.overrides[$s] // empty')"
      if [ -n "$override" ]; then
        case "$override" in
          /*) override_abs="$override" ;;
          *) override_abs="$ROOT_ABS/$(_sw_normalize_relpath "$override")" ;;
        esac
        [ "$override_abs" = "$ROOT_ABS/$cand/$store" ] && continue
      fi

      dir="$ROOT_ABS/$cand/$store"
      [ -d "$dir" ] || continue
      # Ledger-shaped only: exclude dotfiles (a committed .gitkeep, a stray
      # .DS_Store) so an empty-but-scaffolded directory does not read as
      # drift. Real ledger files (session-chat's *.md/*.tsv, session-scheduler's
      # */*.json/*.md, knowledge's context files) never start with ".".
      count="$(find "$dir" -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')"
      [ "${count:-0}" -eq 0 ] && continue
      total=$((total + count))
      [ -n "$details" ] && details="$details
"
      details="${details}$count file(s) under $cand/$store"
    done
  done

  if [ "$total" -gt 0 ]; then
    add_check "stores.drift" "coordination base drift" "WARN" \
      "$total ledger file(s) live outside the configured coordination base (stores.base=\"$configured\")" \
      "Either move that data under $configured/, or change stores.base to point where the live data already is. Until then those messages/tasks/contexts are invisible to this project." \
      "$details"
  else
    add_check "stores.drift" "coordination base drift" "OK" \
      "no ledger files outside stores.base=\"$configured\""
  fi
}

# ============================================================================
# 9. session-chat helper resolution
# ============================================================================
check_session_chat_helper() {
  [ -n "$CONFIG_JSON" ] || return 0
  [ "$CONFIG_VALID" -eq 1 ] || return 0
  local resolve on_missing root ver details status message
  resolve="$(printf '%s' "$CONFIG_JSON" | jq -r '.behavior.session_chat_helper.resolve // "always"')"
  on_missing="$(printf '%s' "$CONFIG_JSON" | jq -r '.behavior.session_chat_helper.on_missing // "warn"')"

  if [ "$resolve" = "never" ]; then
    add_check "integrations.session_chat_helper" "session-chat helper" "OK" \
      "resolve=never — the helper is not consulted by this project"
    return 0
  fi

  # Exactly the resolution workspace-start.sh gates on, so this report can
  # never claim "start WILL fail" for a helper start would actually accept
  # (or vice versa).
  root="$(sw_session_chat_helper_root)" || root=""

  if [ -z "$root" ]; then
    if [ "$on_missing" = "fail" ]; then
      add_check "integrations.session_chat_helper" "session-chat helper" "ERROR" \
        "helper does not resolve; on_missing=fail, so start WILL fail" \
        "Install session-chat, or set behavior.session_chat_helper.on_missing to \"warn\"."
    else
      add_check "integrations.session_chat_helper" "session-chat helper" "WARN" \
        "helper does not resolve; on_missing=warn, so start will continue with a warning" \
        "Install session-chat to restore inter-pane messaging."
    fi
    return 0
  fi

  ver="$(sw_plugin_manifest_version "$root")" || ver=""
  details="root: $root"
  status="OK"
  message="resolved (version ${ver:-undetectable}), resolve=$resolve, on_missing=$on_missing"
  if [ -z "$ver" ]; then
    status="WARN"
    message="resolved but its version is undetectable, resolve=$resolve, on_missing=$on_missing"
  fi
  add_check "integrations.session_chat_helper" "session-chat helper" "$status" "$message" "" "$details"
}

# ============================================================================
# Run every check, in order.
# ============================================================================
check_tooling_tmux
check_tooling_jq
check_tooling_git
check_config
check_plugin_deps
check_pane_cwds
check_secrets
check_state_dir
check_runtimes
check_stores_drift
check_session_chat_helper

OVERALL="ok"
[ "$WARN_COUNT" -gt 0 ] && OVERALL="warn"
[ "$ERROR_COUNT" -gt 0 ] && OVERALL="error"
EXIT_CODE=0
[ "$ERROR_COUNT" -gt 0 ] && EXIT_CODE=1

# ============================================================================
# Render
# ============================================================================
if [ "$JSON_MODE" -eq 1 ]; then
  if ! command -v jq >/dev/null 2>&1; then
    # jq is exactly what is missing, so hand-emit a minimal valid object
    # rather than pretend the full report could be produced.
    printf '%s\n' '{"config":"","status":"error","errors":1,"warnings":0,"exit_code":1,"checks":[{"id":"tooling.jq","label":"jq","status":"ERROR","message":"jq is not on PATH","remediation":"Install jq: brew install jq (macOS) or apt install jq (Ubuntu).","details":[]}]}'
    exit 1
  fi
  CHECKS_JSON="[]"
  IDX=0
  TOTAL="${#CHECK_IDS[@]}"
  while [ "$IDX" -lt "$TOTAL" ]; do
    DETAILS_JSON="$(printf '%s' "${CHECK_DETAILS[$IDX]}" | jq -R -s 'split("\n") | map(select(length > 0))')"
    CHECKS_JSON="$(printf '%s' "$CHECKS_JSON" | jq -c \
      --arg id "${CHECK_IDS[$IDX]}" \
      --arg label "${CHECK_LABELS[$IDX]}" \
      --arg status "${CHECK_STATUSES[$IDX]}" \
      --arg message "${CHECK_MESSAGES[$IDX]}" \
      --arg remediation "${CHECK_REMEDIATIONS[$IDX]}" \
      --argjson details "$DETAILS_JSON" \
      '. + [{id: $id, label: $label, status: $status, message: $message, remediation: $remediation, details: $details}]')"
    IDX=$((IDX + 1))
  done
  jq -n \
    --arg config "$CONFIG_PATH" \
    --arg status "$OVERALL" \
    --argjson errors "$ERROR_COUNT" \
    --argjson warnings "$WARN_COUNT" \
    --argjson exit_code "$EXIT_CODE" \
    --argjson checks "$CHECKS_JSON" \
    '{config: $config, status: $status, errors: $errors, warnings: $warnings, exit_code: $exit_code, checks: $checks}'
  exit "$EXIT_CODE"
fi

echo "session-workspace doctor"
[ -n "$CONFIG_PATH" ] && echo "config: $CONFIG_PATH"
echo

IDX=0
TOTAL="${#CHECK_IDS[@]}"
while [ "$IDX" -lt "$TOTAL" ]; do
  printf '[%-5s] %-34s %s\n' "${CHECK_STATUSES[$IDX]}" "${CHECK_IDS[$IDX]}" "${CHECK_MESSAGES[$IDX]}"
  if [ -n "${CHECK_DETAILS[$IDX]}" ]; then
    while IFS= read -r detail_line; do
      [ -n "$detail_line" ] && printf '          %s\n' "$detail_line"
    done <<<"${CHECK_DETAILS[$IDX]}"
  fi
  if [ -n "${CHECK_REMEDIATIONS[$IDX]}" ]; then
    printf '          -> %s\n' "${CHECK_REMEDIATIONS[$IDX]}"
  fi
  IDX=$((IDX + 1))
done

echo
echo "-----------------------------------------------"
echo "doctor: $ERROR_COUNT error(s), $WARN_COUNT warning(s) — status: $OVERALL"
exit "$EXIT_CODE"
