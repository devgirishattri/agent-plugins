#!/usr/bin/env bash
# adapters.sh — Phase C runtime adapters: typed argv construction, canonical
# env rendering, per-role grants, memory-shard derivation, and secret
# handling.
#
# Core rule (see docs/session_workspace_plugin_plan.md "Engine architecture"):
# build ARGV ARRAYS everywhere; apply `printf '%q'` ONLY at the tmux boundary
# (the canonical env export string — the one place a shell re-parses a value).
# Where there is no shell in between, such as the NAME/VALUE argv handed to
# `tmux set-environment` for pin_to_session, nothing is quoted at all.
# Never `eval`.
#
# This file is both a sourceable function library (config.sh, workspace-*.sh,
# and Phase D consumers `source` it) and a small CLI used by
# test-session-workspace.sh to assert exact argv/env against stub `claude`/
# `codex` executables on PATH:
#
#   adapters.sh agent-argv   --config PATH --pane NAME [--exec]
#   adapters.sh env-exports  --config PATH --pane NAME [--tmux-pane ID]
#   adapters.sh session-env  --config PATH --pane NAME
#   adapters.sh secret-value --config PATH --pane NAME --key KEY
#   adapters.sh secret-file  --config PATH --pane NAME
#
# session-env prints the SUBSET of that pane's env which
# env.groups.<g>.pin_to_session asks to be mirrored into the pane's tmux
# SESSION environment (NUL-terminated NAME, VALUE, NAME, VALUE ... so a value
# containing a newline survives). It is computed from the very same map
# env-exports renders, so a pinned variable can never hold one value in the
# session env and a different one in the pane's process env. Deliberately
# EXCLUDED from that subset, and asserted by tests:
#   * secrets — session env is inherited by EVERY later pane in the session,
#     which is precisely the over-sharing the per-pane private-file delivery
#     below exists to prevent. Secrets never appear in this map at all.
#   * the three engine-always identity vars (TMUX_PANE,
#     SESSION_CHAT_PANE_NAME, KNOWLEDGE_PANE_NAME) and env.pane_name_aliases
#     (whose value IS the pane name) — all four are per-PANE identity. A
#     session-scoped value would be wrong for every pane and, worse, could
#     make a worker pane identify itself as the orchestrator;
#     KNOWLEDGE_PANE_NAME is an authorization boundary.
#
# secret-file resolves every secrets.allow[] key this pane's role may see
# (per secrets.visible_to_roles) and writes "KEY=VALUE" lines to a fresh,
# private (mode 0600), single-use temp file, printing only the file's PATH on
# stdout -- never the value. lifecycle.sh embeds that path (not secret) into
# the pane's own launch script, which reads the file with shell builtins
# (`read`/`export`), exports each var into ITS OWN process environment, and
# unlinks the file immediately. This is how a secret reaches exactly the
# panes authorized for it without ever appearing in any process's argv (see
# lifecycle.sh's _sw_secret_loader_snippet for why `tmux set-environment -h`
# cannot do this: hidden variables are never passed into the environment of
# new processes, per the tmux(1) manual).
#
# `agent-argv --exec` execs the resolved runtime program with the built argv
# array directly (no `%q`, no `eval` — a real `exec "${ARR[@]}"`). Tests point
# PATH at stub `claude`/`codex` binaries that dump their argv, so this never
# launches a real agent; it is also exactly what a future Phase D
# `workspace-start` will do to actually launch a pane's agent.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/config.sh"
source "$HERE/validate-config.sh"

# ============================================================================
# 1. Runtime argv construction
# ============================================================================

# Flags rejected outright, regardless of where they appear (runtimes.*.args,
# or the resolved permission_mode value). Defense in depth: validate-config.sh
# already rejects permission_mode=bypassPermissions at the schema level, but
# adapters.sh must refuse to build dangerous argv even if fed unvalidated
# input directly (e.g. a future caller that skips validation).
CLAUDE_DANGEROUS_PERMISSION_MODE="bypassPermissions"
CODEX_DANGEROUS_FLAGS="--dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust"

# _flag_token FLAG=VALUE or FLAG -> FLAG (strip a trailing =VALUE so
# "--flag=bad" is caught the same as "--flag bad").
_flag_token() {
  printf '%s' "${1%%=*}"
}

# _static_args_have_dangerous_flag RUNTIME ARG...
# Prints nothing; returns 0 (found) or 1 (clean).
_static_args_have_dangerous_flag() {
  local runtime="$1"
  shift
  local a tok banned
  for a in "$@"; do
    tok="$(_flag_token "$a")"
    if [ "$runtime" = "codex" ]; then
      for banned in $CODEX_DANGEROUS_FLAGS; do
        [ "$tok" = "$banned" ] && return 0
        [ "$a" = "$banned" ] && return 0
      done
    fi
    # bypassPermissions can show up as a bare static arg on any runtime
    # (e.g. a project mistakenly listing it in runtimes.claude.args).
    [ "$a" = "$CLAUDE_DANGEROUS_PERMISSION_MODE" ] && return 0
    [ "$tok" = "--permission-mode" ] && [ "${a#*=}" = "$CLAUDE_DANGEROUS_PERMISSION_MODE" ] && return 0
  done
  return 1
}

# _settable VALUE -> 0 if VALUE should emit a flag ("" / "null" / "inherit"
# all mean "no flag"), 1 otherwise.
_settable() {
  local v="${1:-}"
  [ -n "$v" ] && [ "$v" != "null" ] && [ "$v" != "inherit" ]
}

# build_agent_argv
# Reads (must be set by the caller first):
#   ADAPT_RUNTIME          claude | codex | shell
#   ADAPT_PROGRAM          program name/path (runtimes.<r>.program)
#   ADAPT_STATIC_ARGS      array — runtimes.<r>.args
#   ADAPT_MODEL            agent.model ("" / "null" / "inherit" => no flag)
#   ADAPT_EFFORT           agent.effort
#   ADAPT_PROFILE          agent.profile (Claude: --agent NAME; Codex: -p NAME)
#   ADAPT_PERMISSION_MODE  agent.permission_mode (Claude only)
#   ADAPT_GRANT_DIRS       array — resolved --add-dir directories, in order
# Writes ADAPT_ARGV (array) on success; returns 0.
# On a dangerous flag, prints an error to stderr, leaves ADAPT_ARGV unset,
# and returns 1. Never launches, never evals — pure array construction.
build_agent_argv() {
  ADAPT_ARGV=()

  if [ "${ADAPT_PERMISSION_MODE:-}" = "$CLAUDE_DANGEROUS_PERMISSION_MODE" ]; then
    echo "ERROR: adapters: permission_mode \"$CLAUDE_DANGEROUS_PERMISSION_MODE\" is never allowed" >&2
    return 1
  fi
  if _static_args_have_dangerous_flag "$ADAPT_RUNTIME" "${ADAPT_STATIC_ARGS[@]:-}"; then
    echo "ERROR: adapters: runtimes.$ADAPT_RUNTIME.args contains a dangerous flag" >&2
    return 1
  fi

  ADAPT_ARGV+=("$ADAPT_PROGRAM")
  local a
  for a in "${ADAPT_STATIC_ARGS[@]:-}"; do
    [ -n "$a" ] && ADAPT_ARGV+=("$a")
  done

  case "$ADAPT_RUNTIME" in
    claude)
      _settable "${ADAPT_MODEL:-}" && ADAPT_ARGV+=("--model" "$ADAPT_MODEL")
      _settable "${ADAPT_PROFILE:-}" && ADAPT_ARGV+=("--agent" "$ADAPT_PROFILE")
      _settable "${ADAPT_EFFORT:-}" && ADAPT_ARGV+=("--effort" "$ADAPT_EFFORT")
      _settable "${ADAPT_PERMISSION_MODE:-}" && ADAPT_ARGV+=("--permission-mode" "$ADAPT_PERMISSION_MODE")
      ;;
    codex)
      _settable "${ADAPT_MODEL:-}" && ADAPT_ARGV+=("--model" "$ADAPT_MODEL")
      _settable "${ADAPT_PROFILE:-}" && ADAPT_ARGV+=("-p" "$ADAPT_PROFILE")
      _settable "${ADAPT_EFFORT:-}" && ADAPT_ARGV+=("-c" "model_reasoning_effort=$ADAPT_EFFORT")
      # Codex has no --permission-mode equivalent: never emit one, even if a
      # config sets roles.<codex-role>.agent.permission_mode.
      ;;
    shell)
      # No engine-built agent flags at all for the shell "runtime" — grants
      # are agent-only (see resolve_grant_dirs / rule 4).
      ;;
    *)
      echo "ERROR: adapters: unknown runtime \"$ADAPT_RUNTIME\"" >&2
      ADAPT_ARGV=()
      return 1
      ;;
  esac

  if [ "$ADAPT_RUNTIME" != "shell" ]; then
    local d
    for d in "${ADAPT_GRANT_DIRS[@]:-}"; do
      [ -n "$d" ] && ADAPT_ARGV+=("--add-dir" "$d")
    done
  fi

  return 0
}

# ============================================================================
# 2. Canonical env rendering
# ============================================================================

# Engine-shipped KNOWLEDGE_AUTO_* / KNOWLEDGE_CONSOLIDATE_NUDGE defaults,
# identical across every adopter today. Config's env.groups.<g>.values may
# override any of these by name (a "delta"); anything not overridden ships
# as-is. Source of truth for the numbers: plugins/knowledge/scripts/
# inject-recall.sh and memory-auto-capture.sh defaults, and
# nudge-consolidate.sh's KNOWLEDGE_CONSOLIDATE_NUDGE gate.
ENGINE_KNOWLEDGE_DEFAULT_NAMES=(
  KNOWLEDGE_AUTO_RECALL
  KNOWLEDGE_AUTO_RECALL_LIMIT
  KNOWLEDGE_AUTO_RECALL_TERMS
  KNOWLEDGE_AUTO_RECALL_BUDGET
  KNOWLEDGE_CONSOLIDATE_NUDGE
  KNOWLEDGE_AUTO_CAPTURE_LIMIT
  KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING
  KNOWLEDGE_AUTO_CAPTURE_MAX_BYTES
)
ENGINE_KNOWLEDGE_DEFAULT_VALUES=(1 5 4 4000 1 3 20 4096)

# The three vars identity/authorization depends on: engine-always, never
# config-driven (see plan doc). KNOWLEDGE_PANE_NAME in particular is an
# authorization boundary for who may write to the memory store, so these
# must win over anything a config or hook-subprocess tmux probe could set.
ENGINE_ALWAYS_NAMES=(TMUX_PANE SESSION_CHAT_PANE_NAME KNOWLEDGE_PANE_NAME)

# _is_engine_always NAME — true if NAME is one of ENGINE_ALWAYS_NAMES (a
# config value/alias must never be allowed to set these).
_is_engine_always() {
  local name="$1" e
  for e in "${ENGINE_ALWAYS_NAMES[@]}"; do
    [ "$e" = "$name" ] && return 0
  done
  return 1
}

# _is_valid_env_name NAME -> 0 if NAME matches ^[A-Z_][A-Z0-9_]*$ (the same
# shape validate-structural.jq enforces for env.groups.*.values keys and
# env.pane_name_aliases[] entries), 1 otherwise. Plain case-glob matching.
_is_valid_env_name() {
  local n="${1:-}"
  case "$n" in
    '') return 1 ;;
  esac
  case "$n" in
    [A-Z_]*) : ;;
    *) return 1 ;;
  esac
  case "$n" in
    *[!A-Z0-9_]*) return 1 ;;
  esac
  return 0
}

coordination_var_name() {
  case "$1" in
    messages) echo "SESSION_CHAT_TARGET_MESSAGES_DIR" ;;
    scheduler) echo "SESSION_SCHEDULER_HOME" ;;
    contexts) echo "SESSION_CONTEXT_HOME" ;;
  esac
}

# _env_set NAME VALUE — last-write-wins upsert into the parallel ENV_NAMES /
# ENV_VALUES arrays used by render_env_exports. O(n) linear scan; the env
# maps here are always small (well under a hundred entries), and Bash 3.2
# has no associative arrays.
_env_set() {
  local name="$1" value="$2" i
  local n="${#ENV_NAMES[@]}"
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${ENV_NAMES[$i]}" = "$name" ]; then
      ENV_VALUES[$i]="$value"
      return 0
    fi
    i=$((i + 1))
  done
  ENV_NAMES+=("$name")
  ENV_VALUES+=("$value")
}

# _env_pin_mark NAME — record NAME as belonging to the session-pinned subset
# (only meaningful when the role's env group sets pin_to_session: true).
# Callers only ever pass names that were already accepted into the map.
_env_pin_mark() {
  local name="$1" e
  [ "${ENV_PIN_TO_SESSION:-false}" = "true" ] || return 0
  for e in "${ENV_PINNABLE_NAMES[@]:-}"; do
    [ "$e" = "$name" ] && return 0
  done
  ENV_PINNABLE_NAMES+=("$name")
}

# _env_build_map — the single computation behind BOTH renderers below:
# render_env_exports (the pane's process env) and render_session_env_pairs
# (the tmux session env mirrored when pin_to_session is true). One builder is
# what makes "session env and pane env can never silently diverge" a
# structural property rather than a convention.
#
# The caller must declare ENV_NAMES / ENV_VALUES / ENV_PINNABLE_NAMES as
# locals first (Bash 3.2 dynamic scoping makes them visible here).
#
# Reads (set by the caller first):
#   ENV_PANE_NAME           the pane's name (identity + alias value)
#   ENV_GROUP_VALUE_NAMES   array — env.groups.<g>.values keys
#   ENV_GROUP_VALUE_VALUES  array — env.groups.<g>.values values (parallel)
#   ENV_PANE_NAME_ALIASES   array — env.pane_name_aliases
#   ENV_PIN_TO_SESSION      "true"/"false" — role's env_group.pin_to_session
#   ENV_COORD_VAR_NAMES     array — coordination var names to export (already
#                            filtered to stores.pin AND gated by
#                            ENV_PIN_TO_SESSION by the caller)
#   ENV_COORD_VAR_VALUES    array — resolved store paths, parallel to above
#   ENV_TMUX_PANE_ID        the real target tmux pane id (re-pinned; may be
#                            empty in a non-tmux Phase C test context)
_env_build_map() {
  local i n

  n="${#ENGINE_KNOWLEDGE_DEFAULT_NAMES[@]}"
  i=0
  while [ "$i" -lt "$n" ]; do
    _env_set "${ENGINE_KNOWLEDGE_DEFAULT_NAMES[$i]}" "${ENGINE_KNOWLEDGE_DEFAULT_VALUES[$i]}"
    i=$((i + 1))
  done

  n="${#ENV_GROUP_VALUE_NAMES[@]}"
  i=0
  while [ "$i" -lt "$n" ]; do
    local gname="${ENV_GROUP_VALUE_NAMES[$i]}"
    if _is_valid_env_name "$gname"; then
      if ! _is_engine_always "$gname"; then
        _env_set "$gname" "${ENV_GROUP_VALUE_VALUES[$i]}"
        # Pinnable: a plain, pane-independent configured value.
        _env_pin_mark "$gname"
      fi
    else
      echo "WARNING: adapters: env.groups value name \"$gname\" is not a valid env-var name; dropping it" >&2
    fi
    i=$((i + 1))
  done

  # SECURITY: alias_name becomes the bare NAME in "export NAME=VALUE; " below
  # — VALUE is printf %q-quoted, NAME never is. validate-structural.jq
  # already charset-restricts env.pane_name_aliases[] to ^[A-Z_][A-Z0-9_]*$,
  # but this is re-checked here too so the renderer stays safe even when
  # called directly with unvalidated ENV_PANE_NAME_ALIASES. Rejecting here
  # (rather than quoting) matters because lifecycle.sh later runs the whole
  # rendered string via `bash -c` — an unquoted stray NAME can inject a
  # second, independent shell statement, which %q-quoting the value alone
  # cannot prevent.
  n="${#ENV_PANE_NAME_ALIASES[@]}"
  i=0
  while [ "$i" -lt "$n" ]; do
    local alias_name="${ENV_PANE_NAME_ALIASES[$i]}"
    if _is_valid_env_name "$alias_name"; then
      _is_engine_always "$alias_name" || _env_set "$alias_name" "$ENV_PANE_NAME"
    else
      echo "WARNING: adapters: env.pane_name_aliases entry \"$alias_name\" is not a valid env-var name; dropping it" >&2
    fi
    i=$((i + 1))
  done

  if [ "${ENV_PIN_TO_SESSION:-false}" = "true" ]; then
    n="${#ENV_COORD_VAR_NAMES[@]}"
    i=0
    while [ "$i" -lt "$n" ]; do
      _env_set "${ENV_COORD_VAR_NAMES[$i]}" "${ENV_COORD_VAR_VALUES[$i]}"
      _env_pin_mark "${ENV_COORD_VAR_NAMES[$i]}"
      i=$((i + 1))
    done
  fi

  # Engine-always identity vars win last, unconditionally. They are NEVER
  # marked pinnable — see the file header: a session-scoped TMUX_PANE /
  # SESSION_CHAT_PANE_NAME / KNOWLEDGE_PANE_NAME would be wrong for every
  # pane and could mis-identify a worker as the orchestrator.
  _env_set "TMUX_PANE" "${ENV_TMUX_PANE_ID:-}"
  _env_set "SESSION_CHAT_PANE_NAME" "$ENV_PANE_NAME"
  _env_set "KNOWLEDGE_PANE_NAME" "$ENV_PANE_NAME"
}

# render_env_exports — prints the canonical "export K=V; export K2=V2; ..."
# string to stdout, every value `%q`-quoted. This is the ONLY place printf
# '%q' is used for plain (non-secret) env, per the "argv first, quote last"
# rule: it IS the tmux boundary (the string a pane's shell ultimately
# sources/evals to set its process env — this is what fixes ProjectF's
# inline-prefix bug, which never reached the agent's process env at all).
# Reads the same caller-set inputs documented on _env_build_map above.
render_env_exports() {
  local ENV_NAMES=() ENV_VALUES=() ENV_PINNABLE_NAMES=()
  local i n
  _env_build_map

  local out="" name value quoted
  n="${#ENV_NAMES[@]}"
  i=0
  while [ "$i" -lt "$n" ]; do
    name="${ENV_NAMES[$i]}"
    value="${ENV_VALUES[$i]}"
    quoted="$(printf '%q' "$value")"
    out="${out}export ${name}=${quoted}; "
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# render_session_env_pairs — prints the session-pinned SUBSET of the very same
# map as NUL-terminated NAME, VALUE, NAME, VALUE ... (NUL so a value holding a
# newline or whitespace round-trips intact). Empty output when the role's env
# group has pin_to_session: false — that config mirrors nothing at all.
#
# No `%q` here on purpose: the consumer (lifecycle.sh) passes these straight
# to `tmux set-environment` as ARGV elements, so quoting would be re-inserted
# into the value itself. Quote-last still holds — there simply is no shell in
# between. Reads the same caller-set inputs documented on _env_build_map.
render_session_env_pairs() {
  local ENV_NAMES=() ENV_VALUES=() ENV_PINNABLE_NAMES=()
  local i n
  _env_build_map

  n="${#ENV_PINNABLE_NAMES[@]}"
  [ "$n" -gt 0 ] || return 0
  local name j m
  i=0
  while [ "$i" -lt "$n" ]; do
    name="${ENV_PINNABLE_NAMES[$i]}"
    # Direct index lookup rather than "$(_env_get ...)": command substitution
    # would strip a trailing newline from the value, and the whole point of
    # this function is that the session env value is byte-identical to the
    # pane env value.
    m="${#ENV_NAMES[@]}"
    j=0
    while [ "$j" -lt "$m" ]; do
      if [ "${ENV_NAMES[$j]}" = "$name" ]; then
        printf '%s\0%s\0' "$name" "${ENV_VALUES[$j]}"
        break
      fi
      j=$((j + 1))
    done
    i=$((i + 1))
  done
}

# ============================================================================
# 3. Memory shard derivation (mirrors compute-plan.jq's memory_shard/1 —
#    kept here too so adapters.sh does not have to shell out to jq for a
#    single pane when only the shard name is needed, e.g. for an env value).
# ============================================================================

# memory_shard_name PANE_NAME PROJECT_ID STRIP_PREFIX_TEMPLATE FALLBACK
# STRIP_PREFIX_TEMPLATE is the raw config string, e.g. "${PROJECT_ID}-" —
# already token-interpolated by config.sh by the time it reaches here, so in
# practice this receives the literal "<project-id>-" prefix.
memory_shard_name() {
  local pane_name="$1" strip_prefix="$2" fallback="$3"
  shift 3
  local suffixes=("$@")
  local s="$pane_name"
  if [ -n "$strip_prefix" ]; then
    case "$s" in
      "$strip_prefix"*) s="${s#"$strip_prefix"}" ;;
    esac
  fi
  local suf
  for suf in "${suffixes[@]:-}"; do
    [ -z "$suf" ] && continue
    case "$s" in
      *"$suf") s="${s%"$suf"}" ;;
    esac
  done
  [ -z "$s" ] && s="$fallback"
  printf '%s' "$s"
}

# ============================================================================
# 4. Grants — resolved directories are handed to build_agent_argv via
#    ADAPT_GRANT_DIRS; this section only documents the security rule Phase C
#    must uphold: grants apply ONLY to engine-built agent argv (never to
#    shell-role panes, see build_agent_argv's `[ "$ADAPT_RUNTIME" != "shell" ]`
#    guard above), and a role that omits "memory" from roles.<r>.grants must
#    never receive an --add-dir for the memory store — this falls out
#    naturally because ADAPT_GRANT_DIRS is built exclusively from the pane's
#    resolved plan.grants[] (see cmd_agent_argv below), which is itself
#    exclusively driven by roles.<r>.grants (see compute-plan.jq). There is no
#    separate/implicit memory grant path.
# ============================================================================

# ============================================================================
# 5. Secrets
# ============================================================================

# _is_valid_identifier NAME -> 0 if NAME matches ^[A-Za-z_][A-Za-z0-9_]*$
# (the shape validate-structural.jq enforces for secrets.allow[] entries),
# 1 otherwise. Plain case-glob matching, never a regex engine, never eval.
_is_valid_identifier() {
  local n="${1:-}"
  case "$n" in
    '') return 1 ;;
  esac
  case "$n" in
    [A-Za-z_]*) : ;;
    *) return 1 ;;
  esac
  case "$n" in
    *[!A-Za-z0-9_]*) return 1 ;;
  esac
  return 0
}

# resolve_secret_value ENV_FILE_PATH KEY
# Caller environment wins over the file (per the plan's binding rule). Prints
# the resolved value on stdout and returns 0, or returns 1 with nothing
# printed if neither source has it. Never logs the value anywhere else —
# callers must be equally careful (see secret-argv below: the value only ever
# lands inside the ADAPT_ARGV-style tmux set-environment argv array, never in
# an echoed message).
#
# SECURITY: KEY comes straight from config (secrets.allow[]) and must never
# be resolved via bash indirect expansion ("${!key}") — indirect expansion
# evaluates an array subscript, and a subscript may contain command
# substitution, so a key like "x[$(cmd)]" would run `cmd`. `printenv --`
# does a plain lookup: it treats KEY as inert text, never re-parses it.
# validate-structural.jq already charset-restricts secrets.allow[] entries
# to ^[A-Za-z_][A-Za-z0-9_]*$, but this function re-checks defensively so it
# stays safe even if called with unvalidated input directly.
resolve_secret_value() {
  local env_file="$1" key="$2"
  if ! _is_valid_identifier "$key"; then
    echo "ERROR: adapters: secret key \"$key\" is not a valid identifier" >&2
    return 1
  fi
  local caller_val=""
  # printenv exits non-zero (and prints nothing) when KEY is unset; that is
  # expected and handled explicitly here rather than relying on `set -e`
  # (which this file does not enable anyway — see `set -uo pipefail` above).
  if caller_val="$(printenv -- "$key" 2>/dev/null)" && [ -n "$caller_val" ]; then
    printf '%s' "$caller_val"
    return 0
  fi
  _parse_env_file_value "$env_file" "$key"
}

# role_may_see_secret ROLE VISIBLE_TO_ROLES_CSV
# VISIBLE_TO_ROLES_CSV is a space-joined list (from secrets.visible_to_roles).
role_may_see_secret() {
  local role="$1"
  shift
  local r
  for r in "$@"; do
    [ "$r" = "$role" ] && return 0
  done
  return 1
}

# ============================================================================
# CLI — used by tests (stub claude/codex on PATH) and, eventually, by
# workspace-start.sh (Phase D) to build+launch one pane's agent.
# ============================================================================

usage() {
  cat >&2 <<'EOF'
Usage:
  adapters.sh agent-argv   --config PATH --pane NAME [--exec]
  adapters.sh env-exports  --config PATH --pane NAME [--tmux-pane ID]
  adapters.sh session-env  --config PATH --pane NAME
  adapters.sh secret-value --config PATH --pane NAME --key KEY
  adapters.sh secret-file  --config PATH --pane NAME
EOF
}

# _load_plan_and_pane CONFIG_PATH PANE_NAME
# Shared setup for every subcommand: resolves+validates the config (Phase B,
# unchanged), computes the mutation-free plan via workspace-plan.sh, and
# extracts the CONFIG_JSON (raw interpolated config) + PANE_PLAN (this pane's
# entry from the plan) + the pane's session id + role. Sets globals:
#   CONFIG_JSON PLAN_JSON PANE_PLAN SESSION_ID ROLE_NAME
_load_plan_and_pane() {
  local config_override="$1" pane_name="$2"

  ensure_jq
  local config_path
  config_path="$(resolve_project_config_path "$config_override")" || return 1
  CONFIG_JSON="$(load_workspace_config_raw "$config_path")" || return 1
  if ! validate_workspace_config "$CONFIG_JSON" "$config_path"; then
    echo "ERROR: config failed validation: $config_path" >&2
    print_validation_errors
    return 1
  fi

  PLAN_JSON="$(bash "$HERE/workspace-plan.sh" --config "$config_path" --json)" || return 1
  PANE_PLAN="$(printf '%s' "$PLAN_JSON" | jq -c --arg n "$pane_name" '
    [.sessions[] | . as $s | ($s.panes // [])[] | select(.name == $n) | . + {session_id: $s.id}][0] // empty
  ')"
  if [ -z "$PANE_PLAN" ] || [ "$PANE_PLAN" = "null" ]; then
    echo "ERROR: adapters: no pane named \"$pane_name\" in the resolved plan" >&2
    return 1
  fi
  # shellcheck disable=SC2034  # SESSION_ID is part of this function's
  # documented global-output contract (see its header comment) for any
  # future Phase D consumer; secret-file no longer needs a --session
  # argument (delivery is per-pane now, not per-tmux-session), so nothing in
  # this file currently reads it back.
  SESSION_ID="$(printf '%s' "$PANE_PLAN" | jq -r '.session_id')"
  ROLE_NAME="$(printf '%s' "$PANE_PLAN" | jq -r '.role')"
  return 0
}

cmd_agent_argv() {
  local config_override="" pane_name="" do_exec=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --config) config_override="${2:-}"; shift 2 ;;
      --pane) pane_name="${2:-}"; shift 2 ;;
      --exec) do_exec=1; shift ;;
      *) echo "ERROR: unknown argument: $1" >&2; return 1 ;;
    esac
  done
  [ -n "$pane_name" ] || { echo "ERROR: --pane is required" >&2; return 1; }

  _load_plan_and_pane "$config_override" "$pane_name" || return 1

  ADAPT_RUNTIME="$(printf '%s' "$PANE_PLAN" | jq -r '.runtime.name')"
  ADAPT_PROGRAM="$(printf '%s' "$PANE_PLAN" | jq -r '.runtime.program // ""')"
  local static_args_json
  static_args_json="$(printf '%s' "$PANE_PLAN" | jq -c '.runtime.args // []')"
  ADAPT_STATIC_ARGS=()
  while IFS= read -r a; do
    [ -n "$a" ] && ADAPT_STATIC_ARGS+=("$a")
  done < <(printf '%s' "$static_args_json" | jq -r '.[]')

  ADAPT_MODEL="$(printf '%s' "$PANE_PLAN" | jq -r '.agent.model // ""')"
  ADAPT_EFFORT="$(printf '%s' "$PANE_PLAN" | jq -r '.agent.effort // ""')"
  ADAPT_PROFILE="$(printf '%s' "$PANE_PLAN" | jq -r '.agent.profile // ""')"
  ADAPT_PERMISSION_MODE="$(printf '%s' "$PANE_PLAN" | jq -r '.agent.permission_mode // ""')"

  ADAPT_GRANT_DIRS=()
  while IFS= read -r d; do
    [ -n "$d" ] && ADAPT_GRANT_DIRS+=("$d")
  done < <(printf '%s' "$PANE_PLAN" | jq -r '.grants[].path')

  build_agent_argv || return 1

  if [ "$do_exec" -eq 1 ]; then
    exec "${ADAPT_ARGV[@]}"
  fi
  local x
  for x in "${ADAPT_ARGV[@]}"; do
    printf '%s\0' "$x"
  done
}

# _env_prepare_inputs CONFIG_OVERRIDE PANE_NAME TMUX_PANE_ID — resolve the
# plan/pane and populate every ENV_* input _env_build_map reads. Shared by the
# `env-exports` and `session-env` verbs so the two can never be computed from
# different inputs.
_env_prepare_inputs() {
  local config_override="$1" pane_name="$2" tmux_pane_id="$3"

  _load_plan_and_pane "$config_override" "$pane_name" || return 1

  local env_group
  env_group="$(printf '%s' "$CONFIG_JSON" | jq -r --arg r "$ROLE_NAME" '.roles[$r].env_group // "none"')"
  local group_json
  group_json="$(printf '%s' "$CONFIG_JSON" | jq -c --arg g "$env_group" '.env.groups[$g] // {values:{}, pin_to_session:false}')"

  ENV_GROUP_VALUE_NAMES=()
  ENV_GROUP_VALUE_VALUES=()
  while IFS=$'\t' read -r k v; do
    [ -z "$k" ] && continue
    ENV_GROUP_VALUE_NAMES+=("$k")
    ENV_GROUP_VALUE_VALUES+=("$v")
  done < <(printf '%s' "$group_json" | jq -r '.values // {} | to_entries[] | [.key, .value] | @tsv')

  ENV_PANE_NAME_ALIASES=()
  while IFS= read -r a; do
    [ -n "$a" ] && ENV_PANE_NAME_ALIASES+=("$a")
  done < <(printf '%s' "$CONFIG_JSON" | jq -r '.env.pane_name_aliases // [] | .[]')

  ENV_PIN_TO_SESSION="$(printf '%s' "$group_json" | jq -r '.pin_to_session // false')"

  local store_base store_overrides_json root_abs
  store_base="$(printf '%s' "$CONFIG_JSON" | jq -r '.stores.base // ".tmp"')"
  store_overrides_json="$(printf '%s' "$CONFIG_JSON" | jq -c '.stores.overrides // {}')"
  root_abs="$(printf '%s' "$PLAN_JSON" | jq -r '.project.root')"

  ENV_COORD_VAR_NAMES=()
  ENV_COORD_VAR_VALUES=()
  local store var_name override path
  while IFS= read -r store; do
    [ -z "$store" ] && continue
    var_name="$(coordination_var_name "$store")"
    [ -z "$var_name" ] && continue
    override="$(printf '%s' "$store_overrides_json" | jq -r --arg s "$store" '.[$s] // empty')"
    if [ -n "$override" ]; then
      case "$override" in
        /*) path="$override" ;;
        *) path="$root_abs/$override" ;;
      esac
    else
      path="$root_abs/$store_base/$store"
    fi
    ENV_COORD_VAR_NAMES+=("$var_name")
    ENV_COORD_VAR_VALUES+=("$path")
  done < <(printf '%s' "$CONFIG_JSON" | jq -r '.stores.pin // [] | .[]')

  ENV_PANE_NAME="$pane_name"
  ENV_TMUX_PANE_ID="$tmux_pane_id"
}

cmd_env_exports() {
  local config_override="" pane_name="" tmux_pane_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --config) config_override="${2:-}"; shift 2 ;;
      --pane) pane_name="${2:-}"; shift 2 ;;
      --tmux-pane) tmux_pane_id="${2:-}"; shift 2 ;;
      *) echo "ERROR: unknown argument: $1" >&2; return 1 ;;
    esac
  done
  [ -n "$pane_name" ] || { echo "ERROR: --pane is required" >&2; return 1; }

  _env_prepare_inputs "$config_override" "$pane_name" "$tmux_pane_id" || return 1

  render_env_exports
  printf '\n'
}

cmd_session_env() {
  local config_override="" pane_name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --config) config_override="${2:-}"; shift 2 ;;
      --pane) pane_name="${2:-}"; shift 2 ;;
      *) echo "ERROR: unknown argument: $1" >&2; return 1 ;;
    esac
  done
  [ -n "$pane_name" ] || { echo "ERROR: --pane is required" >&2; return 1; }

  # No --tmux-pane: TMUX_PANE is per-pane identity and is never pinnable, so
  # the session-env subset does not depend on it.
  _env_prepare_inputs "$config_override" "$pane_name" "" || return 1

  render_session_env_pairs
}

cmd_secret_value() {
  local config_override="" pane_name="" key=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --config) config_override="${2:-}"; shift 2 ;;
      --pane) pane_name="${2:-}"; shift 2 ;;
      --key) key="${2:-}"; shift 2 ;;
      *) echo "ERROR: unknown argument: $1" >&2; return 1 ;;
    esac
  done
  [ -n "$pane_name" ] || { echo "ERROR: --pane is required" >&2; return 1; }
  [ -n "$key" ] || { echo "ERROR: --key is required" >&2; return 1; }

  _load_plan_and_pane "$config_override" "$pane_name" || return 1

  local allow_json
  allow_json="$(printf '%s' "$CONFIG_JSON" | jq -c '.secrets.allow // []')"
  if ! printf '%s' "$allow_json" | jq -e --arg k "$key" 'index($k) != null' >/dev/null; then
    echo "ERROR: adapters: \"$key\" is not in secrets.allow" >&2
    return 1
  fi

  local visible_json
  visible_json="$(printf '%s' "$CONFIG_JSON" | jq -c '.secrets.visible_to_roles // []')"
  local visible_roles=()
  while IFS= read -r r; do
    [ -n "$r" ] && visible_roles+=("$r")
  done < <(printf '%s' "$visible_json" | jq -r '.[]')
  if ! role_may_see_secret "$ROLE_NAME" "${visible_roles[@]:-}"; then
    echo "ERROR: adapters: role \"$ROLE_NAME\" is not in secrets.visible_to_roles" >&2
    return 1
  fi

  local root_abs env_file_rel env_file_abs
  root_abs="$(printf '%s' "$PLAN_JSON" | jq -r '.project.root')"
  env_file_rel="$(printf '%s' "$CONFIG_JSON" | jq -r '.secrets.env_file // empty')"
  [ -z "$env_file_rel" ] && { echo "ERROR: adapters: secrets.env_file is not configured" >&2; return 1; }
  case "$env_file_rel" in
    /*) env_file_abs="$env_file_rel" ;;
    *) env_file_abs="$root_abs/$env_file_rel" ;;
  esac

  local value on_missing
  if value="$(resolve_secret_value "$env_file_abs" "$key")"; then
    printf '%s' "$value"
    return 0
  fi
  on_missing="$(printf '%s' "$CONFIG_JSON" | jq -r '.secrets.on_missing // "warn"')"
  if [ "$on_missing" = "fail" ]; then
    echo "ERROR: adapters: secret \"$key\" is missing (on_missing: fail)" >&2
    return 1
  fi
  echo "WARNING: adapters: secret \"$key\" is missing (on_missing: warn)" >&2
  return 1
}

cmd_secret_file() {
  local config_override="" pane_name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --config) config_override="${2:-}"; shift 2 ;;
      --pane) pane_name="${2:-}"; shift 2 ;;
      *) echo "ERROR: unknown argument: $1" >&2; return 1 ;;
    esac
  done
  [ -n "$pane_name" ] || { echo "ERROR: --pane is required" >&2; return 1; }

  _load_plan_and_pane "$config_override" "$pane_name" || return 1

  local allow_json
  allow_json="$(printf '%s' "$CONFIG_JSON" | jq -c '.secrets.allow // []')"
  [ "$(printf '%s' "$allow_json" | jq 'length')" -gt 0 ] || return 0

  local visible_json
  visible_json="$(printf '%s' "$CONFIG_JSON" | jq -c '.secrets.visible_to_roles // []')"
  local visible_roles=()
  while IFS= read -r r; do
    [ -n "$r" ] && visible_roles+=("$r")
  done < <(printf '%s' "$visible_json" | jq -r '.[]')
  role_may_see_secret "$ROLE_NAME" "${visible_roles[@]:-}" || return 0

  local on_missing
  on_missing="$(printf '%s' "$CONFIG_JSON" | jq -r '.secrets.on_missing // "warn"')"

  local root_abs env_file_rel env_file_abs
  root_abs="$(printf '%s' "$PLAN_JSON" | jq -r '.project.root')"
  env_file_rel="$(printf '%s' "$CONFIG_JSON" | jq -r '.secrets.env_file // empty')"
  if [ -z "$env_file_rel" ]; then
    echo "ERROR: adapters: secrets.env_file is not configured" >&2
    return 1
  fi
  case "$env_file_rel" in
    /*) env_file_abs="$env_file_rel" ;;
    *) env_file_abs="$root_abs/$env_file_rel" ;;
  esac

  # umask 077 (lib.sh, process-wide) already makes this owner-only; chmod is
  # defensive belt-and-suspenders in case a caller's umask was overridden.
  local out_file
  out_file="$(mktemp "${TMPDIR:-/tmp}/sw-secret.XXXXXX")" || {
    echo "ERROR: adapters: could not create a private secret transfer file" >&2
    return 1
  }
  chmod 600 "$out_file" 2>/dev/null || true

  local key value any=0 missing_fail=0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if value="$(resolve_secret_value "$env_file_abs" "$key")"; then
      printf '%s=%s\n' "$key" "$value" >>"$out_file"
      any=1
    elif [ "$on_missing" = "fail" ]; then
      echo "ERROR: adapters: secret \"$key\" is missing for pane \"$pane_name\" (secrets.on_missing: fail)" >&2
      missing_fail=1
    else
      echo "WARNING: adapters: secret \"$key\" is missing for pane \"$pane_name\" (secrets.on_missing: warn); it will start without it" >&2
    fi
  done < <(printf '%s' "$allow_json" | jq -r '.[]')

  if [ "$missing_fail" -eq 1 ]; then
    rm -f "$out_file"
    return 1
  fi
  if [ "$any" -eq 0 ]; then
    rm -f "$out_file"
    return 0
  fi

  printf '%s\n' "$out_file"
  return 0
}

_run_cli() {
  local sub="${1:-}"
  [ -n "$sub" ] && shift
  case "$sub" in
    agent-argv) cmd_agent_argv "$@" ;;
    env-exports) cmd_env_exports "$@" ;;
    session-env) cmd_session_env "$@" ;;
    secret-value) cmd_secret_value "$@" ;;
    secret-file) cmd_secret_file "$@" ;;
    -h|--help) usage; return 0 ;;
    "") usage; return 1 ;;
    *) echo "ERROR: unknown subcommand: $sub" >&2; usage; return 1 ;;
  esac
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  _run_cli "$@"
  exit $?
fi
