#!/usr/bin/env bash
# task-assign.sh — assign a task to a pane and dispatch via session-chat.
# Usage: task-assign.sh <pane> <id> [--eta MINUTES] [--stage NAME] [--context NAME|auto] [--reviewer PANE] [--workflow ID] [--force] <prompt-text>
# Flags must come before the prompt text.
set -uo pipefail

source "$(dirname "$0")/lib.sh"

require_jq || exit 1
ensure_dirs || exit 1

USAGE="Usage: task-assign.sh <pane> <id> [--eta MINUTES] [--stage NAME] [--context NAME|auto] [--reviewer PANE] [--workflow ID] [--force] <prompt-text>"

PANE="${1:-}"
ID="${2:-}"
shift 2 2>/dev/null || true

# A value-taking flag with nothing after it must error, not spin: under
# `set -u` a failed `shift 2` leaves "$@" unchanged and the loop never ends.
need_value() {
  if [ "$#" -lt 2 ] || [ -z "$2" ]; then
    echo "ERROR: $1 requires a value. $USAGE" >&2
    exit 1
  fi
}

ETA_MIN=""
STAGE=""
CONTEXT=""
REVIEWER=""
WORKFLOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --eta)      need_value "$@"; ETA_MIN="$2"; shift 2 ;;
    --stage)    need_value "$@"; STAGE="$2"; shift 2 ;;
    --context)  need_value "$@"; CONTEXT="$2"; shift 2 ;;
    --reviewer) need_value "$@"; REVIEWER="$2"; shift 2 ;;
    --workflow|--workflow-id) need_value "$@"; WORKFLOW="$2"; shift 2 ;;
    --force)    SESSION_SCHEDULER_FORCE=1; export SESSION_SCHEDULER_FORCE; shift ;;
    *)          break ;;
  esac
done
PROMPT_TEXT="${*:-}"

if [ -z "$PANE" ] || [ -z "$ID" ] || [ -z "$PROMPT_TEXT" ]; then
  echo "ERROR: $USAGE" >&2
  exit 1
fi

validate_task_id "$ID" || exit 1
validate_pane_name "$PANE" "executor pane" || exit 1
[ -n "$REVIEWER" ] && { validate_pane_name "$REVIEWER" "reviewer pane" || exit 1; }
[ -n "$WORKFLOW" ] && { validate_workflow_id "$WORKFLOW" || exit 1; }

if ! task_exists "$ID"; then
  echo "ERROR: task '$ID' not found. Create it first with /task-new." >&2
  exit 1
fi

if [ -n "$ETA_MIN" ] && ! [[ "$ETA_MIN" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --eta expects a positive integer number of minutes, got '$ETA_MIN'." >&2
  exit 1
fi
if [ -n "$STAGE" ]; then
  validate_stage "$STAGE" || exit 1
fi

# Pre-flight: status transition must be legal (or forced) BEFORE we touch the
# prompt file or dispatch anything. (Re-checked inside the lock at commit time.)
CURRENT_STATUS=$(task_get "$ID" '.status')
if ! transition_allowed "$CURRENT_STATUS" "assigned" && ! scheduler_force_enabled; then
  echo "ERROR: illegal status transition '$CURRENT_STATUS' -> 'assigned' for task $ID." >&2
  echo "  current status: $CURRENT_STATUS; legal next: $(legal_targets "$CURRENT_STATUS")" >&2
  echo "  Override with --force (or SESSION_SCHEDULER_FORCE=1)." >&2
  exit 1
fi

# Pre-flight: refuse if any dependency is not done (unless --force).
UNMET=$(unmet_deps "$ID")
if [ -n "$UNMET" ] && ! scheduler_force_enabled; then
  echo "ERROR: task $ID has unmet dependencies:" >&2
  while IFS= read -r dep_line; do
    printf '  %s\n' "$dep_line" >&2
  done <<< "$UNMET"
  echo "Complete them first, or re-run with --force to assign anyway." >&2
  exit 1
fi

# Pre-flight: resolve the context attachment before any side effects.
#   --context NAME  attaches an existing knowledge context snapshot
#                   ($SESSION_CONTEXT_HOME/NAME.md); the executor loads it with
#                   /knowledge:context-load NAME.
#   --context auto  generates a scheduler-owned handoff derived purely from
#                   data this script already holds (the approved prompt + ledger
#                   state) under $SESSION_SCHEDULER_HOME/handoffs/<id>/<nonce>.md.
#                   It never touches the knowledge context store and does not
#                   need SESSION_CONTEXT_HOME. Written below (after the prompt is
#                   known) and removed on dispatch rollback.
CONTEXT_FILE=""
AUTO_CONTEXT=0
CONTEXT_DIR=""
HANDOFF_FILE=""
HANDOFF_TASK_DIR=""
HANDOFF_DIR_PREEXISTED=0
if [ "$CONTEXT" = "auto" ]; then
  AUTO_CONTEXT=1
  HANDOFF_NONCE=$(generate_context_nonce) || exit 1
  HANDOFF_TASK_DIR=$(handoff_dir "$ID")
  [ -d "$HANDOFF_TASK_DIR" ] && HANDOFF_DIR_PREEXISTED=1
  HANDOFF_FILE="$HANDOFF_TASK_DIR/$HANDOFF_NONCE.md"
  if [ -e "$HANDOFF_FILE" ]; then
    echo "ERROR: handoff file $HANDOFF_FILE already exists; handoffs are never overwritten." >&2
    exit 1
  fi
elif [ -n "$CONTEXT" ]; then
  validate_context_name "$CONTEXT" || exit 1
  CONTEXT_DIR="$(resolve_contexts_dir)" || exit 1
  CONTEXT_FILE="$CONTEXT_DIR/$CONTEXT.md"
  if [ ! -f "$CONTEXT_FILE" ]; then
    echo "ERROR: context snapshot '$CONTEXT' not found at $CONTEXT_FILE." >&2
    echo "  Generate it first with /knowledge:context-generate $CONTEXT," >&2
    echo "  or use --context auto to derive a scheduler-owned handoff from this task." >&2
    exit 1
  fi
fi

NAME=$(task_get "$ID" '.name')
ASSIGNER=$(current_pane_name)
PROMPT_FILE=$(prompt_path "$ID")

# Canonical absolute ledger home, embedded in the prompt as PROVENANCE: the
# executor's process must already have this exact value inherited at startup
# (set by the pane launcher). The packet never prints executable export lines —
# if the executor's inherited value is absent or different, it must request a
# relaunch rather than derive another ledger.
SCHED_HOME_ABS=$(abs_dir "$SCHEDULER_DIR")
HANDOFF_HOME_ABS=$(abs_dir "$HANDOFFS_DIR")
CTX_HOME_ABS=""
[ -n "$CONTEXT_DIR" ] && CTX_HOME_ABS=$(abs_dir "$CONTEXT_DIR")
HANDOFF_FILE_ABS=""
[ "$AUTO_CONTEXT" = "1" ] && HANDOFF_FILE_ABS="$HANDOFF_HOME_ABS/$ID/$HANDOFF_NONCE.md"

# If the prompt file already exists (reassignment), back it up so we can
# restore it on dispatch failure; if it's new, delete it on dispatch failure.
PROMPT_BACKUP=""
HAD_PROMPT=0
if [ -f "$PROMPT_FILE" ]; then
  HAD_PROMPT=1
  PROMPT_BACKUP="${PROMPT_FILE}.bak.$$"
  if ! cp "$PROMPT_FILE" "$PROMPT_BACKUP"; then
    echo "ERROR: could not back up existing prompt file $PROMPT_FILE; aborting." >&2
    exit 1
  fi
fi

restore_prompt_on_failure() {
  if [ "$HAD_PROMPT" -eq 1 ]; then
    mv "$PROMPT_BACKUP" "$PROMPT_FILE" 2>/dev/null
  else
    rm -f "$PROMPT_FILE"
  fi
  # A handoff generated for THIS assignment is an artifact of a dispatch that
  # never landed; remove it (and the per-task dir if we created it) so a
  # rolled-back assign leaves nothing behind.
  if [ "$AUTO_CONTEXT" = "1" ]; then
    rm -f "$HANDOFF_FILE" 2>/dev/null
    [ "$HANDOFF_DIR_PREEXISTED" -eq 0 ] && rmdir "$HANDOFF_TASK_DIR" 2>/dev/null
  fi
}

# Build the executor prompt with task header + reply instructions.
cat > "$PROMPT_FILE" <<EOF
Task ${ID}: ${NAME}

${PROMPT_TEXT}

---
Shared scheduler home (provenance): ${SCHED_HOME_ABS}
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

Reply with the form for your runtime (Claude uses /..., Codex uses \$...):
  When done:
    Claude: /session-scheduler:task-done ${ID} [note]
    Codex:  \$session-scheduler:task-done ${ID} [note]
  To request review (e.g. with a commit SHA):
    Claude: /session-scheduler:task-review ${ID} <note>
    Codex:  \$session-scheduler:task-review ${ID} <note>
  If blocked:
    Claude: /session-scheduler:task-block ${ID} <reason>
    Codex:  \$session-scheduler:task-block ${ID} <reason>
EOF

if [ -n "$REVIEWER" ]; then
  cat >> "$PROMPT_FILE" <<EOF

Reviewer: ${REVIEWER} — on /task-review this task is auto-dispatched to them for audit.
EOF
fi

# Generate the auto handoff (derived from the approved prompt + ledger state)
# before dispatch, so a rollback can remove it. The nonce is unique per
# assignment and preflight already refused an existing path, so a prior
# handoff is never overwritten. Body layout is provider-shared (Codex emits the
# identical sections).
if [ "$AUTO_CONTEXT" = "1" ]; then
  if ! mkdir -p "$HANDOFF_TASK_DIR" 2>/dev/null; then
    restore_prompt_on_failure
    echo "ERROR: could not create handoff dir $HANDOFF_TASK_DIR." >&2
    exit 1
  fi
  HO_STAGE="$STAGE"
  [ -z "$HO_STAGE" ] && HO_STAGE=$(task_get "$ID" '.stage // empty')
  HO_REVIEWER="$REVIEWER"
  [ -z "$HO_REVIEWER" ] && HO_REVIEWER=$(task_get "$ID" '.reviewer // empty')
  HO_WORKFLOW="$WORKFLOW"
  [ -z "$HO_WORKFLOW" ] && HO_WORKFLOW=$(task_get "$ID" '.meta.workflow_id // empty')
  HO_DEPS=$(task_get "$ID" '(.depends_on // []) | join(", ")')
  if ! cat > "$HANDOFF_FILE" <<EOF
# Auto handoff — task ${ID}: ${NAME}

Generated by \`/task-assign --context auto\` at dispatch time from the approved
prompt and ledger state (no live-session summarization). Never overwritten:
each assignment writes a new file.

## Task
- id: ${ID}
- name: ${NAME}
- status before assignment: ${CURRENT_STATUS}
- stage: ${HO_STAGE:-(unset)}
- assigner: ${ASSIGNER}
- assignee: ${PANE}
- reviewer: ${HO_REVIEWER:-(none)}
- workflow: ${HO_WORKFLOW:-(none)}
- depends_on: ${HO_DEPS:-(none)}
- shared ledger: ${SCHED_HOME_ABS}

## Dispatched prompt
${PROMPT_TEXT}
EOF
  then
    restore_prompt_on_failure
    echo "ERROR: could not write handoff file $HANDOFF_FILE." >&2
    exit 1
  fi
  chmod 600 "$HANDOFF_FILE" 2>/dev/null || true

  cat >> "$PROMPT_FILE" <<EOF

## Handoff
Auto handoff (read it first): ${HANDOFF_FILE_ABS}
It lives under the shared scheduler home above; the same inherited-environment
contract applies. Read the file directly — it is not a knowledge context snapshot.
EOF
fi

if [ -n "$CONTEXT_DIR" ]; then
  cat >> "$PROMPT_FILE" <<EOF

## Context
Shared context home (provenance): ${CTX_HOME_ABS}
Your process must already have this exact SESSION_CONTEXT_HOME inherited from
startup — the environment contract above applies to it as well. If it is
absent or differs, stop and request a relaunch instead of deriving another
context store.
Load the shared context first (form for your runtime):
  Claude: /knowledge:context-load ${CONTEXT}
  Codex:  \$knowledge:context-load ${CONTEXT}
EOF
fi

if ! session_chat_dispatch "$PANE" "$PROMPT_FILE"; then
  restore_prompt_on_failure
  echo "ERROR: session-chat dispatch to '$PANE' failed; ledger NOT updated, prompt file rolled back." >&2
  exit 1
fi
[ -n "$PROMPT_BACKUP" ] && rm -f "$PROMPT_BACKUP"

# Compute eta_at (now + N minutes) via epoch math; portable across BSD/GNU date.
ETA_AT=""
if [ -n "$ETA_MIN" ]; then
  ETA_AT=$(epoch_to_iso $(($(epoch_now) + ETA_MIN * 60)))
  if [ -z "$ETA_AT" ]; then
    echo "WARN: could not compute eta_at (date arithmetic failed); proceeding without ETA." >&2
  fi
fi

# ONE locked mutation: metadata update + status flip. The lock is taken only
# now — after transport — so a busy-pane dispatch never holds the task lock.
if ! task_lock "$ID"; then
  echo "ERROR: dispatch succeeded but the ledger for $ID could not be locked. Inspect $(task_path "$ID")." >&2
  exit 1
fi
CURRENT_JSON=$(cat "$(task_path "$ID")")
UPDATED_JSON=$(printf '%s' "$CURRENT_JSON" | jq \
  --arg assignee "$PANE" \
  --arg prompt_file "$PROMPT_FILE" \
  --arg eta "$ETA_AT" \
  --arg stage "$STAGE" \
  --arg ctx "$CONTEXT" \
  --arg ctx_home "$CTX_HOME_ABS" \
  --arg handoff_file "$HANDOFF_FILE_ABS" \
  --arg handoff_home "$HANDOFF_HOME_ABS" \
  --arg reviewer "$REVIEWER" \
  --arg workflow "$WORKFLOW" \
  --arg sched_home "$SCHED_HOME_ABS" \
  '.assignee = $assignee
   | .prompt_file = $prompt_file
   | .meta.scheduler_home = $sched_home
   | del(.meta.review_dispatched_at, .meta.review_dispatch_status, .meta.review_dispatch_error, .meta.review_dispatch_attempt_at, .meta.review_last_dispatch_attempt_at, .meta.review_dispatch_attempts, .meta.review_prompt_file)
   | .meta |= (if type == "object" then with_entries(select((.key | startswith("review_")) | not)) else . end)
   | with_entries(select((.key | startswith("review_")) | not))
   | (if $eta != "" then .eta_at = $eta else . end)
   | (if $stage != "" then .stage = $stage else . end)
   | (if $handoff_file != ""
      then .meta.handoff_file = $handoff_file | .meta.handoff_home = $handoff_home
           | del(.meta.context, .meta.context_home)
      elif $ctx != ""
      then .meta.context = $ctx | .meta.context_home = $ctx_home
           | del(.meta.handoff_file, .meta.handoff_home)
      else del(.meta.context, .meta.context_home, .meta.handoff_file, .meta.handoff_home) end)
   | (if $reviewer != "" then .reviewer = $reviewer else . end)
   | (if $workflow != "" then .meta.workflow_id = $workflow else . end)')
if ! task_write "$ID" "$UPDATED_JSON"; then
  task_unlock "$ID"
  echo "ERROR: dispatch succeeded but ledger update failed for $ID. Inspect $(task_path "$ID")." >&2
  exit 1
fi
if ! task_set_status_unlocked "$ID" "assigned" "$ASSIGNER" "dispatched to $PANE"; then
  task_unlock "$ID"
  echo "ERROR: dispatch succeeded but status update failed for $ID. Inspect $(task_path "$ID")." >&2
  exit 1
fi
task_unlock "$ID"

echo "Assigned task $ID ($NAME) to $PANE."
echo "  prompt:   $PROMPT_FILE"
echo "  status:   assigned"
echo "  ledger:   $SCHED_HOME_ABS"
[ -n "$STAGE" ]    && echo "  stage:    $STAGE"
[ -n "$ETA_AT" ]   && echo "  eta:      $ETA_AT (${ETA_MIN}m)"
[ "$AUTO_CONTEXT" = "1" ] && echo "  handoff:  $HANDOFF_FILE_ABS"
[ -n "$CONTEXT_DIR" ] && echo "  context:  $CONTEXT"
[ -n "$REVIEWER" ] && echo "  reviewer: $REVIEWER (auto-dispatched on /task-review)"
[ -n "$WORKFLOW" ] && echo "  workflow: $WORKFLOW"
echo
echo "Track with: /task-status $ID"
