#!/usr/bin/env bash
# Generic schema-v3/v4 lifecycle reminders. The inactive path is deliberately
# pure bash and silent because UserPromptSubmit runs on every turn.
set -uo pipefail

EVENT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --event) EVENT="${2:-}"; shift 2 ;;
    --codex-hook-output) shift ;;
    *) exit 0 ;;
  esac
done

CONFIG="${SESSION_WORKSPACE_CONFIG:-}"
GUARDS="${SESSION_WORKSPACE_GUARDS_JSON:-}"
[ -n "$CONFIG" ] && [ -n "$GUARDS" ] || exit 0
[ -r "$CONFIG" ] || exit 0
CONFIG_TEXT="$(<"$CONFIG")"
[[ "$CONFIG_TEXT" =~ \"schema_version\"[[:space:]]*:[[:space:]]*(3|4)[[:space:]]*([,}]) ]] || exit 0
case "$EVENT" in
  session) FEATURE='"session_reminder":true'; HOOK_EVENT="SessionStart" ;;
  prompt) FEATURE='"prompt_reminder":true'; HOOK_EVENT="UserPromptSubmit" ;;
  *) exit 0 ;;
esac
case "$GUARDS" in *"$FEATURE"*) : ;; *) exit 0 ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
command -v jq >/dev/null 2>&1 || exit 0
PLAN="$(bash "$HERE/workspace-plan.sh" --config "$CONFIG" --json 2>/dev/null)" || exit 0

ROW="$(printf '%s' "$PLAN" | jq -r --arg pane "${SESSION_WORKSPACE_PANE_NAME:-}" --argjson expected "$GUARDS" '
  select(.harness.active and .harness.guards == $expected)
  | ([.sessions[].panes[] | select(.name == $pane)] | .[0] // null) as $p
  | select($p != null)
  | [($p.name // "unknown"), ($p.role // "unknown"), (.harness.roles.orchestrator // ""), (.harness.roles.executor // ""), (.harness.roles.reviewer // "")] | @tsv
' 2>/dev/null)" || exit 0
[ -n "$ROW" ] || exit 0
IFS=$'\t' read -r PANE ROLE ORCHESTRATOR EXECUTOR REVIEWER <<<"$ROW"

if [ "$EVENT" = session ]; then
  MESSAGE="session-workspace: pane ${PANE} has role ${ROLE}. Keep work within its configured scope; route child implementation through ${EXECUTOR}, independent review through ${REVIEWER}, and cross-repository coordination through ${ORCHESTRATOR}."
else
  MESSAGE="session-workspace reminder: follow the configured ${ORCHESTRATOR}/${EXECUTOR}/${REVIEWER} routing and strict-v1 gates for this turn."
fi

# Claude and Codex consume the same event-specific additionalContext object.
jq -cn --arg event "$HOOK_EVENT" --arg message "$MESSAGE" \
  '{hookSpecificOutput:{hookEventName:$event,additionalContext:$message}}'
