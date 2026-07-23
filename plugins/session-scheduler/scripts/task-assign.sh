#!/usr/bin/env bash
# task-assign.sh — assign a task to a pane and dispatch via session-chat.
# Usage: task-assign.sh <pane> <id> [--eta MINUTES] [--stage NAME] [--context NAME] [--force] <prompt-text>
# Flags must come before the prompt text.
set -uo pipefail

source "$(dirname "$0")/lib.sh"

require_jq || exit 1
ensure_dirs || exit 1

PANE="${1:-}"
ID="${2:-}"
shift 2 2>/dev/null || true

ETA_MIN=""
STAGE=""
CONTEXT=""
REVIEWER=""
WORKFLOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --eta)      ETA_MIN="${2:-}"; shift 2 ;;
    --stage)    STAGE="${2:-}"; shift 2 ;;
    --context)  CONTEXT="${2:-}"; shift 2 ;;
    --reviewer) REVIEWER="${2:-}"; shift 2 ;;
    --workflow|--workflow-id) WORKFLOW="${2:-}"; shift 2 ;;
    --force)    SESSION_SCHEDULER_FORCE=1; export SESSION_SCHEDULER_FORCE; shift ;;
    *)          break ;;
  esac
done
PROMPT_TEXT="${*:-}"

if [ -z "$PANE" ] || [ -z "$ID" ] || [ -z "$PROMPT_TEXT" ]; then
  echo "ERROR: Usage: task-assign.sh <pane> <id> [--eta MINUTES] [--stage NAME] [--context NAME] [--reviewer PANE] [--workflow ID] [--force] <prompt-text>" >&2
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
# prompt file or dispatch anything.
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

# Pre-flight: resolve the context snapshot before any side effects.
# --context auto is a special value: instead of requiring a pre-existing
# snapshot, the assignment generates a private, immutable handoff derived purely
# from data this script already holds (the approved prompt + ledger state) — no
# live-session summarization, so it is safe to produce from a shell script. The
# generated file is written below (after the prompt is known) and removed on
# dispatch rollback. CONTEXT_NAME is what the executor actually loads.
CONTEXT_FILE=""
AUTO_CONTEXT=0
CONTEXT_NAME="$CONTEXT"
CONTEXT_DIR=""
if [ -n "$CONTEXT" ]; then
  CONTEXT_DIR="$(resolve_contexts_dir)" || exit 1
  if [ "$CONTEXT" = "auto" ]; then
    AUTO_CONTEXT=1
    # Unique per assignment so the handoff is genuinely immutable: a later
    # (re)assignment mints a NEW file rather than overwriting a prior one that a
    # reviewer/executor may still be reading. The random suffix also means we
    # never clobber an existing snapshot.
    CONTEXT_NAME="auto-$ID-$(generate_task_id)"
    CONTEXT_FILE="$CONTEXT_DIR/$CONTEXT_NAME.md"
    if [ -e "$CONTEXT_FILE" ]; then
      echo "ERROR: auto-context file $CONTEXT_FILE already exists; refusing to overwrite an immutable handoff." >&2
      exit 1
    fi
  else
    if ! [[ "$CONTEXT" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      echo "ERROR: invalid context name '$CONTEXT' (alphanumeric, _, - only)." >&2
      exit 1
    fi
    CONTEXT_FILE="$CONTEXT_DIR/$CONTEXT.md"
    if [ ! -f "$CONTEXT_FILE" ]; then
      echo "ERROR: context snapshot '$CONTEXT' not found at $CONTEXT_FILE." >&2
      echo "  Generate it first with /knowledge:context-generate $CONTEXT," >&2
      echo "  or use --context auto to derive an immutable handoff from this task." >&2
      exit 1
    fi
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
CTX_HOME_ABS=""
[ -n "$CONTEXT" ] && CTX_HOME_ABS=$(abs_dir "$CONTEXT_DIR")

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
  # An auto handoff generated for THIS assignment is an artifact of a dispatch
  # that never landed; remove it so a rolled-back assign leaves nothing behind.
  # (chmod 400 doesn't block owner rm in a writable dir.)
  [ "$AUTO_CONTEXT" = "1" ] && rm -f "$CONTEXT_FILE" 2>/dev/null
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

# Generate the immutable auto handoff (derived from the approved prompt + ledger
# state) before dispatch, so a rollback can remove it. Owner read-only (0400)
# marks it immutable; the name is unique per assignment and preflight already
# refused to overwrite an existing file, so we never clobber a prior handoff.
if [ "$AUTO_CONTEXT" = "1" ]; then
  mkdir -p "$CONTEXT_DIR" 2>/dev/null || true
  cat > "$CONTEXT_FILE" <<EOF
# Auto handoff — task ${ID}: ${NAME}

Immutable snapshot generated by \`/task-assign --context auto\` at dispatch time,
from the approved prompt and ledger state (no live-session summarization). Load
with: /knowledge:context-load ${CONTEXT_NAME}

## Task
- id: ${ID}
- name: ${NAME}
- stage: ${STAGE:-(unset)}
- assigner: ${ASSIGNER}
- assignee: ${PANE}
- shared ledger: ${SCHED_HOME_ABS}

## Dispatched prompt
${PROMPT_TEXT}
EOF
  chmod 400 "$CONTEXT_FILE" 2>/dev/null || true
fi

if [ -n "$CONTEXT" ]; then
  cat >> "$PROMPT_FILE" <<EOF

## Context
Shared context home (provenance): ${CTX_HOME_ABS}
Your process must already have this exact SESSION_CONTEXT_HOME inherited from
startup — the environment contract above applies to it as well. If it is
absent or differs, stop and request a relaunch instead of deriving another
context store.
Load the shared context first (form for your runtime):
  Claude: /knowledge:context-load ${CONTEXT_NAME}
  Codex:  \$knowledge:context-load ${CONTEXT_NAME}
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

CURRENT_JSON=$(cat "$(task_path "$ID")")
UPDATED_JSON=$(printf '%s' "$CURRENT_JSON" | jq \
  --arg assignee "$PANE" \
  --arg prompt_file "$PROMPT_FILE" \
  --arg eta "$ETA_AT" \
  --arg stage "$STAGE" \
  --arg ctx "$CONTEXT_NAME" \
  --arg reviewer "$REVIEWER" \
  --arg workflow "$WORKFLOW" \
  --arg sched_home "$SCHED_HOME_ABS" \
  --arg ctx_home "$CTX_HOME_ABS" \
  '.assignee = $assignee
   | .prompt_file = $prompt_file
   | .meta.scheduler_home = $sched_home
   | del(.meta.review_dispatched_at, .meta.review_dispatch_status, .meta.review_dispatch_error, .meta.review_dispatch_attempt_at, .meta.review_last_dispatch_attempt_at, .meta.review_dispatch_attempts, .meta.review_prompt_file)
   | .meta |= (if type == "object" then with_entries(select((.key | startswith("review_")) | not)) else . end)
   | with_entries(select((.key | startswith("review_")) | not))
   | (if $eta != "" then .eta_at = $eta else . end)
   | (if $stage != "" then .stage = $stage else . end)
   | (if $ctx != "" then .meta.context = $ctx else . end)
   | (if $ctx_home != "" then .meta.context_home = $ctx_home else . end)
   | (if $reviewer != "" then .reviewer = $reviewer else . end)
   | (if $workflow != "" then .meta.workflow_id = $workflow else . end)')
if ! task_write "$ID" "$UPDATED_JSON"; then
  echo "ERROR: dispatch succeeded but ledger update failed for $ID. Inspect $(task_path "$ID")." >&2
  exit 1
fi
if ! task_set_status "$ID" "assigned" "$ASSIGNER" "dispatched to $PANE"; then
  echo "ERROR: dispatch succeeded but status update failed for $ID. Inspect $(task_path "$ID")." >&2
  exit 1
fi

echo "Assigned task $ID ($NAME) to $PANE."
echo "  prompt:   $PROMPT_FILE"
echo "  status:   assigned"
echo "  ledger:   $SCHED_HOME_ABS"
[ -n "$STAGE" ]    && echo "  stage:    $STAGE"
[ -n "$ETA_AT" ]   && echo "  eta:      $ETA_AT (${ETA_MIN}m)"
[ -n "$CONTEXT" ]  && echo "  context:  $CONTEXT_NAME$([ "$AUTO_CONTEXT" = "1" ] && echo ' (auto, immutable)')"
[ -n "$REVIEWER" ] && echo "  reviewer: $REVIEWER (auto-dispatched on /task-review)"
[ -n "$WORKFLOW" ] && echo "  workflow: $WORKFLOW"
echo
echo "Track with: /task-status $ID"
