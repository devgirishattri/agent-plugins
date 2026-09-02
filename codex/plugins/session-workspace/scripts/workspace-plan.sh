#!/usr/bin/env bash
# workspace-plan.sh — session-workspace 'plan' verb.
# Deterministic, MUTATION-FREE: resolves and displays what `workspace-start`
# would do, in both human-readable and --json form, without touching tmux or
# any state directory. Invoked by the plugin's workspace-plan command in
# both provider trees, and reachable via the dispatcher as `workspace.sh plan`.
#
# Usage: workspace-plan.sh [TARGET|all] [--config PATH] [--json]
#   TARGET  a sessions[].id to show only that session (default: all)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/config.sh"
source "$HERE/validate-config.sh"

usage() {
  echo "Usage: workspace-plan.sh [TARGET|all] [--config PATH] [--json]" >&2
}

TARGET="all"
CONFIG_OVERRIDE=""
JSON_MODE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      CONFIG_OVERRIDE="${2:-}"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    all)
      TARGET="all"
      shift
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      TARGET="$1"
      shift
      ;;
  esac
done

ensure_jq

CONFIG_PATH="$(resolve_project_config_path "$CONFIG_OVERRIDE")" || exit 1
CONFIG_JSON="$(load_workspace_config_raw "$CONFIG_PATH")" || exit 1

if ! validate_workspace_config "$CONFIG_JSON" "$CONFIG_PATH"; then
  echo "ERROR: config failed validation: $CONFIG_PATH" >&2
  print_validation_errors
  exit 1
fi

ROOT_REL="$(printf '%s' "$CONFIG_JSON" | jq -r '.project.root // "."')"
CONFIG_DIR="$(config_base_dir "$CONFIG_PATH")"
ROOT_ABS="$(canonicalize_dir "$CONFIG_DIR/$ROOT_REL")"
if [ -z "$ROOT_ABS" ]; then
  echo "ERROR: project.root (\"$ROOT_REL\") does not resolve to an existing directory relative to $CONFIG_DIR" >&2
  exit 1
fi
BROWSER_PROFILE_DIR=""
if printf '%s' "$CONFIG_JSON" | jq -e 'has("browser")' >/dev/null; then
  BROWSER_PROFILE_DIR="$(sw_browser_profile_dir "$(printf '%s' "$CONFIG_JSON" | jq -r '.project.id')")"
fi

# Validate TARGET before computing the plan, so an unknown target fails fast.
# Session filtering happens after normalization: schema-v4 orchestration is a
# workspace-wide target map and still needs every configured executor/reviewer
# pair even when the caller asks to display one tmux session.
if [ "$TARGET" != "all" ]; then
  KNOWN_IDS="$(printf '%s' "$CONFIG_JSON" | jq -r '[(.sessions // [])[].id] | join(", ")')"
  if ! printf '%s' "$CONFIG_JSON" | jq -e --arg t "$TARGET" '[(.sessions // [])[].id] | index($t) != null' >/dev/null; then
    echo "ERROR: unknown session target \"$TARGET\" (known: $KNOWN_IDS)" >&2
    exit 1
  fi
fi

# Resolve every pane's cwd against the filesystem (mutation-free: read-only
# `cd ... && pwd -P` probes, same canonicalization rule used by
# validate-config.sh — never realpath). This has to happen in bash;
# compute-plan.jq only consumes the resulting map, it never touches disk.
CWD_MAP="$(printf '%s' "$CONFIG_JSON" | jq -c '
  [(.sessions // [])[] | (.panes // [])[] | select(has("cwd")) | {name, cwd}]
')"
CWD_MAP_RESOLVED="{}"
while IFS=$'\t' read -r pane_name cwd_rel; do
  [ -z "$pane_name" ] && continue
  case "$cwd_rel" in
    /*) candidate="$cwd_rel" ;;
    *) candidate="$ROOT_ABS/$cwd_rel" ;;
  esac
  resolved="$(canonicalize_dir "$candidate")"
  CWD_MAP_RESOLVED="$(printf '%s' "$CWD_MAP_RESOLVED" | jq -c --arg k "$pane_name" --arg v "$resolved" '.[$k] = (if $v == "" then null else $v end)')"
done < <(printf '%s' "$CWD_MAP" | jq -r '.[] | [.name, .cwd] | @tsv')

PLAN_JSON="$(printf '%s' "$CONFIG_JSON" | jq -c \
  --arg root "$ROOT_ABS" \
  --arg config_path "$CONFIG_PATH" \
  --arg browser_profile_dir "$BROWSER_PROFILE_DIR" \
  --argjson cwd_map "$CWD_MAP_RESOLVED" \
  -f "$HERE/compute-plan.jq")"

if [ "$TARGET" != "all" ]; then
  PLAN_JSON="$(printf '%s' "$PLAN_JSON" | jq -c --arg t "$TARGET" '.sessions |= map(select(.id == $t))')"
fi

if [ "$JSON_MODE" -eq 1 ]; then
  printf '%s\n' "$PLAN_JSON" | jq '.'
  exit 0
fi

# --- human-readable renderer ---
flag_or_none() {
  local v="$1"
  [ -z "$v" ] || [ "$v" = "null" ] && { echo "(none — no flag)"; return; }
  echo "$v"
}

printf 'session-workspace plan — %s\n' "$CONFIG_PATH"
printf '%s\n' "$PLAN_JSON" | jq -r '
  "project: \(.project.id) (\(.project.display_name))  root=\(.project.root)",
  (if .harness.active then
     "harness: active  mode=\(.harness.mode)  profile=\(.harness.profile)",
     (if .harness.guards then "guards: " + (.harness.guards | tojson) else empty end)
   else
     "harness: inactive"
   end),
  (if (.orchestration.active // false) then
     "orchestration: active  profile=\(.orchestration.profile)  targets=\(.orchestration.targets | length)",
     (.orchestration.targets[] |
       "  target \(.id): cwd=\(.cwd) executor=\(.executor) reviewer=\(.reviewer) git=\(.remote)/\(.work_branch)->\(.release_branch) deploy=\(.deploy.strategy) align_work_after_release=\(.deploy.align_work_after_release)")
   elif has("orchestration") then
     "orchestration: inactive"
   else empty end)
'
echo

printf '%s\n' "$PLAN_JSON" | jq -c '.sessions[]' | while IFS= read -r session; do
  s_id="$(printf '%s' "$session" | jq -r '.id')"
  s_name="$(printf '%s' "$session" | jq -r '.name')"
  s_win="$(printf '%s' "$session" | jq -r '.window_index')"
  s_layout_kind="$(printf '%s' "$session" | jq -r '.layout.kind // "standard"')"
  s_layout_name="$(printf '%s' "$session" | jq -r '.layout.name // ""')"
  s_retain="$(printf '%s' "$session" | jq -r '.retain_layout')"

  printf '== session: %s (%s) ==\n' "$s_id" "$s_name"
  if [ "$s_layout_kind" = "split_tree" ]; then
    printf '  window_index=%s  layout=split_tree  retain_layout=%s\n' "$s_win" "$s_retain"
    printf '%s\n' "$session" | jq -r '
      "  pane_order: " + ((.layout.pane_order // []) | join(" -> "))
    '
  else
    printf '  window_index=%s  layout=%s (%s)  retain_layout=%s\n' "$s_win" "$s_layout_kind" "$s_layout_name" "$s_retain"
  fi
  # What `workspace-start` will actually mirror into this tmux session's
  # environment via `set-environment` (names only — never a value, and never
  # a secret or a per-pane identity var; see compute-plan.jq).
  printf '%s\n' "$session" | jq -r '
    "  session env pinned (names only): " +
    (if ((.pinned_session_env // []) | length) == 0 then "(none)" else (.pinned_session_env | join(", ")) end)
  '

  printf '%s\n' "$session" | jq -c '.panes[]' | while IFS= read -r pane; do
    p_name="$(printf '%s' "$pane" | jq -r '.name')"
    p_role="$(printf '%s' "$pane" | jq -r '.role')"
    p_rt="$(printf '%s' "$pane" | jq -r '.runtime.name')"
    p_prog="$(printf '%s' "$pane" | jq -r '.runtime.program // "(none)"')"
    p_cwd="$(printf '%s' "$pane" | jq -r '.cwd // ("(unresolved: " + (.cwd_raw // "?") + ")")')"
    p_optional="$(printf '%s' "$pane" | jq -r '.optional')"
    p_skip="$(printf '%s' "$pane" | jq -r '.skip_unresolved // false')"
    p_model="$(printf '%s' "$pane" | jq -r '.agent.model // ""')"
    p_effort="$(printf '%s' "$pane" | jq -r '.agent.effort // ""')"
    p_profile="$(printf '%s' "$pane" | jq -r '.agent.profile // ""')"
    p_perm="$(printf '%s' "$pane" | jq -r '.agent.permission_mode // ""')"
    p_command="$(printf '%s' "$pane" | jq -r 'if .command then (.command | join(" ")) else "" end')"
    p_port="$(printf '%s' "$pane" | jq -r '.port // ""')"

    printf '  pane: %s' "$p_name"
    [ "$p_optional" = "true" ] && printf ' (optional)'
    [ "$p_skip" = "true" ] && printf ' [SKIPPED: cwd unavailable — will not be launched]'
    printf '\n'
    printf '    role=%s  runtime=%s  program=%s\n' "$p_role" "$p_rt" "$p_prog"
    printf '    cwd=%s\n' "$p_cwd"
    [ -n "$p_command" ] && printf '    command: %s\n' "$p_command"
    [ -n "$p_port" ] && printf '    port: %s\n' "$p_port"
    printf '    agent: model=%s effort=%s profile=%s permission_mode=%s\n' \
      "$(flag_or_none "$p_model")" "$(flag_or_none "$p_effort")" "$(flag_or_none "$p_profile")" "$(flag_or_none "$p_perm")"
    printf '%s\n' "$pane" | jq -r '
      "    grants: " + (if (.grants | length) == 0 then "(none)" else (.grants | map("\(.store)=\(.path)") | join(", ")) end)
    '
    printf '%s\n' "$pane" | jq -r '
      "    memory: mode=" + .memory.mode + " path=" + .memory.path
    '
    printf '%s\n' "$pane" | jq -r '
      "    env vars (names only): " + (.env_names | join(", "))
    '
  done
  echo
done

exit 0
