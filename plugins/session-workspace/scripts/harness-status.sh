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
# Usage: harness-status.sh [--config PATH] [--json]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/config.sh"

CONFIG_OVERRIDE=""
JSON_MODE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_OVERRIDE="${2:-}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help)
      echo "Usage: harness-status.sh [--config PATH] [--json]"
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
if command -v python3 >/dev/null 2>&1; then
  PROBE_JSON="$(printf '{"tool_name":"HarnessStatusProbe","tool_input":{}}' | python3 "$HERE/harness-policy.py" --decision-json 2>/dev/null)" || PROBE_JSON="null"
  printf '%s' "$PROBE_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 || PROBE_JSON="null"
fi

STATUS_JSON="$(printf '%s' "$PLAN_JSON" | jq \
  --arg config_path "$CONFIG_PATH" \
  --arg env_config "${SESSION_WORKSPACE_CONFIG:-}" \
  --arg env_root "${SESSION_WORKSPACE_PROJECT_ROOT:-}" \
  --arg env_pane "${SESSION_WORKSPACE_PANE_NAME:-}" \
  --arg env_role "${SESSION_WORKSPACE_ROLE:-}" \
  --arg env_cwd "${SESSION_WORKSPACE_PANE_CWD:-}" \
  --arg env_mode "${SESSION_WORKSPACE_HARNESS_MODE:-}" \
  --arg chat_alias "${SESSION_CHAT_PANE_NAME:-}" \
  --arg knowledge_alias "${KNOWLEDGE_PANE_NAME:-}" \
  --argjson probe "$PROBE_JSON" '
  . as $plan
  | ([.sessions[] | .panes[] | select(.name == $env_pane)] | .[0] // null) as $pane
  | [$env_config, $env_root, $env_pane, $env_role, $env_cwd] as $core
  | ([$core[] | select(. != "")] | length) as $core_set
  | {
      config_path: $config_path,
      active: .harness.active,
      mode: (.harness.mode // "inactive"),
      profile: (.harness.profile // null),
      roles: (.harness.roles // null),
      gates: (.harness.gates // null),
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
            and (($chat_alias == "" or $chat_alias == $env_pane) and ($knowledge_alias == "" or $knowledge_alias == $env_pane)))
          end
        )
      },
      policy: $probe
    }
')"

if [ "$JSON_MODE" -eq 1 ]; then
  printf '%s\n' "$STATUS_JSON"
  exit 0
fi

printf 'session-workspace harness status — %s\n' "$CONFIG_PATH"
printf '%s\n' "$STATUS_JSON" | jq -r '
  if .active then
    "state: active  mode=\(.mode)  profile=\(.profile)",
    "roles: orchestrator=\(.roles.orchestrator) executor=\(.roles.executor) reviewer=\(.roles.reviewer)",
    "gates: plan-review=\(.gates.plan_review_ttl_minutes)m audit=\(.gates.audit_ttl_minutes)m"
  else
    "state: inactive"
  end,
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
   end)
'
