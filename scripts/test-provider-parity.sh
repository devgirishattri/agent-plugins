#!/usr/bin/env bash
# Cross-provider smoke test: Claude and Codex scheduler/context scripts must
# operate on the same shared schemas and safety contracts without translation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/provider-parity-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Review routing metadata describes one assignment cycle only. Both providers
# must clear every canonical field and every pre-.meta compatibility alias on
# reassignment; leaving even one value can suppress or corrupt the next review.
assert_review_cycle_cleared() {
  local file="$1" label="$2"
  if jq -e '
    [
      .meta.review_prompt_file,
      .meta.review_dispatched_at,
      .meta.review_dispatch_status,
      .meta.review_dispatch_attempt_at,
      .meta.review_last_dispatch_attempt_at,
      .meta.review_dispatch_attempts,
      .meta.review_dispatch_error,
      .review_prompt_file,
      .review_dispatched_at,
      .review_dispatch_status,
      .review_dispatch_attempt_at,
      .review_last_dispatch_attempt_at,
      .review_dispatch_attempts,
      .review_dispatch_error
    ] | all(. == null)
  ' "$file" >/dev/null; then
    return 0
  fi

  echo "Review-cycle residue after $label:" >&2
  jq '{
    canonical_meta: {
      review_prompt_file: .meta.review_prompt_file,
      review_dispatched_at: .meta.review_dispatched_at,
      review_dispatch_status: .meta.review_dispatch_status,
      review_dispatch_attempt_at: .meta.review_dispatch_attempt_at,
      review_last_dispatch_attempt_at: .meta.review_last_dispatch_attempt_at,
      review_dispatch_attempts: .meta.review_dispatch_attempts,
      review_dispatch_error: .meta.review_dispatch_error
    },
    legacy_root: {
      review_prompt_file,
      review_dispatched_at,
      review_dispatch_status,
      review_dispatch_attempt_at,
      review_last_dispatch_attempt_at,
      review_dispatch_attempts,
      review_dispatch_error
    }
  }' "$file" >&2
  fail "$label retained canonical or legacy review-cycle metadata"
}

assert_provider_neutral_packet() {
  local packet="$1" label="$2"
  local scheduler_home_q context_home_q
  [ -f "$packet" ] || fail "$label packet missing: $packet"
  scheduler_home_q=$(printf '%q' "$(cd "$SESSION_SCHEDULER_HOME" && pwd -P)")
  context_home_q=$(printf '%q' "$(cd "$SESSION_CONTEXT_HOME" && pwd -P)")
  grep -F "export SESSION_SCHEDULER_HOME=$scheduler_home_q" "$packet" >/dev/null \
    || fail "$label packet missing exact shell-safe scheduler export"
  grep -F "export SESSION_CONTEXT_HOME=$context_home_q" "$packet" >/dev/null \
    || fail "$label packet missing exact shell-safe context export"
  grep -F '$session-scheduler:task-done' "$packet" >/dev/null \
    || fail "$label packet missing Codex completion command"
  grep -F '/session-scheduler:task-done' "$packet" >/dev/null \
    || fail "$label packet missing Claude completion command"
  grep -F '$session-scheduler:task-block' "$packet" >/dev/null \
    || fail "$label packet missing Codex block command"
  grep -F '/session-scheduler:task-block' "$packet" >/dev/null \
    || fail "$label packet missing Claude block command"
  grep -F '$session-context:context-load' "$packet" >/dev/null \
    || fail "$label packet missing Codex context-load command"
  grep -F '/session-context:context-load' "$packet" >/dev/null \
    || fail "$label packet missing Claude context-load command"
}

# Spaces and an apostrophe force both providers to keep using printf %q for
# copy-paste-safe shared-home exports.
export SESSION_SCHEDULER_HOME="$TMP/shared scheduler's ledger"
export SESSION_CONTEXT_HOME="$TMP/shared context's store"
export SESSION_CHAT_ROOT_OVERRIDE="$TMP/session-chat"
mkdir -p "$SESSION_CHAT_ROOT_OVERRIDE/.codex-plugin" "$SESSION_CHAT_ROOT_OVERRIDE/scripts" "$SESSION_CONTEXT_HOME"
printf '{"name":"session-chat","version":"0.17.0"}\n' > "$SESSION_CHAT_ROOT_OVERRIDE/.codex-plugin/plugin.json"

printf '%s\n' '#!/usr/bin/env bash' 'if [ "${PARITY_DISPATCH_FAIL:-0}" = "1" ]; then exit 1; fi' \
  'printf "%s\t%s\n" "$1" "$2" >> "${PARITY_DISPATCH_LOG:?}"' \
  'if [ "${PARITY_DISPATCH_QUEUE:-0}" = "1" ]; then printf "Queued dispatch to %s\n" "$1"; fi' \
  > "$SESSION_CHAT_ROOT_OVERRIDE/scripts/dispatch-to-session.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
  > "$SESSION_CHAT_ROOT_OVERRIDE/scripts/send-message.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "parity-orchestrator\n"' \
  > "$SESSION_CHAT_ROOT_OVERRIDE/scripts/get-my-name.sh"
chmod +x "$SESSION_CHAT_ROOT_OVERRIDE/scripts/"*.sh
export PARITY_DISPATCH_LOG="$TMP/dispatch.log"
: > "$PARITY_DISPATCH_LOG"

CLAUDE_SCRIPTS="$ROOT/plugins/session-scheduler/scripts"
CODEX_SCRIPTS="$ROOT/codex/plugins/session-scheduler/scripts"

claude_created=$(bash "$CLAUDE_SCRIPTS/task-new.sh" "Claude-created shared task" --workflow shared-claude)
CLAUDE_ID=$(printf '%s\n' "$claude_created" | grep -oE '[a-f0-9]{8}' | head -1)
[ -n "$CLAUDE_ID" ] || fail "could not parse Claude-created task id"
bash "$CODEX_SCRIPTS/task-assign.sh" parity-worker "$CLAUDE_ID" --reviewer parity-reviewer --context auto "Codex assigns Claude task" >/dev/null
CLAUDE_FILE="$SESSION_SCHEDULER_HOME/tasks/$CLAUDE_ID.json"
jq -e '.meta.workflow_id == "shared-claude" and .meta.scheduler_home != null and .reviewer == "parity-reviewer"' "$CLAUDE_FILE" >/dev/null \
  || fail "Codex did not preserve canonical schema on Claude-created task"
assert_provider_neutral_packet "$SESSION_SCHEDULER_HOME/prompts/$CLAUDE_ID.md" "Codex assignment"
bash "$CLAUDE_SCRIPTS/task-status.sh" --workflow shared-claude | grep -F "$CLAUDE_ID" >/dev/null \
  || fail "Claude could not filter task after Codex assignment"
bash "$CLAUDE_SCRIPTS/task-review.sh" "$CLAUDE_ID" "cross-provider review" >/dev/null
assert_provider_neutral_packet "$SESSION_SCHEDULER_HOME/prompts/${CLAUDE_ID}-review.md" "Claude review"
CLAUDE_REVIEW_DISPATCHED_AT=$(jq -r '.meta.review_dispatched_at // empty' "$CLAUDE_FILE")
[ -n "$CLAUDE_REVIEW_DISPATCHED_AT" ] || fail "Claude review did not write canonical success metadata"
CLAUDE_REVIEW_HISTORY=$(jq '[.history[] | select(.event == "review")] | length' "$CLAUDE_FILE")
DISPATCHES_BEFORE_CODEX_REENTRY=$(wc -l < "$PARITY_DISPATCH_LOG" | tr -d ' ')
bash "$CODEX_SCRIPTS/task-review.sh" "$CLAUDE_ID" "must not duplicate Claude review" \
  > "$TMP/codex-no-duplicate.out"
DISPATCHES_AFTER_CODEX_REENTRY=$(wc -l < "$PARITY_DISPATCH_LOG" | tr -d ' ')
[ "$DISPATCHES_BEFORE_CODEX_REENTRY" = "$DISPATCHES_AFTER_CODEX_REENTRY" ] \
  || fail "Codex duplicated a Claude-recorded reviewer dispatch"
grep -F 'Not re-dispatching' "$TMP/codex-no-duplicate.out" >/dev/null \
  || fail "Codex did not explain duplicate reviewer suppression"
jq -e --arg at "$CLAUDE_REVIEW_DISPATCHED_AT" --argjson history "$CLAUDE_REVIEW_HISTORY" '
  .meta.review_dispatched_at == $at
  and ([.history[] | select(.event == "review")] | length) == $history
  and ([keys[] | select(startswith("review_"))] | length) == 0
' "$CLAUDE_FILE" >/dev/null || fail "Codex changed Claude canonical review metadata/history"
bash "$CODEX_SCRIPTS/task-done.sh" "$CLAUDE_ID" "approved by Codex" >/dev/null
[ "$(jq -r '.status' "$CLAUDE_FILE")" = "done" ] || fail "Codex could not complete Claude-created task"

codex_created=$(bash "$CODEX_SCRIPTS/task-new.sh" "Codex-created shared task" --workflow shared-codex --reviewer parity-reviewer)
CODEX_ID=$(printf '%s\n' "$codex_created" | grep -oE 'task-[a-zA-Z0-9_.-]+' | head -1)
[ -n "$CODEX_ID" ] || fail "could not parse Codex-created task id"
bash "$CLAUDE_SCRIPTS/task-assign.sh" parity-worker "$CODEX_ID" --context auto "Claude assigns Codex task" >/dev/null
CODEX_FILE="$SESSION_SCHEDULER_HOME/tasks/$CODEX_ID.json"
jq -e '.meta.workflow_id == "shared-codex" and .meta.scheduler_home != null and .reviewer == "parity-reviewer"' "$CODEX_FILE" >/dev/null \
  || fail "Claude did not preserve canonical schema on Codex-created task"
assert_provider_neutral_packet "$SESSION_SCHEDULER_HOME/prompts/$CODEX_ID.md" "Claude assignment"
bash "$CODEX_SCRIPTS/task-status.sh" --workflow shared-codex | grep -F "$CODEX_ID" >/dev/null \
  || fail "Codex could not filter task after Claude assignment"
PARITY_DISPATCH_FAIL=1 bash "$CODEX_SCRIPTS/task-review.sh" "$CODEX_ID" "original Codex review note" \
  > "$TMP/codex-failed-review.out" 2> "$TMP/codex-failed-review.err"
assert_provider_neutral_packet "$SESSION_SCHEDULER_HOME/prompts/${CODEX_ID}-review.md" "Codex failed review"
jq -e '
  .status == "review"
  and (.meta.review_dispatched_at // "") == ""
  and .meta.review_dispatch_status == "failed"
  and (.meta.review_dispatch_attempt_at // "") != ""
  and .meta.review_dispatch_attempts == 1
  and (.meta.review_dispatch_error | startswith("session-chat dispatch failed"))
  and ([.history[] | select(.event == "review")] | length) == 1
  and ([keys[] | select(startswith("review_"))] | length) == 0
' "$CODEX_FILE" >/dev/null || fail "Codex failure did not produce Claude-compatible retry metadata"
bash "$CLAUDE_SCRIPTS/task-review.sh" "$CODEX_ID" "Claude retries Codex transport" >/dev/null
jq -e '
  .status == "review"
  and (.meta.review_dispatched_at // "") != ""
  and (.meta.review_dispatch_status == "delivered" or .meta.review_dispatch_status == "queued")
  and .meta.review_dispatch_error == null
  and ([.history[] | select(.event == "review")] | length) == 1
' "$CODEX_FILE" >/dev/null || fail "Claude could not retry Codex failure metadata without duplicate history"
assert_provider_neutral_packet "$SESSION_SCHEDULER_HOME/prompts/${CODEX_ID}-review.md" "Claude retry review"

# A new assignment cycle must clear both providers' canonical transport state
# and every legacy root alias so an old success cannot suppress the next review.
bash "$CLAUDE_SCRIPTS/task-block.sh" "$CODEX_ID" "changes requested after retry" >/dev/null
bash "$CODEX_SCRIPTS/task-assign.sh" parity-worker "$CODEX_ID" --context auto \
  "Codex reassigns after Claude review retry" >/dev/null
jq -e '
  .status == "assigned"
' "$CODEX_FILE" >/dev/null || fail "Codex did not reassign the Claude-reviewed task"
assert_review_cycle_cleared "$CODEX_FILE" "Codex reassignment after Claude review"
PARITY_DISPATCH_QUEUE=1 bash "$CODEX_SCRIPTS/task-review.sh" "$CODEX_ID" \
  "second-cycle queued Codex review" >/dev/null
jq -e '
  .status == "review"
  and .meta.review_dispatch_status == "queued"
  and (.meta.review_dispatched_at // "") != ""
  and .meta.review_dispatch_attempts == 1
  and .meta.review_dispatch_error == null
  and ([.history[] | select(.event == "review")] | length) == 2
' "$CODEX_FILE" >/dev/null || fail "Codex did not classify a successful queued reviewer dispatch"

# Reverse direction: seed all compatibility aliases alongside Codex's
# canonical review metadata, block the cycle, then have Claude reassign it.
# Claude must reset every field just as Codex does above.
jq '
  .review_prompt_file=.meta.review_prompt_file
  | .review_dispatched_at=.meta.review_dispatched_at
  | .review_dispatch_status=.meta.review_dispatch_status
  | .review_dispatch_attempt_at=.meta.review_dispatch_attempt_at
  | .review_last_dispatch_attempt_at=.meta.review_dispatch_attempt_at
  | .review_dispatch_attempts=.meta.review_dispatch_attempts
  | .review_dispatch_error="legacy error must be cleared"
' "$CODEX_FILE" > "$TMP/codex-review-with-legacy.tmp"
mv "$TMP/codex-review-with-legacy.tmp" "$CODEX_FILE"
bash "$CODEX_SCRIPTS/task-block.sh" "$CODEX_ID" "rework before Claude reassignment" >/dev/null
bash "$CLAUDE_SCRIPTS/task-assign.sh" parity-worker "$CODEX_ID" --context auto \
  "Claude reassigns after Codex review metadata" >/dev/null
jq -e '.status == "assigned"' "$CODEX_FILE" >/dev/null \
  || fail "Claude did not reassign the Codex-reviewed task"
assert_review_cycle_cleared "$CODEX_FILE" "Claude reassignment after Codex review"

# Upgrade-state regression: an explicit canonical null is newer and therefore
# authoritative over stale pre-.meta aliases. Each consumer must retry the
# reviewer hand-off instead of reviving the legacy success timestamp and
# suppressing dispatch. Seed the same valid shared task independently before
# each provider retry so both paths see the exact mixed-version state.
for provider in claude codex; do
  if [ "$provider" = "claude" ]; then
    review_scripts="$CLAUDE_SCRIPTS"
  else
    review_scripts="$CODEX_SCRIPTS"
  fi

  stale_review_at="2025-01-02T03:04:05Z"
  jq --arg stale "$stale_review_at" '
    .status = "review"
    | .meta.review_dispatched_at = null
    | .meta.review_dispatch_status = "failed"
    | .meta.review_dispatch_attempt_at = "2026-07-10T00:00:00Z"
    | .meta.review_last_dispatch_attempt_at = "2026-07-10T00:00:00Z"
    | .meta.review_dispatch_attempts = 1
    | .meta.review_dispatch_error = "canonical retry remains pending"
    | .review_prompt_file = "stale-legacy-review-prompt.md"
    | .review_dispatched_at = $stale
    | .review_dispatch_status = "delivered"
    | .review_dispatch_attempt_at = $stale
    | .review_last_dispatch_attempt_at = $stale
    | .review_dispatch_attempts = 99
    | .review_dispatch_error = "stale legacy state must not suppress retry"
  ' "$CODEX_FILE" > "$TMP/${provider}-canonical-null-upgrade.tmp"
  mv "$TMP/${provider}-canonical-null-upgrade.tmp" "$CODEX_FILE"

  upgrade_history_before=$(jq '[.history[] | select(.event == "review")] | length' "$CODEX_FILE")
  upgrade_dispatches_before=$(wc -l < "$PARITY_DISPATCH_LOG" | tr -d ' ')
  bash "$review_scripts/task-review.sh" "$CODEX_ID" \
    "$provider retries canonical-null upgrade state" \
    > "$TMP/${provider}-canonical-null-retry.out"
  upgrade_dispatches_after=$(wc -l < "$PARITY_DISPATCH_LOG" | tr -d ' ')
  [ "$upgrade_dispatches_after" -eq $((upgrade_dispatches_before + 1)) ] \
    || fail "$provider suppressed a canonical-null retry because of stale legacy metadata"
  jq -e --arg stale "$stale_review_at" --argjson history "$upgrade_history_before" '
    .status == "review"
    and (.meta.review_dispatched_at // "") != ""
    and .meta.review_dispatched_at != $stale
    and (.meta.review_dispatch_status == "delivered" or .meta.review_dispatch_status == "queued")
    and .meta.review_dispatch_error == null
    and ([.history[] | select(.event == "review")] | length) == $history
    and ([keys[] | select(startswith("review_"))] | length) == 0
  ' "$CODEX_FILE" >/dev/null \
    || fail "$provider did not normalize canonical-null upgrade state after retry"
done

# Inverse upgrade state: when the canonical .meta object itself is absent, a
# root-only legacy success timestamp remains authoritative. Both consumers must
# create .meta, suppress a duplicate dispatch, migrate the timestamp/status,
# remove all root aliases, and leave review history untouched.
for provider in claude codex; do
  if [ "$provider" = "claude" ]; then
    review_scripts="$CLAUDE_SCRIPTS"
  else
    review_scripts="$CODEX_SCRIPTS"
  fi

  legacy_success_at="2025-02-03T04:05:06Z"
  jq --arg success "$legacy_success_at" '
    .status = "review"
    | del(.meta)
    | .review_prompt_file = "legacy-success-review-prompt.md"
    | .review_dispatched_at = $success
    | .review_dispatch_status = "delivered"
    | .review_dispatch_attempt_at = $success
    | .review_last_dispatch_attempt_at = $success
    | .review_dispatch_attempts = 7
    | .review_dispatch_error = null
  ' "$CODEX_FILE" > "$TMP/${provider}-legacy-success-upgrade.tmp"
  mv "$TMP/${provider}-legacy-success-upgrade.tmp" "$CODEX_FILE"

  legacy_history_before=$(jq '[.history[] | select(.event == "review")] | length' "$CODEX_FILE")
  legacy_dispatches_before=$(wc -l < "$PARITY_DISPATCH_LOG" | tr -d ' ')
  bash "$review_scripts/task-review.sh" "$CODEX_ID" \
    "$provider suppresses migrated legacy success" \
    > "$TMP/${provider}-legacy-success-suppression.out"
  legacy_dispatches_after=$(wc -l < "$PARITY_DISPATCH_LOG" | tr -d ' ')
  [ "$legacy_dispatches_after" -eq "$legacy_dispatches_before" ] \
    || fail "$provider duplicated a legacy-recorded successful reviewer dispatch"
  grep -F 'Not re-dispatching' "$TMP/${provider}-legacy-success-suppression.out" >/dev/null \
    || fail "$provider did not explain legacy-success duplicate suppression"
  jq -e --arg success "$legacy_success_at" --argjson history "$legacy_history_before" '
    .status == "review"
    and .meta.review_dispatched_at == $success
    and .meta.review_dispatch_status == "delivered"
    and ([.history[] | select(.event == "review")] | length) == $history
    and ([keys[] | select(startswith("review_"))] | length) == 0
  ' "$CODEX_FILE" >/dev/null \
    || fail "$provider did not canonically migrate and clean legacy success metadata"
done

[ "$(grep -c 'parity-reviewer' "$PARITY_DISPATCH_LOG")" -ge 2 ] \
  || fail "reviewer routing did not dispatch across both provider paths"

# Context stores are dedicated private data directories, not arbitrary trees.
# Both providers must reject a misconfigured project-like root before changing
# any modes, and confirmed removal must clean legacy orphan history even when
# the current snapshot has already disappeared.
CLAUDE_CONTEXT_SCRIPTS="$ROOT/plugins/session-context/scripts"
CODEX_CONTEXT_SCRIPTS="$ROOT/codex/plugins/session-context/scripts"
for provider in claude codex; do
  if [ "$provider" = "claude" ]; then
    context_scripts="$CLAUDE_CONTEXT_SCRIPTS"
  else
    context_scripts="$CODEX_CONTEXT_SCRIPTS"
  fi

  wrong_store="$TMP/${provider}-misconfigured-context-root"
  mkdir -p "$wrong_store/src"
  printf 'do not chmod a project tree\n' > "$wrong_store/src/app.txt"
  chmod 755 "$wrong_store" "$wrong_store/src"
  chmod 644 "$wrong_store/src/app.txt"
  if SESSION_CONTEXT_HOME="$wrong_store" bash "$context_scripts/list-contexts.sh" \
    > "$TMP/${provider}-wrong-store.out" 2>&1; then
    fail "$provider context accepted a project-like store with unexpected nested content"
  fi
  [ "$(stat -f '%Lp' "$wrong_store" 2>/dev/null || stat -c '%a' "$wrong_store")" = "755" ] \
    || fail "$provider context changed the misconfigured root mode before rejecting it"
  [ "$(stat -f '%Lp' "$wrong_store/src" 2>/dev/null || stat -c '%a' "$wrong_store/src")" = "755" ] \
    || fail "$provider context recursively changed an unexpected directory"
  [ "$(stat -f '%Lp' "$wrong_store/src/app.txt" 2>/dev/null || stat -c '%a' "$wrong_store/src/app.txt")" = "644" ] \
    || fail "$provider context changed an unexpected project file"

  orphan_store="$TMP/${provider}-orphan-contexts"
  mkdir -p "$orphan_store/.history"
  orphan_history="$orphan_store/.history/orphan.20260710-000000Z.md"
  printf 'private orphan history\n' > "$orphan_history"
  SESSION_CONTEXT_HOME="$orphan_store" \
    bash "$context_scripts/remove-context.sh" orphan --confirmed \
    > "$TMP/${provider}-orphan-remove.out" 2>&1 \
    || fail "$provider context could not remove orphan-only history"
  [ ! -e "$orphan_history" ] || fail "$provider context left orphan-only history behind"
done

echo "cross-provider scheduler and context parity tests passed"
