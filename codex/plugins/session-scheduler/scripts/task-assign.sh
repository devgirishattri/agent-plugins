#!/usr/bin/env bash
# task-assign.sh — Assign a scheduler task to a named pane through session-chat
# Usage: task-assign.sh <pane> <task-id> [--eta MINUTES] [--stage NAME] [--context NAME|auto] [--reviewer PANE] [--workflow ID] [--force] <prompt>
# Flags must come before the prompt text.
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

if [ "$#" -lt 3 ]; then
  echo "ERROR: Usage: task-assign.sh <pane> <task-id> [--eta MINUTES] [--stage NAME] [--context NAME|auto] [--reviewer PANE] [--workflow ID] [--force] <prompt>" >&2
  exit 1
fi

require_jq || exit 1
ensure_dirs || exit 1

ASSIGNEE="$1"
ID="$2"
shift 2

ETA_MIN=""
STAGE=""
CONTEXT=""
REVIEWER_OVERRIDE=""
WORKFLOW_ID_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --eta|--stage|--context|--reviewer|--workflow|--workflow-id)
      require_flag_value "$@" || exit 1 ;;
  esac
  case "$1" in
    --eta)     ETA_MIN="${2:-}"; shift 2 ;;
    --stage)   STAGE="${2:-}"; shift 2 ;;
    --context) CONTEXT="${2:-}"; shift 2 ;;
    --reviewer) REVIEWER_OVERRIDE="${2:-}"; shift 2 ;;
    --workflow|--workflow-id) WORKFLOW_ID_OVERRIDE="${2:-}"; shift 2 ;;
    --force)   SESSION_SCHEDULER_FORCE=1; export SESSION_SCHEDULER_FORCE; shift ;;
    *)         break ;;
  esac
done
PROMPT="$*"

if [ -z "$PROMPT" ]; then
  echo "ERROR: Prompt text is required (flags must come before the prompt)." >&2
  exit 1
fi

FILE=$(task_file "$ID") || exit 1
if [ ! -f "$FILE" ]; then
  echo "ERROR: Task not found: $ID" >&2
  exit 1
fi

if [ -n "$ETA_MIN" ] && ! [[ "$ETA_MIN" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --eta expects a positive integer number of minutes, got: $ETA_MIN" >&2
  exit 1
fi
if [ -n "$STAGE" ]; then
  validate_stage "$STAGE" || exit 1
fi
if [ -n "$REVIEWER_OVERRIDE" ]; then
  validate_route_name "reviewer pane" "$REVIEWER_OVERRIDE" || exit 1
fi
if [ -n "$WORKFLOW_ID_OVERRIDE" ]; then
  validate_route_name "workflow id" "$WORKFLOW_ID_OVERRIDE" || exit 1
fi

# Pre-flight: status transition must be legal (or forced) BEFORE we touch the
# prompt file or dispatch anything.
CURRENT_STATUS=$(jq -r '.status // ""' "$FILE")
if ! transition_allowed "$CURRENT_STATUS" "assigned" && ! scheduler_force_enabled; then
  echo "ERROR: Illegal status transition '$CURRENT_STATUS' -> 'assigned' for task $ID." >&2
  echo "Current status: $CURRENT_STATUS; legal next: $(legal_targets "$CURRENT_STATUS")" >&2
  echo "Override with --force or SESSION_SCHEDULER_FORCE=1." >&2
  exit 1
fi

# Pre-flight: refuse if any dependency is not done (unless --force).
UNMET=$(unmet_deps "$ID")
if [ -n "$UNMET" ] && ! scheduler_force_enabled; then
  echo "ERROR: Task $ID has unmet dependencies:" >&2
  while IFS= read -r dep_line; do
    printf '  %s\n' "$dep_line" >&2
  done <<< "$UNMET"
  echo "Complete them first, or re-run with --force to assign anyway." >&2
  exit 1
fi

# Pre-flight: resolve session-chat and the context snapshot before
# assignment side effects. `--context auto` creates a task-scoped handoff only
# after all other pre-flight checks pass.
CHAT_ROOT=$(session_chat_root) || exit 1
TASK_NAME=$(jq -r '.name' "$FILE")
CONTEXT_FILE=""
AUTO_CONTEXT_FILE=""
if [ -n "$CONTEXT" ] && [ "$CONTEXT" != "auto" ]; then
  # Validate an explicit name before resolving the store or creating any
  # assignment artifacts. `auto` is the sole scheduler-owned sentinel.
  if [ "$CONTEXT" != "auto" ]; then
    validate_context_name "$CONTEXT" || exit 1
  fi
  CONTEXT_DIR="$(resolve_contexts_dir)" || exit 1
  CONTEXT_FILE="$CONTEXT_DIR/$CONTEXT.md"
  if [ ! -f "$CONTEXT_FILE" ]; then
    echo "ERROR: Context snapshot '$CONTEXT' not found at $CONTEXT_FILE." >&2
    echo "Generate it first with \$knowledge:context-generate $CONTEXT." >&2
    exit 1
  fi
fi

ASSIGNER=$(current_pane_name)
[ -z "$ASSIGNER" ] && ASSIGNER=$(jq -r '.assigner // "?"' "$FILE")
[ -n "$ASSIGNER" ] || ASSIGNER="?"
PROMPT_FILE=$(prompt_file "$ID") || exit 1
REVIEWER=$(jq -r '.reviewer // empty' "$FILE")
WORKFLOW_ID=$(jq -r '.meta.workflow_id // .workflow_id // empty' "$FILE")
[ -n "$REVIEWER_OVERRIDE" ] && REVIEWER="$REVIEWER_OVERRIDE"
[ -n "$WORKFLOW_ID_OVERRIDE" ] && WORKFLOW_ID="$WORKFLOW_ID_OVERRIDE"
SCHEDULER_HOME_ABS=$(absolute_existing_dir "$SCHEDULER_DIR") || exit 1
CONTEXT_HOME_ABS=""
if [ -n "$CONTEXT" ] && [ "$CONTEXT" != "auto" ]; then
  CONTEXT_HOME_ABS=$(absolute_existing_dir "$CONTEXT_DIR") || exit 1
fi
# If the prompt file already exists (reassignment), back it up so we can
# restore it on dispatch failure; if it is new, delete it on dispatch failure.
PROMPT_BACKUP=""
HAD_PROMPT=0
if [ -f "$PROMPT_FILE" ]; then
  HAD_PROMPT=1
  PROMPT_BACKUP="${PROMPT_FILE}.bak.$$"
  cp "$PROMPT_FILE" "$PROMPT_BACKUP" || {
    [ -n "$AUTO_CONTEXT_FILE" ] && rm -f "$AUTO_CONTEXT_FILE"
    echo "ERROR: Could not back up existing prompt file $PROMPT_FILE; aborting." >&2
    exit 1
  }
fi

restore_prompt_on_failure() {
  [ "${PROMPT_RESTORED:-0}" = 0 ] || return 0
  PROMPT_RESTORED=1
  if [ "$HAD_PROMPT" -eq 1 ]; then
    mv "$PROMPT_BACKUP" "$PROMPT_FILE" 2>/dev/null
  else
    rm -f "$PROMPT_FILE"
  fi
  [ -n "$AUTO_CONTEXT_FILE" ] && rm -f "$AUTO_CONTEXT_FILE"
  [ -n "$AUTO_CONTEXT_FILE" ] && rmdir "$(dirname "$AUTO_CONTEXT_FILE")" 2>/dev/null || true
  [ -n "${HANDOFF_TASK_DIR:-}" ] && rmdir "$HANDOFF_TASK_DIR" 2>/dev/null || true
}

DISPATCH_SUCCEEDED=0
trap '[ "$DISPATCH_SUCCEEDED" = 1 ] || restore_prompt_on_failure' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

HANDOFF_HOME_ABS=""
if [ "$CONTEXT" = "auto" ]; then
  HANDOFF_HOME_ABS=$(absolute_existing_dir "$HANDOFFS_DIR") || exit 1
  HANDOFF_TASK_DIR="$HANDOFF_HOME_ABS/$ID"
  [ ! -L "$HANDOFF_TASK_DIR" ] || { echo "ERROR: unsafe handoff directory" >&2; exit 1; }
  mkdir -p "$HANDOFF_TASK_DIR" || exit 1
  _scheduler_safe_dir "$HANDOFF_TASK_DIR" || exit 1
  AUTO_CONTEXT_NONCE=$(generate_context_nonce) || exit 1
  AUTO_CONTEXT_FILE="$HANDOFF_TASK_DIR/$AUTO_CONTEXT_NONCE.md"
  HANDOFF_STAGE="${STAGE:-$(jq -r '.stage // "(unset)"' "$FILE")}"
  HANDOFF_STAGE="${HANDOFF_STAGE:-(unset)}"
  HANDOFF_DEPS=$(jq -r '(.depends_on // []) | if length == 0 then "(none)" else join(", ") end' "$FILE")
  if ! (set -o noclobber; : > "$AUTO_CONTEXT_FILE") 2>/dev/null; then
    echo "ERROR: refusing existing handoff path: $AUTO_CONTEXT_FILE" >&2
    AUTO_CONTEXT_FILE=""
    restore_prompt_on_failure
    exit 1
  fi
  if ! cat > "$AUTO_CONTEXT_FILE" <<EOF
# Auto handoff — task $ID: $TASK_NAME

Generated by \`/task-assign --context auto\` at dispatch time from the approved
prompt and ledger state (no live-session summarization). Never overwritten:
each assignment writes a new file.

## Task
- id: $ID
- name: $TASK_NAME
- status before assignment: $CURRENT_STATUS
- stage: $HANDOFF_STAGE
- assigner: $ASSIGNER
- assignee: $ASSIGNEE
- reviewer: ${REVIEWER:-(none)}
- workflow: ${WORKFLOW_ID:-(none)}
- depends_on: $HANDOFF_DEPS
- shared ledger: $SCHEDULER_HOME_ABS

## Dispatched prompt
$PROMPT
EOF
  then
    echo "ERROR: could not create never overwritten handoff: $AUTO_CONTEXT_FILE" >&2
    restore_prompt_on_failure
    exit 1
  fi
fi

if ! cat > "$PROMPT_FILE" <<EOF
Task ID: $ID
Task Name: $TASK_NAME
Assigned To: $ASSIGNEE
Reviewer: ${REVIEWER:-(none)}
Workflow: ${WORKFLOW_ID:-(none)}
Shared scheduler home (provenance): $SCHEDULER_HOME_ABS

$PROMPT

Environment contract:
- The shared home paths in this packet are provenance and relaunch guidance,
  not commands to run.
- Your process must already have these exact values inherited in its
  environment from startup (the pane/session launcher sets them before the
  agent starts).
- Invoke scheduler skills/helpers as ONE literal Bash segment:
  bash "<installed session-scheduler plugin root>/scripts/<helper>.sh" ...
- Do not run export, do not prefix the helper with env or variable
  assignments, and do not combine it with any other shell segment (no
  chaining, pipelines, redirection, or command/process substitution).
- If the inherited values are absent or differ, stop and request a relaunch of
  this pane with the correct environment instead of deriving another ledger.

Transport contract:
- Scheduler helpers can dispatch or notify through nested session-chat/tmux
  after updating the ledger.
- In a sandboxed runtime, request scoped escalation/approval for the exact
  installed helper on the first attempt; keep it one literal Bash segment and
  never work around the sandbox with bash -c, wrappers, env, exports, or broad
  provider-home access. Escalation is transport access, not authority — role,
  recipient, argument, confirmation, and lifecycle policies remain in force.
- If notification fails after a state transition, inspect task-status first:
  never rerun task-done or task-block once the task is done/blocked, and never
  use --force to repair a notification. Report the partial success and, only
  when authorized, send a separate exact session-chat message instead.
- task-review may retry dispatch only while the task is in review with no
  successful reviewer-dispatch timestamp; never duplicate a delivered packet.

When complete, report with either provider form:
Codex:  \$session-scheduler:task-done $ID <summary>
Claude: /session-scheduler:task-done $ID <summary>

To request review (e.g. with a commit SHA), use either provider form:
Codex:  \$session-scheduler:task-review $ID <note>
Claude: /session-scheduler:task-review $ID <note>

If blocked, use either provider form:
Codex:  \$session-scheduler:task-block $ID <reason>
Claude: /session-scheduler:task-block $ID <reason>
EOF
then
  restore_prompt_on_failure
  exit 1
fi

if [ "$CONTEXT" = "auto" ]; then
  if ! cat >> "$PROMPT_FILE" <<EOF

## Handoff
Auto handoff (read it first): $AUTO_CONTEXT_FILE
It lives under the shared scheduler home above; the same inherited-environment
contract applies. Read the file directly — it is not a knowledge context snapshot.
EOF
  then restore_prompt_on_failure; exit 1; fi
elif [ -n "$CONTEXT" ]; then
  if ! cat >> "$PROMPT_FILE" <<EOF

## Context
Shared context home (provenance): $CONTEXT_HOME_ABS
Load the shared context first with either provider form:
Codex:  \$knowledge:context-load $CONTEXT
Claude: /knowledge:context-load $CONTEXT
EOF
  then restore_prompt_on_failure; exit 1; fi
fi

if ! bash "$CHAT_ROOT/scripts/dispatch-to-session.sh" "$ASSIGNEE" "$PROMPT_FILE"; then
  restore_prompt_on_failure
  echo "ERROR: session-chat dispatch to '$ASSIGNEE' failed; ledger NOT updated, prompt file rolled back." >&2
  exit 1
fi
DISPATCH_SUCCEEDED=1
[ -n "$PROMPT_BACKUP" ] && rm -f "$PROMPT_BACKUP"

# Compute eta_at (now + N minutes) via epoch math; portable across BSD/GNU date.
ETA_AT=""
if [ -n "$ETA_MIN" ]; then
  ETA_AT=$(epoch_to_iso $(($(now_epoch) + ETA_MIN * 60)))
  [ -z "$ETA_AT" ] && echo "WARN: Could not compute eta_at (date arithmetic failed); proceeding without ETA." >&2
fi

# Every successful assignment starts a fresh review-dispatch cycle. Clear the
# prior cycle's transport metadata so a later failed review can be retried even
# after an earlier review was successfully dispatched and then rejected.
lock_task_for_command "$ID" || exit 1
[ -f "$FILE" ] || { echo "ERROR: dispatch succeeded but task disappeared: $ID" >&2; exit 1; }
CURRENT_STATUS=$(jq -r '.status' "$FILE")
if ! transition_allowed "$CURRENT_STATUS" assigned && ! scheduler_force_enabled; then
  echo "ERROR: dispatch succeeded but task changed to $CURRENT_STATUS; assignment not committed." >&2
  exit 1
fi
jq \
  --arg assignee "$ASSIGNEE" \
  --arg assigner "$ASSIGNER" \
  --arg prompt_file "$PROMPT_FILE" \
  --arg eta "$ETA_AT" \
  --arg stage "$STAGE" \
  --arg ctx "$CONTEXT" \
  --arg reviewer "$REVIEWER_OVERRIDE" \
  --arg workflow "$WORKFLOW_ID_OVERRIDE" \
  --arg scheduler_home "$SCHEDULER_HOME_ABS" \
  --arg context_home "$CONTEXT_HOME_ABS" \
  --arg handoff "$AUTO_CONTEXT_FILE" \
  --arg handoff_home "$HANDOFF_HOME_ABS" \
  --arg now "$(now_iso)" \
  --arg note "$PROMPT$(if ! transition_allowed "$CURRENT_STATUS" assigned; then printf ' (forced)'; fi)" \
  '.assignee=$assignee
   | .assigner=(if (.assigner // "") == "" then $assigner else .assigner end)
   | .prompt_file=$prompt_file
   | (if $eta != "" then .eta_at=$eta else . end)
   | (if $stage != "" then .stage=$stage else . end)
   | (.meta //= {})
   | (if $ctx == "auto" then
        del(.meta.context, .meta.context_home)
        | .meta.handoff_file=$handoff | .meta.handoff_home=$handoff_home
      elif $ctx != "" then
        del(.meta.handoff_file, .meta.handoff_home)
        | .meta.context=$ctx | .meta.context_home=$context_home
      else del(.meta.context, .meta.context_home, .meta.handoff_file, .meta.handoff_home) end)
   | (if $reviewer != "" then .reviewer=$reviewer else . end)
   | .meta.workflow_id=(if $workflow == "" then (.meta.workflow_id // .workflow_id // null) else $workflow end)
   | .meta.scheduler_home=$scheduler_home
   | .status="assigned" | .updated_at=$now
   | (if .started_at == null then .started_at=$now else . end)
   | .history += [{ts:$now,event:"assigned",actor:$assigner,note:$note}]
   | del(.workflow_id, .scheduler_home, .context_home,
         .meta.review_prompt_file, .meta.review_dispatched_at,
         .meta.review_dispatch_status, .meta.review_dispatch_attempt_at,
         .meta.review_last_dispatch_attempt_at, .meta.review_dispatch_attempts,
         .meta.review_dispatch_error,
         .review_prompt_file, .review_dispatched_at,
         .review_dispatch_status, .review_dispatch_attempt_at,
         .review_last_dispatch_attempt_at, .review_dispatch_attempts,
         .review_dispatch_error)' \
  "$FILE" | write_json_atomic "$FILE" || exit 1

echo "Assigned task $ID to $ASSIGNEE"
[ -n "$STAGE" ]   && echo "Stage: $STAGE"
[ -n "$ETA_AT" ]  && echo "ETA: $ETA_AT (${ETA_MIN}m)"
if [ "$CONTEXT" = "auto" ]; then
  echo "  handoff:  $AUTO_CONTEXT_FILE"
elif [ -n "$CONTEXT" ]; then
  echo "  context:  $CONTEXT"
fi
[ -n "$REVIEWER" ] && echo "Reviewer: $REVIEWER"
[ -n "$WORKFLOW_ID" ] && echo "Workflow: $WORKFLOW_ID"
echo "Scheduler home: $SCHEDULER_HOME_ABS"
exit 0
