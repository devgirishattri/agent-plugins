#!/usr/bin/env bash
# delete-all-sessions.sh - Bulk-delete every Codex session for ONE project path.
# Usage: delete-all-sessions.sh --confirmed [project-path]
#   No project-path arg: uses the current working directory's project.
# SAFETY:
#   - Scoped to one project path; refuses "all"/global wipes.
#   - Enumerates candidates through list-sessions.sh, then rechecks each UUID's
#     project against native state before delegating removal to delete-session.sh.
#   - Requires an explicit confirmation token supplied only after user consent.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
SESSIONS_DIR="$CODEX_DIR/sessions"
CONFIRMATION="${1:-}"
FILTER="${2:-$(pwd)}"

if [ "$#" -gt 2 ] || [ "$CONFIRMATION" != "--confirmed" ]; then
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

listing=$(bash "$SCRIPT_DIR/list-sessions.sh" "$FILTER") || {
    echo "ERROR: Cannot enumerate sessions; bulk deletion refused." >&2
    exit 1
}
session_ids=$(printf '%s\n' "$listing" | awk -F '\t' 'NF >= 5 { print $2 }' | sort -u)

if [ -z "$session_ids" ]; then
    echo "No sessions found for project: $FILTER"
    exit 0
fi

total=$(printf '%s\n' "$session_ids" | grep -c .)

echo "Bulk-deleting $total session(s) for project: $FILTER"
echo "Sessions dir: $SESSIONS_DIR"
echo "===================================="

ok=0
fail=0
while IFS= read -r sid; do
    [ -z "$sid" ] && continue
    echo ""
    if python3 "$SCRIPT_DIR/session-metadata.py" verify-project "$sid" --project "$FILTER" \
        && bash "$SCRIPT_DIR/delete-session.sh" "$sid" --confirmed; then
        ok=$(( ok + 1 ))
    else
        fail=$(( fail + 1 ))
    fi
done < <(printf '%s\n' "$session_ids")

echo ""
echo "===================================="
echo "Sessions: $total processed | $ok fully deleted | $fail with failures"
if [ "$fail" -gt 0 ]; then
    echo "WARNING: Some sessions did not delete cleanly. Check permissions and retry."
    exit 1
fi
