#!/usr/bin/env bash
# delete-all-sessions.sh - Bulk-delete every Codex session for ONE project path.
# Usage: delete-all-sessions.sh [project-path]
#   No arg: uses the current working directory's project.
# SAFETY:
#   - Scoped to one project path; refuses "all"/global wipes.
#   - Enumerates session UUIDs through list-sessions.sh, then delegates each
#     removal to delete-session.sh, which re-validates the UUID format.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
SESSIONS_DIR="$CODEX_DIR/sessions"
FILTER="${1:-$(pwd)}"

if [ "$FILTER" = "all" ]; then
    echo "ERROR: Refusing a global wipe. Pass a single project path (defaults to the current dir)."
    echo "This flag only deletes sessions for one project directory at a time."
    exit 1
fi

if echo "$FILTER" | grep -qE '(^|/)\.\.(/|$)'; then
    echo "ERROR: Invalid path (path traversal not allowed)"
    exit 1
fi

if [ ! -d "$SESSIONS_DIR" ]; then
    echo "No sessions found (sessions directory does not exist)"
    exit 0
fi

session_ids=$(
    bash "$SCRIPT_DIR/list-sessions.sh" "$FILTER" 2>/dev/null \
        | awk -F '\t' 'NF >= 5 { print $2 }' \
        | grep -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
        | sort -u
)

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
    if bash "$SCRIPT_DIR/delete-session.sh" "$sid"; then
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
