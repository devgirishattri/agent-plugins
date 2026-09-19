#!/usr/bin/env bash
# delete-all-sessions.sh - Bulk-delete every Codex session for ONE project path.
# Usage: delete-all-sessions.sh --plan|--confirmed [project-path]
#   No project-path arg: uses the current working directory's project.
# SAFETY:
#   - Scoped to one project path; refuses "all"/global wipes.
#   - Preflights native metadata, plans eligible candidates, then rechecks each UUID's
#     project against native state before delegating removal to delete-session.sh.
#   - Requires an explicit confirmation token supplied only after user consent.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONFIRMATION="${1:-}"
FILTER="${2:-$(pwd)}"

if [ "$#" -gt 2 ] || { [ "$CONFIRMATION" != "--confirmed" ] && [ "$CONFIRMATION" != "--plan" ]; }; then
    echo "CANCELLED: Explicit final confirmation is required before bulk deletion."
    echo "Only run this helper with --confirmed after the user answers the final confirmation question affirmatively."
    exit 2
fi

if [ "$FILTER" = "all" ]; then
    echo "ERROR: Refusing a global wipe. Pass a single project path (defaults to the current dir)."
    echo "This flag only deletes sessions for one project directory at a time."
    exit 1
fi

if echo "$FILTER" | grep -qE '(^|/)\.\.(/|$)'; then
    echo "ERROR: Invalid path (path traversal not allowed)"
    exit 1
fi

FILTER=$(cd "$FILTER" && pwd -P) || { echo "ERROR: Project directory is unavailable." >&2; exit 1; }

plan=$(python3 "$SCRIPT_DIR/session-metadata.py" delete-plan --project "$FILTER") || exit 1
echo "Project: $FILTER"
printf 'STATUS\tSESSION_ID\tTHREAD\tREASON\n'
[ -z "$plan" ] || printf '%s\n' "$plan"
session_ids=$(printf '%s\n' "$plan" | awk -F '\t' '$1 == "ELIGIBLE" { print $2 }')
skipped=$(printf '%s\n' "$plan" | awk -F '\t' '$1 == "SKIP" { count++ } END { print count+0 }')
total=$(printf '%s\n' "$plan" | awk -F '\t' '$1 == "ELIGIBLE" { count++ } END { print count+0 }')
echo "Plan: $total eligible | $skipped skipped"
[ "$CONFIRMATION" != "--plan" ] || exit 0

if [ -z "$session_ids" ]; then
    echo "No eligible sessions to delete for project: $FILTER"
    [ "$skipped" -eq 0 ]
    exit $?
fi

echo "Bulk-deleting $total session(s) for project: $FILTER"
echo "===================================="

ok=0
fail=0
failed_ids=()
while IFS= read -r sid; do
    [ -z "$sid" ] && continue
    echo ""
    echo "Deleting session: $sid"
    if python3 "$SCRIPT_DIR/session-metadata.py" verify-project "$sid" --project "$FILTER" \
        && bash "$SCRIPT_DIR/delete-session.sh" "$sid" --confirmed; then
        ok=$(( ok + 1 ))
    else
        fail=$(( fail + 1 ))
        failed_ids+=("$sid")
        echo "FAILED: $sid (see diagnostic above)" >&2
    fi
done < <(printf '%s\n' "$session_ids")

echo ""
echo "===================================="
echo "Sessions: $total processed | $ok fully deleted | $fail with failures | $skipped skipped"
if [ "$fail" -gt 0 ] || [ "$skipped" -gt 0 ]; then
    [ "$fail" -eq 0 ] || printf 'Failed UUID: %s\n' "${failed_ids[@]}"
    echo "Some sessions remain. Review the per-session reasons before retrying."
    exit 1
fi
