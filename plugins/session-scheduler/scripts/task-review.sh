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
# A contracted task is handed to task-contract.sh with the original arguments
# before any write; it never returns in that case.
contract_route_if_needed review "$ID" "$@"
shift 2>/dev/null || true
if [ "${1:-}" = "--force" ]; then
  SESSION_SCHEDULER_FORCE=1; export SESSION_SCHEDULER_FORCE
  shift
fi
NOTE="${*:-}"
NOTE_SUFFIX=""

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
    task_update "$ID" '
      .meta = (.meta | if type == "object" then . else {} end)
      | reduce ("review_dispatched_at","review_dispatch_status","review_dispatch_error","review_dispatch_attempt_at","review_last_dispatch_attempt_at","review_dispatch_attempts","review_prompt_file") as $k
        (.; if ((.meta | has($k)) | not) and has($k) then .meta[$k] = .[$k] else . end)
      | (if (.meta.review_dispatched_at != null) and ((.meta.review_dispatch_status // null) == null)
         then .meta.review_dispatch_status = "delivered" else . end)
      | with_entries(select((.key | startswith("review_")) | not))' || true
    echo "Task $ID is already in review and was dispatched to its reviewer at ${REVIEW_DISPATCHED}."
    echo "  Not re-dispatching (would duplicate delivery). Resolve with /task-done $ID or /task-block $ID <reason>."
    exit 0
  fi
  RETRY=1  # RETRY_REVIEW_DISPATCH
  # A retry re-sends the ORIGINAL review request: the audit packet must carry
  # the note (e.g. commit SHA) recorded when the task entered review, not
  # whatever the retry invocation typed. The CLI note stays required
  # syntactically and is ignored here.
  ORIGINAL_NOTE=$(task_get "$ID" '[.history[]? | select(.event == "review")][-1].note // empty')
  if [ -n "$ORIGINAL_NOTE" ]; then
    NOTE="$ORIGINAL_NOTE"
    NOTE_SUFFIX=" (original review note reused on retry)"
  fi
else
  if ! task_set_status "$ID" "review" "$ACTOR" "$NOTE"; then
    echo "ERROR: task $ID NOT moved to review." >&2
    exit 1
  fi
  if [ -n "$ASSIGNER" ] && [ "$ASSIGNER" != "?" ] && [ "$ASSIGNER" != "$ACTOR" ]; then
    # Durable file-backed dispatch first (queued to the assigner's inbox when
    # busy — the same transport task-assign uses), inline /send as a
    # last-resort fallback. This ack is independent of reviewer routing below:
    # a failure here never blocks or retries the review transition, and never
    # collides with the review_dispatch_* bookkeeping reviewer routing owns.
    session_chat_ack "$ASSIGNER" "$ID" "review" "task ${ID} (${NAME}) ready for REVIEW by ${ACTOR}: ${NOTE}"
    task_record_last_ack "$ID" "review" "$ASSIGNER" "$SESSION_CHAT_ACK_STATUS" "$SESSION_CHAT_ACK_FILE"
    if [ "$SESSION_CHAT_ACK_STATUS" = "failed" ]; then
      echo "WARN: durable ack to assigner '$ASSIGNER' failed — the assigner notification that task $ID is ready for review was not delivered." >&2
      echo "  Reviewer routing proceeds independently; task $ID stays in review. Do not rerun the transition to repair the notification." >&2
    fi
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

$(packet_contract_block "$SCHED_HOME_ABS")

Audit the work, then record the outcome (use the form for your runtime):
  approve — Claude: /session-scheduler:task-done ${ID} <note>
            Codex:  \$session-scheduler:task-done ${ID} <note>
  reject  — Claude: /session-scheduler:task-block ${ID} <reason>
            Codex:  \$session-scheduler:task-block ${ID} <reason>

--- Original assignment ---
${ORIG_ASSIGNMENT}
EOF
  chmod 600 "$REVIEW_PROMPT" 2>/dev/null || true
  # stdout is captured (stderr stays discarded) only to read the request id:
  # exactly one line "Message id: <hex>" printed by the dispatch itself. Notes
  # and stderr are never parsed. An older session-chat prints none, so the
  # request id is recorded as null (unknown), never guessed.
  _rv_out=$(session_chat_dispatch "$REVIEWER" "$REVIEW_PROMPT" 2>/dev/null)
  dc=$?
  _rv_msg_id=""
  if [ "$(printf '%s\n' "$_rv_out" | grep -cE '^Message id: [a-f0-9]{8,16}$')" = "1" ]; then
    _rv_msg_id=$(printf '%s\n' "$_rv_out" | grep -E '^Message id: [a-f0-9]{8,16}$' | sed 's/^Message id: //')
  fi
  # Record dispatch metadata so a later /task-review can tell a successful
  # delivery (do NOT re-dispatch — would duplicate) from a failed one (retry OK).
  _rv_now=$(iso_now)
  case "$dc" in
    0|3)
      [ "$dc" = "3" ] && ROUTED="$REVIEWER (queued to durable inbox)" || ROUTED="$REVIEWER"
      _rv_status=$([ "$dc" = "3" ] && echo queued || echo delivered)
      # Delivered packet: the success stamp MUST persist, or a later
      # /task-review would re-dispatch and duplicate delivery. Report loudly.
      task_update "$ID" \
        'with_entries(select((.key | startswith("review_")) | not))
         | .meta.review_dispatched_at = $t
         | .meta.review_dispatch_status = $s
         | .meta.review_dispatch_error = null
         | .meta.review_prompt_file = $pf
         | .meta.review_request_msg_id = (if $rid == "" then null else $rid end)
         | .meta.review_last_dispatch_attempt_at = $t
         | .meta.review_dispatch_attempts = ((.meta.review_dispatch_attempts // 0) + 1)' \
        --arg t "$_rv_now" --arg s "$_rv_status" --arg pf "$REVIEW_PROMPT" --arg rid "$_rv_msg_id" \
        || ROUTE_WARN="reviewer packet was delivered to '$REVIEWER' but recording review_dispatched_at FAILED; do NOT re-run /task-review (it would duplicate delivery). Inspect $(task_path "$ID")."
      ;;
    *)
      ROUTE_WARN="reviewer dispatch to '$REVIEWER' failed (rc=$dc); task remains in review. Fix the issue (see /session-chat:panes) and re-run /task-review, or notify the reviewer manually."
      # No success timestamp -> a later /task-review is allowed to retry. Also
      # clear stale legacy root review_* aliases AND force canonical
      # .meta.review_dispatched_at to null so a leftover root/meta success stamp
      # can never falsely suppress the retry.
      task_update "$ID" \
        'with_entries(select((.key | startswith("review_")) | not))
         | .meta.review_dispatched_at = null
         | .meta.review_dispatch_status = null
         | .meta.review_dispatch_attempt_at = $t
         | .meta.review_last_dispatch_attempt_at = $t
         | .meta.review_dispatch_error = $e
         | .meta.review_prompt_file = $pf
         | .meta.review_request_msg_id = null
         | .meta.review_dispatch_attempts = ((.meta.review_dispatch_attempts // 0) + 1)' \
        --arg t "$_rv_now" --arg e "dispatch failed rc=$dc" --arg pf "$REVIEW_PROMPT" || true
      ;;
  esac
fi

if [ "$RETRY" = "1" ]; then
  echo "Task $ID already in review — retried reviewer dispatch (no status change)."
else
  echo "Task $ID moved to review."
fi
echo "  note: ${NOTE}${NOTE_SUFFIX}"
[ -n "$ROUTED" ] && echo "  routed to reviewer: $ROUTED"
echo
echo "Reviewer: approve with /task-done $ID [note], or reject with /task-block $ID <reason>."
[ -n "$ROUTE_WARN" ] && echo "WARN: $ROUTE_WARN" >&2
exit 0
