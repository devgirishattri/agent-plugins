#!/usr/bin/env bash
# harness-doctor.sh — read-only dependency/config/identity checks for the
# opt-in harness. Never repairs anything.
#
# Checks (OK / INFO / WARN / ERROR):
#   config.validation   workspace config validates and a plan resolves
#   harness.activation  strict-v1 enabled (OK) or inactive (INFO)
#   hook.registration   hooks/hooks.json registers the PreToolUse hook
#   runtime.python3     required only while a harness is active
#   identity.env        engine identity present/complete/partial in THIS process
#   identity.alias      SESSION_CHAT_PANE_NAME / KNOWLEDGE_PANE_NAME agree with it
#   identity.live       what the policy ITSELF decides for this process (the
#                       same probe harness-status.sh reports as "policy"):
#                       OK when active and accepted, ERROR when it would block
#                       every gated call here, INFO when the hook is a no-op,
#                       WARN when it cannot be probed
#
# Usage: harness-doctor.sh [--config PATH] [--json]
# Exit status: non-zero only when at least one check is ERROR. --json always
# emits one structured report, including when config validation fails.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONFIG_OVERRIDE=""
JSON_MODE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_OVERRIDE="${2:-}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help)
      echo "Usage: harness-doctor.sh [--config PATH] [--json]"
      exit 0
      ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done

CHECKS='[]'
add_check() {
  local id="$1" status="$2" detail="$3"
  CHECKS="$(printf '%s' "$CHECKS" | jq --arg id "$id" --arg status "$status" --arg detail "$detail" '. + [{id:$id,status:$status,detail:$detail}]')"
}

emit_report() {
  local status_json="$1"
  local errors
  errors="$(printf '%s' "$CHECKS" | jq '[.[] | select(.status == "ERROR")] | length')"
  local report
  report="$(jq -n --argjson status "$status_json" --argjson checks "$CHECKS" --argjson errors "$errors" '{status:$status,checks:$checks,summary:{errors:$errors}}')"
  if [ "$JSON_MODE" -eq 1 ]; then
    printf '%s\n' "$report"
  else
    printf 'session-workspace harness doctor\n'
    printf '%s\n' "$CHECKS" | jq -r '.[] | "  [\(.status)] \(.id) — \(.detail)"'
    printf 'summary: %s error(s)\n' "$errors"
  fi
  [ "$errors" -eq 0 ]
}

STATUS_ARGS=()
[ -n "$CONFIG_OVERRIDE" ] && STATUS_ARGS+=(--config "$CONFIG_OVERRIDE")
STATUS_ARGS+=(--json)
if ! STATUS_JSON="$(bash "$HERE/harness-status.sh" "${STATUS_ARGS[@]}" 2>&1)"; then
  # Structured even on failure: the config could not be validated, so every
  # later check is skipped rather than run against untrusted data.
  DETAIL="$(printf '%s' "$STATUS_JSON" | tr '\n' ' ' | cut -c1-600)"
  add_check "config.validation" ERROR "workspace config/plan validation failed: $DETAIL"
  emit_report "null"
  exit 1
fi

ACTIVE="$(printf '%s' "$STATUS_JSON" | jq -r '.active')"
ID_PRESENT="$(printf '%s' "$STATUS_JSON" | jq -r '.identity.present')"
ID_COMPLETE="$(printf '%s' "$STATUS_JSON" | jq -r '.identity.complete')"
ID_PARTIAL="$(printf '%s' "$STATUS_JSON" | jq -r '.identity.partial')"
# jq's // treats false as absent, so null-vs-false must be spelled out.
ID_MATCH="$(printf '%s' "$STATUS_JSON" | jq -r 'if .identity.matches == null then "none" else (.identity.matches | tostring) end')"
ALIAS_AGREE="$(printf '%s' "$STATUS_JSON" | jq -r '.identity.aliases.agree')"
PROBE_ACTIVE="$(printf '%s' "$STATUS_JSON" | jq -r 'if .policy == null then "none" else (.policy.active | tostring) end')"
PROBE_DECISION="$(printf '%s' "$STATUS_JSON" | jq -r '.policy.decision // ""')"
PROBE_RULE="$(printf '%s' "$STATUS_JSON" | jq -r '.policy.rule // ""')"
PROBE_REASON="$(printf '%s' "$STATUS_JSON" | jq -r '.policy.reason // ""')"

add_check "config.validation" OK "workspace config and normalized plan validate"
if [ "$ACTIVE" = true ]; then
  add_check "harness.activation" OK "strict-v1 is explicitly enabled"
else
  add_check "harness.activation" INFO "harness is inactive; hook execution is a no-op"
fi

if [ -f "$HERE/../hooks/hooks.json" ] && jq -e '
  [.hooks.PreToolUse, .hooks.SessionStart, .hooks.UserPromptSubmit, .hooks.Stop]
  | all(type == "array" and length > 0)
' "$HERE/../hooks/hooks.json" >/dev/null 2>&1; then
  add_check "hook.registration" OK "bundled hooks/hooks.json registers PreToolUse, SessionStart, UserPromptSubmit, and Stop (file check only; provider trust/loading not verifiable here)"
else
  add_check "hook.registration" ERROR "hooks/hooks.json is missing or invalid"
fi

GUARDS_COUNT="$(printf '%s' "$STATUS_JSON" | jq '.guards // {} | length')"
if [ "$GUARDS_COUNT" -gt 0 ]; then
  add_check "guards.configuration" OK "schema-v3/v4 guard packs validate and are exposed by the normalized plan"
else
  add_check "guards.configuration" INFO "no schema-v3/v4 guard packs configured"
fi

if [ "$ACTIVE" = true ]; then
  if command -v python3 >/dev/null 2>&1; then
    add_check "runtime.python3" OK "python3 is available for active strict-v1 policy"
  else
    add_check "runtime.python3" ERROR "active strict-v1 policy requires python3; every gated call fails closed without it"
  fi
else
  add_check "runtime.python3" INFO "python3 is not required while the harness is inactive"
fi

if [ "$ID_PRESENT" = false ]; then
  add_check "identity.env" INFO "no workspace engine identity is inherited by this process"
elif [ "$ID_COMPLETE" = true ]; then
  add_check "identity.env" OK "all engine identity variables are present"
else
  add_check "identity.env" ERROR "engine identity is PARTIAL (some SESSION_WORKSPACE_* variables missing); an active policy fails closed on this"
fi

if [ "$ID_PRESENT" = false ]; then
  add_check "identity.alias" INFO "no pane-name aliases to compare"
elif [ "$ALIAS_AGREE" = true ]; then
  add_check "identity.alias" OK "SESSION_CHAT_PANE_NAME / KNOWLEDGE_PANE_NAME agree with the engine pane name"
else
  add_check "identity.alias" ERROR "SESSION_CHAT_PANE_NAME or KNOWLEDGE_PANE_NAME disagrees with SESSION_WORKSPACE_PANE_NAME; an active policy fails closed on this"
fi

# identity.live is decided by the policy probe, never by a parallel
# re-implementation: the probe ran harness-policy.py in this very process.
if [ "$PROBE_ACTIVE" = "none" ]; then
  if [ "$ID_PRESENT" = true ]; then
    add_check "identity.live" WARN "could not probe the policy (python3 unavailable); identity present but unverified"
  else
    add_check "identity.live" INFO "policy not probed (python3 unavailable) and no identity present"
  fi
elif [ "$PROBE_ACTIVE" = false ]; then
  if [ "$ID_PARTIAL" = true ]; then
    add_check "identity.live" WARN "hook is a no-op in this process only because identity is partial/unlaunched ($PROBE_REASON)"
  elif [ "$ID_PRESENT" = true ] && [ "$ID_MATCH" != true ]; then
    add_check "identity.live" WARN "hook is a no-op here (harness inactive) but the inherited identity does not match this config; restart the pane before enabling the harness"
  else
    add_check "identity.live" INFO "hook is a no-op in this process ($PROBE_REASON)"
  fi
elif [ "$PROBE_DECISION" = "allow" ]; then
  add_check "identity.live" OK "policy accepts this process's identity (strict-v1 active)"
else
  add_check "identity.live" ERROR "policy BLOCKS every gated call in this process [$PROBE_RULE]: $PROBE_REASON — restart the pane via workspace restart"
fi

emit_report "$STATUS_JSON"
