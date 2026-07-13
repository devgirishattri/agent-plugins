#!/usr/bin/env bash
# task-review.sh — move an assigned task to review; ack assigner via session-chat.
# The executor (or orchestrator) calls this when work is ready for audit, with a
# note such as a commit SHA. The reviewer then runs task-done (approve) or
# task-block (reject).
# Usage: task-review.sh <id> [--force] <note>
set -uo pipefail

source "$(dirname "$0")/lib.sh"

require_jq || exit 1
ensure_dirs || exit 1

ID="${1:-}"
shift 2>/dev/null || true
if [ "${1:-}" = "--force" ]; then
  SESSION_SCHEDULER_FORCE=1; export SESSION_SCHEDULER_FORCE
  shift
fi
NOTE="${*:-}"

if [ -z "$ID" ] || [ -z "$NOTE" ]; then
  echo "ERROR: Usage: task-review.sh <id> [--force] <note>   (note required, e.g. a commit SHA)" >&2
  exit 1
fi

validate_task_id "$ID" || exit 1
task_exists "$ID" || { echo "ERROR: task '$ID' not found." >&2; exit 1; }

ACTOR=$(current_pane_name)
ASSIGNER=$(task_get "$ID" '.assigner')
NAME=$(task_get "$ID" '.name')
REVIEWER=$(task_get "$ID" '.reviewer // ""')
CURRENT=$(task_get "$ID" '.status')
# Canonical .meta.review_dispatched_at is AUTHORITATIVE: when meta HAS the key we
# use its value even if null (null = not yet successfully dispatched → retry is
# allowed). Only when meta lacks the key entirely do we consult a legacy root
# alias. Using `//` here would let a STALE root timestamp revive a canonical null
# and falsely suppress a legitimate retry after a hard dispatch failure.
REVIEW_DISPATCHED=$(task_get "$ID" '
  if (.meta | type) == "object" and (.meta | has("review_dispatched_at"))
  then .meta.review_dispatched_at
  else .review_dispatched_at
  end')

# RETRY_REVIEW_DISPATCH: dispatch-only retry for an already-review task. If the
# task is ALREADY in review, only RE-DISPATCH when the prior attempt did NOT
# already succeed (meta.review_dispatched_at absent) — re-running after a
# successful dispatch would DUPLICATE reviewer delivery. When it did succeed,
# refuse and point the user at task-done/task-block. Retry never mutates status
# or history and preserves the original review note.
RETRY=0
if [ "$CURRENT" = "review" ]; then
  if [ -n "$REVIEW_DISPATCHED" ] && [ "$REVIEW_DISPATCHED" != "null" ]; then
    # Already successfully dispatched — suppress the duplicate. Fully normalize a
    # legacy schema first: for EACH canonical review field, import the legacy root
    # alias ONLY when the canonical key is absent (an explicit canonical null stays
    # authoritative); derive review_dispatch_status="delivered" when a success
    # timestamp exists but no status; then drop every root review_* alias.
    _mig=$(cat "$(task_path "$ID")" | jq '
      .meta = (.meta | if type == "object" then . else {} end)
      | reduce ("review_dispatched_at","review_dispatch_status","review_dispatch_error","review_dispatch_attempt_at","review_last_dispatch_attempt_at","review_dispatch_attempts","review_prompt_file") as $k
        (.; if ((.meta | has($k)) | not) and has($k) then .meta[$k] = .[$k] else . end)
      | (if (.meta.review_dispatched_at != null) and ((.meta.review_dispatch_status // null) == null)
         then .meta.review_dispatch_status = "delivered" else . end)
      | with_entries(select((.key | startswith("review_")) | not))')
    task_write "$ID" "$_mig" || true
    echo "Task $ID is already in review and was dispatched to its reviewer at ${REVIEW_DISPATCHED}."
    echo "  Not re-dispatching (would duplicate delivery). Resolve with /task-done $ID or /task-block $ID <reason>."
    exit 0
  fi
  RETRY=1  # RETRY_REVIEW_DISPATCH
else
  if ! task_set_status "$ID" "review" "$ACTOR" "$NOTE"; then
    echo "ERROR: task $ID NOT moved to review." >&2
    exit 1
  fi
  if [ -n "$ASSIGNER" ] && [ "$ASSIGNER" != "?" ] && [ "$ASSIGNER" != "$ACTOR" ]; then
    session_chat_send "$ASSIGNER" "task ${ID} (${NAME}) ready for REVIEW by ${ACTOR}: ${NOTE}"
  fi
fi

# Reviewer routing: if a reviewer pane was recorded at assignment, auto-dispatch
# the audit request to them over the hardened transport (durable — recovered on
# their next turn if busy). The dispatch carries the ORIGINAL assignment so the
# reviewer has the full context, not just the review note. On a HARD dispatch
# failure we do NOT downgrade to a lossy one-line /send: the task stays in
# review and we warn, so a message is never silently half-delivered. Skipped
# when the reviewer is the actor themselves (self-review is a no-op hand-off).
ROUTED=""
ROUTE_WARN=""
if [ -n "$REVIEWER" ] && [ "$REVIEWER" != "null" ] && [ "$REVIEWER" != "$ACTOR" ]; then
  SCHED_HOME_ABS=$(abs_dir "$SCHEDULER_DIR")  # provenance only — never printed as an export
  REVIEW_PROMPT=$(prompt_path "${ID}-review")
  ORIG_PROMPT_FILE=$(prompt_path "$ID")
  ORIG_ASSIGNMENT="(original assignment prompt not found)"
  # Only inline the original prompt if it is a real, regular file that canonically
  # lives inside PROMPTS_DIR (ID is already charset-validated; this is defense in
  # depth so a review packet never carries content from outside the ledger).
  if [ -f "$ORIG_PROMPT_FILE" ] && [ ! -L "$ORIG_PROMPT_FILE" ]; then
    op_dir=$(cd "$(dirname "$ORIG_PROMPT_FILE")" 2>/dev/null && pwd -P)
    canon_prompts=$(cd "$PROMPTS_DIR" 2>/dev/null && pwd -P)
    if [ -n "$op_dir" ] && [ "$op_dir" = "$canon_prompts" ]; then
      ORIG_ASSIGNMENT=$(cat "$ORIG_PROMPT_FILE")
    fi
  fi
  cat > "$REVIEW_PROMPT" <<EOF
Review requested — task ${ID}: ${NAME}
Submitted by: ${ACTOR}
Note (e.g. commit SHA): ${NOTE}

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

Audit the work, then record the outcome (use the form for your runtime):
  approve — Claude: /session-scheduler:task-done ${ID} <note>
            Codex:  \$session-scheduler:task-done ${ID} <note>
  reject  — Claude: /session-scheduler:task-block ${ID} <reason>
            Codex:  \$session-scheduler:task-block ${ID} <reason>

--- Original assignment ---
${ORIG_ASSIGNMENT}
EOF
  chmod 600 "$REVIEW_PROMPT" 2>/dev/null || true
  session_chat_dispatch "$REVIEWER" "$REVIEW_PROMPT" >/dev/null 2>&1
  dc=$?
  # Record dispatch metadata so a later /task-review can tell a successful
  # delivery (do NOT re-dispatch — would duplicate) from a failed one (retry OK).
  _rv_now=$(iso_now)
  _rv_json=$(cat "$(task_path "$ID")")
  case "$dc" in
    0|3)
      [ "$dc" = "3" ] && ROUTED="$REVIEWER (queued to durable inbox)" || ROUTED="$REVIEWER"
      _rv_status=$([ "$dc" = "3" ] && echo queued || echo delivered)
      _rv_out=$(printf '%s' "$_rv_json" | jq --arg t "$_rv_now" --arg s "$_rv_status" --arg pf "$REVIEW_PROMPT" \
        'with_entries(select((.key | startswith("review_")) | not))
         | .meta.review_dispatched_at = $t
         | .meta.review_dispatch_status = $s
         | .meta.review_dispatch_error = null
         | .meta.review_prompt_file = $pf
         | .meta.review_last_dispatch_attempt_at = $t
         | .meta.review_dispatch_attempts = ((.meta.review_dispatch_attempts // 0) + 1)')
      task_write "$ID" "$_rv_out" || true
      ;;
    *)
      ROUTE_WARN="reviewer dispatch to '$REVIEWER' failed (rc=$dc); task remains in review. Fix the issue (see /session-chat:panes) and re-run /task-review, or notify the reviewer manually."
      # No success timestamp -> a later /task-review is allowed to retry. Also
      # clear stale legacy root review_* aliases AND force canonical
      # .meta.review_dispatched_at to null so a leftover root/meta success stamp
      # can never falsely suppress the retry.
      _rv_out=$(printf '%s' "$_rv_json" | jq --arg t "$_rv_now" --arg e "dispatch failed rc=$dc" --arg pf "$REVIEW_PROMPT" \
        'with_entries(select((.key | startswith("review_")) | not))
         | .meta.review_dispatched_at = null
         | .meta.review_dispatch_status = null
         | .meta.review_dispatch_attempt_at = $t
         | .meta.review_last_dispatch_attempt_at = $t
         | .meta.review_dispatch_error = $e
         | .meta.review_prompt_file = $pf
         | .meta.review_dispatch_attempts = ((.meta.review_dispatch_attempts // 0) + 1)')
      task_write "$ID" "$_rv_out" || true
      ;;
  esac
fi

if [ "$RETRY" = "1" ]; then
  echo "Task $ID already in review — retried reviewer dispatch (no status change)."
else
  echo "Task $ID moved to review."
fi
echo "  note: $NOTE"
[ -n "$ROUTED" ] && echo "  routed to reviewer: $ROUTED"
echo
echo "Reviewer: approve with /task-done $ID [note], or reject with /task-block $ID <reason>."
[ -n "$ROUTE_WARN" ] && echo "WARN: $ROUTE_WARN" >&2
exit 0
