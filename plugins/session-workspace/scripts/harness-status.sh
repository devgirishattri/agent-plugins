#!/usr/bin/env bash
# harness-status.sh — read-only status for the opt-in session-workspace harness.
#
# Reports the validated harness block (inactive, or active with mode/profile/
# roles/gates), this process's engine-owned identity (the six
# SESSION_WORKSPACE_* variables plus the SESSION_CHAT_PANE_NAME /
# KNOWLEDGE_PANE_NAME aliases), a structural comparison of that identity
# against the plan, and — decisive — the live verdict of harness-policy.py
# itself for this process ("policy"), obtained by probing it with a harmless
# unknown-tool payload in the CURRENT environment. The probe is the single
# source of truth: whatever it says is exactly what the PreToolUse hook will
# do here, so status/doctor can never disagree with the policy.
#
# The "floor" lines are the immutable strict-v1 role floor, rendered only from
# harness-policy.py --floor-json (the policy's own tables), for this pane's
# resolved role or, without an accepted identity, for every role. The
# "optional guard packs" line lists only the configured harness.guards packs,
# which add to the floor. --probe decides this pane's built-in floor cases
# through harness-policy.py --probe-json; it runs and writes nothing, and the
# script exits 1 when any case is not decided as expected.
#
# To judge one payload for a role without a live pane (read-only, never the
# hook), use the policy's test mode: harness-policy.py --decision-json
# --as-role reviewer|executor --as-cwd DIR < payload.json
#
# Usage: harness-status.sh [--config PATH] [--json] [--probe]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/config.sh"

CONFIG_OVERRIDE=""
JSON_MODE=0
PROBE_MODE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_OVERRIDE="${2:-}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    --probe) PROBE_MODE=1; shift ;;
    -h|--help)
      echo "Usage: harness-status.sh [--config PATH] [--json] [--probe]"
      echo "Judge one payload for a role (read-only test mode, never the hook):"
      echo "  python3 $HERE/harness-policy.py --decision-json --as-role reviewer|executor --as-cwd DIR < payload.json"
      exit 0
      ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done

CONFIG_PATH="$(resolve_project_config_path "$CONFIG_OVERRIDE")" || exit 1
CONFIG_DIR="$(cd "$(dirname "$CONFIG_PATH")" && pwd -P)" || exit 1
CONFIG_PATH="$CONFIG_DIR/$(basename "$CONFIG_PATH")"
PLAN_JSON="$(bash "$HERE/workspace-plan.sh" --config "$CONFIG_PATH" --json)" || exit 1

# Live policy probe: the policy reads ONLY the environment (never --config),
# so this reflects the process it runs in. An unknown tool name is allowed by
# the floor when active, so the only non-allow outcomes are integrity
# denials (identity/config/drift). Absent python3 the probe is null and the
# doctor reports that separately.
PROBE_JSON="null"
FLOOR_JSON="null"
CASES_JSON="null"
if command -v python3 >/dev/null 2>&1; then
  PROBE_JSON="$(printf '{"tool_name":"HarnessStatusProbe","tool_input":{}}' | python3 "$HERE/harness-policy.py" --decision-json 2>/dev/null)" || PROBE_JSON="null"
  printf '%s' "$PROBE_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 || PROBE_JSON="null"
  FLOOR_JSON="$(python3 "$HERE/harness-policy.py" --floor-json 2>/dev/null </dev/null)" || FLOOR_JSON="null"
  printf '%s' "$FLOOR_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 || FLOOR_JSON="null"
  if [ "$PROBE_MODE" -eq 1 ]; then
    CASES_JSON="$(python3 "$HERE/harness-policy.py" --probe-json 2>/dev/null </dev/null)" || CASES_JSON="null"
    printf '%s' "$CASES_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 || CASES_JSON="null"
  fi
fi
if [ "$PROBE_MODE" -eq 1 ] && [ "$CASES_JSON" = "null" ]; then
  CASES_JSON='{"ran":false,"reason":"harness-policy.py --probe-json is unavailable (python3 missing or failed)","role":null,"floor":null,"mode":null,"cases":[]}'
fi

STATUS_JSON="$(printf '%s' "$PLAN_JSON" | jq \
  --arg config_path "$CONFIG_PATH" \
  --arg env_config "${SESSION_WORKSPACE_CONFIG:-}" \
  --arg env_root "${SESSION_WORKSPACE_PROJECT_ROOT:-}" \
  --arg env_pane "${SESSION_WORKSPACE_PANE_NAME:-}" \
  --arg env_role "${SESSION_WORKSPACE_ROLE:-}" \
  --arg env_cwd "${SESSION_WORKSPACE_PANE_CWD:-}" \
  --arg env_mode "${SESSION_WORKSPACE_HARNESS_MODE:-}" \
  --arg env_scope "${SESSION_WORKSPACE_SCOPE_JSON:-}" \
  --arg env_read_paths "${SESSION_WORKSPACE_READ_PATHS_JSON:-}" \
  --arg env_guards "${SESSION_WORKSPACE_GUARDS_JSON:-}" \
  --arg chat_alias "${SESSION_CHAT_PANE_NAME:-}" \
  --arg knowledge_alias "${KNOWLEDGE_PANE_NAME:-}" \
  --argjson probe "$PROBE_JSON" \
  --argjson floor "$FLOOR_JSON" \
  --argjson cases "$CASES_JSON" '
  . as $plan
  | ([.sessions[] | .panes[] | select(.name == $env_pane)] | .[0] // null) as $pane
  | (.harness.roles // {}) as $role_names
  | ([.sessions[] | .panes[] | select(.role == $role_names.orchestrator and (.scope.environment // null) != null and .cwd != $plan.project.root)] | length > 0) as $has_confined
  | [$env_config, $env_root, $env_pane, $env_role, $env_cwd] as $core
  | ([$core[] | select(. != "")] | length) as $core_set
  | {
      config_path: $config_path,
      active: .harness.active,
      mode: (.harness.mode // "inactive"),
      profile: (.harness.profile // null),
      roles: (.harness.roles // null),
      gates: (.harness.gates // null),
      # floor: the immutable strict-v1 role floor from harness-policy.py
      # --floor-json. guards: only the optional harness.guards packs.
      floor: (if .harness.active != true or $floor == null then null else
        ($floor.current) as $current
        | {
            profile: $floor.profile,
            configurable: $floor.configurable,
            view: (if $current == null then "all" else "pane" end),
            current: $current,
            reason: $floor.reason,
            roles: [
              (if $current != null then [$current]
               else ["reviewer", "executor", "orchestrator"] + (if $has_confined then ["confined_orchestrator"] else [] end) end)[]
              | . as $key
              | $floor.roles[$key] + {name: (
                  if $key == "confined_orchestrator" then "\($role_names.orchestrator) (confined)"
                  else ($role_names[$key] // $key) end)}
            ],
            all: $floor.all,
            guard_pack_rules: $floor.guard_pack_rules
          }
        end),
      guards: (.harness.guards // null),
      read_paths: ($pane.read_paths // []),
      identity: {
        # present: ANY engine identity variable is set; complete: all five
        # core variables are set (mode is legitimately empty when inactive);
        # partial: some but not all -- the policy fails closed on that.
        present: ($core_set > 0 or $env_mode != ""),
        complete: ($core_set == 5),
        partial: (($core_set > 0 or $env_mode != "") and $core_set != 5),
        config: (if $env_config == "" then null else $env_config end),
        project_root: (if $env_root == "" then null else $env_root end),
        pane_name: (if $env_pane == "" then null else $env_pane end),
        role: (if $env_role == "" then null else $env_role end),
        cwd: (if $env_cwd == "" then null else $env_cwd end),
        mode: (if $env_mode == "" then null else $env_mode end),
        guards: (if $env_guards == "" then null else (try ($env_guards | fromjson) catch "invalid") end),
        read_paths: (if $env_read_paths == "" then [] else (try ($env_read_paths | fromjson) catch "invalid") end),
        aliases: {
          session_chat_pane_name: (if $chat_alias == "" then null else $chat_alias end),
          knowledge_pane_name: (if $knowledge_alias == "" then null else $knowledge_alias end),
          agree: (($chat_alias == "" or $chat_alias == $env_pane) and ($knowledge_alias == "" or $knowledge_alias == $env_pane))
        },
        matches: (
          if ($core_set == 0 and $env_mode == "") then null
          else ($core_set == 5
            and $pane != null
            and $env_config == $config_path
            and $env_root == .project.root
            and $env_role == $pane.role
            and $env_cwd == ($pane.cwd // "")
            and $env_mode == (.harness.mode // "")
            and (if ($pane.read_paths // [] | length) > 0 then (try (($env_read_paths | fromjson) == $pane.read_paths) catch false) else $env_read_paths == "" end)
            and (if $pane.scope != null then (try (($env_scope | fromjson) == $pane.scope) catch false) else $env_scope == "" end)
            and (if .harness.guards then (try (($env_guards | fromjson) == .harness.guards) catch false) else $env_guards == "" end)
            and (($chat_alias == "" or $chat_alias == $env_pane) and ($knowledge_alias == "" or $knowledge_alias == $env_pane)))
          end
        )
      },
      policy: $probe,
      probe: $cases
    }
')"

# --probe exits 1 when any case was not decided as expected.
PROBE_RC=0
if [ "$PROBE_MODE" -eq 1 ] && ! printf '%s' "$STATUS_JSON" | jq -e '.probe.ran != true or all(.probe.cases[]; .ok)' >/dev/null 2>&1; then
  PROBE_RC=1
fi

if [ "$JSON_MODE" -eq 1 ]; then
  printf '%s\n' "$STATUS_JSON"
  exit "$PROBE_RC"
fi

printf 'session-workspace harness status — %s\n' "$CONFIG_PATH"
printf '%s\n' "$STATUS_JSON" | jq -r '
  def pad($n): . + ([range([$n - length, 0] | max)] | map(" ") | join(""));
  if .active then
    "state: active  mode=\(.mode)  profile=\(.profile)",
    "roles: orchestrator=\(.roles.orchestrator) executor=\(.roles.executor) reviewer=\(.roles.reviewer)",
    "gates: plan-review=\(.gates.plan_review_ttl_minutes)m audit=\(.gates.audit_ttl_minutes)m",
    (if .floor == null then
       "floor (strict-v1, not configurable): not rendered (python3 unavailable; the hook fails closed without it)"
     else
       "floor (strict-v1, not configurable):",
       (.floor.roles[] | "  \(.name) -> \(.text)"),
       "  all roles -> \(.floor.all.text)"
     end),
    (if .guards then "optional guard packs: " + (.guards | tojson) else "optional guard packs: none (schema-v2-compatible behavior)" end)
  else
    "state: inactive"
  end,
  "read_paths (shell only): " + (.read_paths | tojson),
  (if .identity.matches == null then
     "identity: not present in this process (run from a workspace-launched pane for a live match)"
   elif .identity.partial then
     "identity: PARTIAL  pane=\(.identity.pane_name // "missing") role=\(.identity.role // "missing") cwd=\(.identity.cwd // "missing") config=\(if .identity.config == null then "missing" else "set" end) root=\(if .identity.project_root == null then "missing" else "set" end)"
   elif .identity.matches then
     "identity: MATCH  pane=\(.identity.pane_name) role=\(.identity.role) cwd=\(.identity.cwd)"
   else
     "identity: MISMATCH  pane=\(.identity.pane_name // "missing") role=\(.identity.role // "missing") cwd=\(.identity.cwd // "missing")" + (if .identity.aliases.agree then "" else "  (pane-name alias disagrees: session-chat=\(.identity.aliases.session_chat_pane_name // "-") knowledge=\(.identity.aliases.knowledge_pane_name // "-"))" end)
   end),
  (if .policy == null then
     "policy: not probed (python3 unavailable)"
   elif .policy.active | not then
     "policy: hook is a no-op in this process (\(.policy.reason))"
   elif .policy.decision == "allow" then
     "policy: strict-v1 active for role \(.policy.role) in \(.policy.mode) mode; identity accepted"
   else
     "policy: BLOCKING in this process [\(.policy.rule)] \(.policy.reason)"
   end),
  (if .probe == null then empty
   elif .probe.ran != true then
     "probe: not run (\(.probe.reason))"
   else
     ([.probe.cases[] | select(.ok | not)] | length) as $bad
     | "probe (decides this pane'"'"'s floor cases, runs nothing): \(.probe.floor) in \(.probe.mode) mode, \(.probe.cases | length) cases, " + (if $bad == 0 then "all as expected" else "\($bad) NOT as expected" end),
       ([.probe.cases | to_entries[] | .value + {index: .key}] | group_by(.group) | sort_by(.[0].index)[]
        | if length > 1 and all(.[]; .ok) and ([.[].rule] | unique | length) == 1 and ([.[].decision] | unique | length) == 1
          then "  " + (.[0].decision | pad(6)) + " " + (.[0].rule | pad(26)) + " " + .[0].group + " [\(length) edit tools]"
          else .[] | if .ok
            then "  " + (.decision | pad(6)) + " " + (.rule | pad(26)) + " " + .group
            else "  UNEXPECTED " + .decision + " " + .rule + " (expected " + .expect + " " + .expect_rule + "): " + .group + " (\(.tool))"
            end
          end)
   end)
'
exit "$PROBE_RC"
