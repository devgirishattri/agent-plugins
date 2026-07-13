#!/usr/bin/env bash
# task-review.sh — Move an assigned scheduler task to review
# The executor (or orchestrator) calls this when work is ready for audit, with
# a note such as a commit SHA. The reviewer then runs task-done (approve) or
# task-block (reject).
# Usage: task-review.sh <task-id> [--force] <note>
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

if [ "$#" -lt 2 ]; then
  echo "ERROR: Usage: task-review.sh <task-id> [--force] <note>   (note required, e.g. a commit SHA)" >&2
  exit 1
fi

require_jq || exit 1
ensure_dirs || exit 1

ID="$1"
shift
if [ "${1:-}" = "--force" ]; then
  SESSION_SCHEDULER_FORCE=1; export SESSION_SCHEDULER_FORCE
  shift
fi
NOTE="$*"
if [ -z "$NOTE" ]; then
  echo "ERROR: Usage: task-review.sh <task-id> [--force] <note>   (note required, e.g. a commit SHA)" >&2
  exit 1
fi
FILE=$(task_file "$ID") || exit 1
[ -f "$FILE" ] || { echo "ERROR: Task not found: $ID" >&2; exit 1; }

# Canonical review-delivery state lives under .meta so Claude and Codex can
# safely retry one another's hand-offs. Older Codex releases wrote these keys
# at the task root. Migrate those aliases only when the canonical key is
# absent (an explicit canonical null means a newer assignment cleared it),
# then remove every legacy alias in the same atomic rewrite.
jq '
  (.meta | if type == "object" then . else {} end) as $meta
  | .meta = $meta
  | .meta.review_prompt_file =
      (if (.meta | has("review_prompt_file")) then .meta.review_prompt_file
       else (.review_prompt_file // null) end)
  | .meta.review_dispatched_at =
      (if (.meta | has("review_dispatched_at")) then .meta.review_dispatched_at
       else (.review_dispatched_at // null) end)
  | .meta.review_dispatch_attempt_at =
      (if (.meta | has("review_dispatch_attempt_at")) then .meta.review_dispatch_attempt_at
       elif (.meta | has("review_last_dispatch_attempt_at")) then .meta.review_last_dispatch_attempt_at
       else (.review_dispatch_attempt_at // .review_last_dispatch_attempt_at // null) end)
  | .meta.review_dispatch_attempts =
      (if (.meta | has("review_dispatch_attempts")) then .meta.review_dispatch_attempts
       else (.review_dispatch_attempts // null) end)
  | .meta.review_dispatch_error =
      (if (.meta | has("review_dispatch_error")) then .meta.review_dispatch_error
       else (.review_dispatch_error // null) end)
  | .meta.review_dispatch_status =
      (if (.meta | has("review_dispatch_status")) then .meta.review_dispatch_status
       elif (.review_dispatch_status // "") != "" then .review_dispatch_status
       elif (.meta.review_dispatched_at // "") != "" then "delivered"
       else null end)
  | del(.meta.review_last_dispatch_attempt_at,
        .review_prompt_file, .review_dispatched_at,
        .review_dispatch_status, .review_dispatch_attempt_at,
        .review_last_dispatch_attempt_at, .review_dispatch_attempts,
        .review_dispatch_error)
' "$FILE" | write_json_atomic "$FILE" || {
  echo "ERROR: Could not normalize review dispatch metadata for task $ID." >&2
  exit 1
}

ACTOR=$(current_pane_name)
REVIEWER=$(jq -r '.reviewer // empty' "$FILE")
CURRENT_STATUS=$(jq -r '.status // ""' "$FILE")
REVIEW_DISPATCHED_AT=$(jq -r '.meta.review_dispatched_at // empty' "$FILE")
RETRY_REVIEW_DISPATCH=0
REVIEW_REQUEST_NOTE="$NOTE"

# A failed automatic reviewer dispatch happens after the legal assigned->review
# transition. Permit a later task-review call to retry only that missing
# dispatch, without inventing a review->review transition or duplicate history
# event. A task that was already dispatched remains protected by the normal
# lifecycle check.
if [ "$CURRENT_STATUS" = "review" ]; then
  if [ -n "$REVIEW_DISPATCHED_AT" ]; then
    echo "Task $ID is already in review and was dispatched to its reviewer at $REVIEW_DISPATCHED_AT."
    echo "Not re-dispatching because that would duplicate reviewer delivery."
    exit 0
  elif [ -n "$REVIEWER" ] && [ "$REVIEWER" != "$ACTOR" ]; then
    RETRY_REVIEW_DISPATCH=1
    STORED_REVIEW_NOTE=$(jq -r '[.history[]? | select(.event == "review")][-1].note // empty' "$FILE")
    [ -n "$STORED_REVIEW_NOTE" ] && REVIEW_REQUEST_NOTE="$STORED_REVIEW_NOTE"
  else
    echo "ERROR: Task $ID is already in review and has no pending external reviewer dispatch." >&2
    echo "Resolve it with task-done/task-block instead of creating another review event." >&2
    exit 1
  fi
else
  append_history_update "$FILE" "review" "review" "$ACTOR" "$NOTE" || exit 1
fi

ASSIGNER=$(jq -r '.assigner // ""' "$FILE")
REVIEW_DISPATCHED=0
if [ -n "$REVIEWER" ] && [ "$REVIEWER" != "$ACTOR" ]; then
  CHAT_ROOT=$(session_chat_root 2>/dev/null || true)
  if [ -n "$CHAT_ROOT" ]; then
    REVIEW_PROMPT="$PROMPTS_DIR/${ID}-review.md"
    ORIGINAL_PROMPT=$(jq -r '.prompt_file // empty' "$FILE")
    TRUSTED_ORIGINAL_PROMPT=$(trusted_recorded_prompt_file "$ID" "$ORIGINAL_PROMPT" 2>/dev/null || true)
    TASK_NAME=$(jq -r '.name // ""' "$FILE")
    SCHEDULER_HOME_RECORDED=$(jq -r '.meta.scheduler_home // .scheduler_home // empty' "$FILE")
    [ -n "$SCHEDULER_HOME_RECORDED" ] || SCHEDULER_HOME_RECORDED=$(absolute_existing_dir "$SCHEDULER_DIR")
    CONTEXT_HOME_RECORDED=$(jq -r '.meta.context_home // .context_home // empty' "$FILE")
    CONTEXT_NAME=$(jq -r '.meta.context // empty' "$FILE")
    CONTEXT_NAME_ARG=""
    if [ -n "$CONTEXT_NAME" ]; then
      CONTEXT_NAME_ARG=$(printf '%q' "$CONTEXT_NAME")
    fi
    umask 077
    {
      printf 'Review task ID: %s\n' "$ID"
      printf 'Task name: %s\n' "$TASK_NAME"
      printf 'Reviewer: %s\n' "$REVIEWER"
      printf 'Shared scheduler home (provenance): %s\n' "$SCHEDULER_HOME_RECORDED"
      printf 'Shared context home (provenance): %s\n\n' "${CONTEXT_HOME_RECORDED:-(not set)}"
      printf 'Review request: %s\n' "$REVIEW_REQUEST_NOTE"
      if [ "$RETRY_REVIEW_DISPATCH" -eq 1 ] && [ "$NOTE" != "$REVIEW_REQUEST_NOTE" ]; then
        printf 'Dispatch retry note: %s\n' "$NOTE"
      fi
      printf '\nAudit the completed work independently.\n'
      printf '\nEnvironment contract:\n'
      printf -- '- The shared home paths in this packet are provenance and relaunch guidance,\n'
      printf -- '  not commands to run.\n'
      printf -- '- Your process must already have these exact values inherited in its\n'
      printf -- '  environment from startup (the pane/session launcher sets them before the\n'
      printf -- '  agent starts).\n'
      printf -- '- Invoke scheduler skills/helpers as ONE literal Bash segment:\n'
      printf -- '  bash "<installed session-scheduler plugin root>/scripts/<helper>.sh" ...\n'
      printf -- '- Do not run export, do not prefix the helper with env or variable\n'
      printf -- '  assignments, and do not combine it with any other shell segment (no\n'
      printf -- '  chaining, pipelines, redirection, or command/process substitution).\n'
      printf -- '- If the inherited values are absent or differ, stop and request a relaunch of\n'
      printf -- '  this pane with the correct environment instead of deriving another ledger.\n'
      printf '\nApprove with either provider form:\n'
      printf 'Codex:  $session-scheduler:task-done %s <audit note>\n' "$ID"
      printf 'Claude: /session-scheduler:task-done %s <audit note>\n' "$ID"
      printf '\nReject with either provider form:\n'
      printf 'Codex:  $session-scheduler:task-block %s <reason>\n' "$ID"
      printf 'Claude: /session-scheduler:task-block %s <reason>\n' "$ID"
      if [ -n "$CONTEXT_NAME_ARG" ]; then
        printf '\nLoad the shared context with either provider form:\n'
        printf 'Codex:  $session-context:context-load %s\n' "$CONTEXT_NAME_ARG"
        printf 'Claude: /session-context:context-load %s\n' "$CONTEXT_NAME_ARG"
      fi
      if [ -n "$TRUSTED_ORIGINAL_PROMPT" ]; then
        printf '\n## Original assignment\n\n'
        cat "$TRUSTED_ORIGINAL_PROMPT"
      elif [ -n "$ORIGINAL_PROMPT" ]; then
        printf '\n## Original assignment\n\n(unavailable: stored prompt_file failed safety checks)\n'
      fi
    } > "$REVIEW_PROMPT"
    DISPATCH_OUTPUT=$(bash "$CHAT_ROOT/scripts/dispatch-to-session.sh" "$REVIEWER" "$REVIEW_PROMPT" 2>&1)
    DISPATCH_RC=$?
    if [ "$DISPATCH_RC" -eq 0 ] || [ "$DISPATCH_RC" -eq 3 ]; then
      REVIEW_DISPATCHED=1
      NOW=$(now_iso)
      case "$DISPATCH_RC:$DISPATCH_OUTPUT" in
        3:*) REVIEW_DISPATCH_STATUS="queued" ;;
        *"Queued dispatch"*|*"Queued to "*) REVIEW_DISPATCH_STATUS="queued" ;;
        *) REVIEW_DISPATCH_STATUS="delivered" ;;
      esac
      [ -n "$DISPATCH_OUTPUT" ] && printf '%s\n' "$DISPATCH_OUTPUT"
      jq --arg prompt "$REVIEW_PROMPT" --arg now "$NOW" --arg status "$REVIEW_DISPATCH_STATUS" \
        '(.meta //= {})
         | .meta.review_prompt_file=$prompt
         | .meta.review_dispatched_at=$now
         | .meta.review_dispatch_status=$status
         | .meta.review_dispatch_attempt_at=$now
         | .meta.review_dispatch_attempts=(if (.meta.review_dispatch_attempts | type) == "number" then .meta.review_dispatch_attempts + 1 else 1 end)
         | .meta.review_dispatch_error=null
         | del(.meta.review_last_dispatch_attempt_at,
               .review_prompt_file, .review_dispatched_at,
               .review_dispatch_status, .review_dispatch_attempt_at,
               .review_last_dispatch_attempt_at, .review_dispatch_attempts,
               .review_dispatch_error)' "$FILE" | write_json_atomic "$FILE" || {
        echo "ERROR: Review was dispatched, but its delivery metadata could not be recorded for task $ID." >&2
        exit 1
      }
    else
      NOW=$(now_iso)
      DISPATCH_ERROR="session-chat dispatch failed (rc=$DISPATCH_RC)"
      [ -n "$DISPATCH_OUTPUT" ] && printf '%s\n' "$DISPATCH_OUTPUT" >&2
      jq --arg prompt "$REVIEW_PROMPT" --arg now "$NOW" --arg error "$DISPATCH_ERROR" \
        '(.meta //= {})
         | .meta.review_prompt_file=$prompt
         | del(.meta.review_dispatched_at)
         | .meta.review_dispatch_status="failed"
         | .meta.review_dispatch_attempt_at=$now
         | .meta.review_dispatch_attempts=(if (.meta.review_dispatch_attempts | type) == "number" then .meta.review_dispatch_attempts + 1 else 1 end)
         | .meta.review_dispatch_error=$error
         | del(.meta.review_last_dispatch_attempt_at,
               .review_prompt_file, .review_dispatched_at,
               .review_dispatch_status, .review_dispatch_attempt_at,
               .review_last_dispatch_attempt_at, .review_dispatch_attempts,
               .review_dispatch_error)' "$FILE" | write_json_atomic "$FILE" || {
        echo "ERROR: Could not record the failed review dispatch for task $ID." >&2
        exit 1
      }
      echo "WARN: Task moved to review, but automatic dispatch to '$REVIEWER' failed." >&2
    fi
  else
    NOW=$(now_iso)
    jq --arg now "$NOW" \
      '(.meta //= {})
       | del(.meta.review_dispatched_at)
       | .meta.review_dispatch_status="failed"
       | .meta.review_dispatch_attempt_at=$now
       | .meta.review_dispatch_attempts=(if (.meta.review_dispatch_attempts | type) == "number" then .meta.review_dispatch_attempts + 1 else 1 end)
       | .meta.review_dispatch_error="session-chat unavailable"
       | del(.meta.review_last_dispatch_attempt_at,
             .review_prompt_file, .review_dispatched_at,
             .review_dispatch_status, .review_dispatch_attempt_at,
             .review_last_dispatch_attempt_at, .review_dispatch_attempts,
             .review_dispatch_error)' "$FILE" | write_json_atomic "$FILE" || {
      echo "ERROR: Could not record the unavailable reviewer transport for task $ID." >&2
      exit 1
    }
    echo "WARN: Task moved to review, but session-chat is unavailable for reviewer dispatch." >&2
  fi
fi
if [ "$RETRY_REVIEW_DISPATCH" -eq 0 ] && [ -n "$ASSIGNER" ] && [ "$ASSIGNER" != "$ACTOR" ]; then
  CHAT_ROOT=$(session_chat_root 2>/dev/null || true)
  if [ -n "$CHAT_ROOT" ]; then
    bash "$CHAT_ROOT/scripts/send-message.sh" "$ASSIGNER" "Task $ID ready for REVIEW: $NOTE" >&2 || true
  fi
fi

if [ "$RETRY_REVIEW_DISPATCH" -eq 1 ] && [ "$REVIEW_DISPATCHED" -eq 1 ]; then
  echo "Retried review dispatch for task $ID to $REVIEWER."
elif [ "$RETRY_REVIEW_DISPATCH" -eq 1 ]; then
  echo "Review dispatch retry for task $ID failed; task remains in review."
else
  echo "Marked task $ID review."
fi
if [ "$REVIEW_DISPATCHED" -eq 1 ] && [ "$RETRY_REVIEW_DISPATCH" -eq 0 ]; then
  echo "Dispatched independent review to $REVIEWER."
elif [ "$RETRY_REVIEW_DISPATCH" -eq 0 ]; then
  echo "Reviewer: approve with \$session-scheduler:task-done $ID <note>, or reject with \$session-scheduler:task-block $ID <reason>."
fi
