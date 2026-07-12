#!/usr/bin/env bash
# delete-all-sessions.sh - Bulk-delete every session under ONE project directory.
# Usage: delete-all-sessions.sh [project-path]
#   No arg: uses the current working directory's project.
# SAFETY:
#   - Scoped to a single encoded project dir; refuses "all"/global wipes.
#   - Rejects path-traversal and verifies the resolved dir stays inside projects/.
#   - Enumerates session UUIDs, then delegates each removal to delete-session.sh,
#     which re-validates the UUID format before deleting anything.
# Supported platforms: macOS, Linux, Windows (WSL only)
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CLAUDE_DIR="$HOME/.claude"
PROJECTS_DIR="$CLAUDE_DIR/projects"

FILTER=""
CONFIRMED=0
for arg in "$@"; do
    case "$arg" in
        --confirmed) CONFIRMED=1 ;;
        *) [ -z "$FILTER" ] && FILTER="$arg" ;;
    esac
done
[ -z "$FILTER" ] && FILTER="$(pwd)"

if [ "$FILTER" = "all" ]; then
    echo "ERROR: Refusing a global wipe. Pass a single project path (defaults to the current dir)."
    echo "This flag only deletes sessions for one project directory at a time."
    exit 1
fi

if [ ! -d "$PROJECTS_DIR" ]; then
    echo "No sessions found (projects directory does not exist)"
    exit 0
fi

# Reject path-traversal sequences
if echo "$FILTER" | grep -qE '(^|/)\.\.(/|$)'; then
    echo "ERROR: Invalid path (path traversal not allowed)"
    exit 1
fi

# Encode: /Users/foo/Code/bar -> -Users-foo-Code-bar
encoded=$(printf '%s' "$FILTER" | sed 's|/|-|g')
target="$PROJECTS_DIR/$encoded"
# Verify the resolved path stays STRICTLY within the real PROJECTS_DIR. Both
# sides are canonicalized with `pwd -P` so a symlinked encoded-project dir (or a
# symlinked ancestor) that escapes the tree is resolved to its true location and
# rejected. The trailing-slash boundary (projects/<x>) is a real path test: a
# sibling like "projects-evil" or PROJECTS_DIR itself can never match, unlike the
# old bare-prefix strip which accepted "projects-evil".
projects_real=$(cd "$PROJECTS_DIR" 2>/dev/null && pwd -P) || projects_real=""
resolved=$(cd "$target" 2>/dev/null && pwd -P) || resolved=""
# A MISSING/unreadable target dir is benign: there are simply no sessions for it.
if [ -z "$resolved" ]; then
    echo "No sessions found for project: $FILTER"
    exit 0
fi
# Past this point the target DID resolve. If we cannot establish the projects
# boundary, or the target lands OUTSIDE it (a symlinked encoded-project dir or
# ancestor escaping the tree), that is an actively unsafe condition — fail loudly
# and non-zero, never a benign "no sessions".
if [ -z "$projects_real" ]; then
    echo "REFUSED: cannot resolve the projects directory boundary ($PROJECTS_DIR)." >&2
    exit 2
fi
case "$resolved" in
    "$projects_real"/*) : ;;   # strictly inside the real projects dir — OK
    *)
        echo "REFUSED: project path '$FILTER' resolves OUTSIDE $projects_real (symlinked project dir or ancestor?): $resolved" >&2
        echo "  Refusing to enumerate or delete sessions outside the projects tree." >&2
        exit 2
        ;;
esac

# Collect UUID-named session transcripts directly under the project dir.
# (maxdepth 1 avoids subagent data dirs and the memory/ folder.)
session_ids=$(
    find "$resolved" -maxdepth 1 -name '*.jsonl' -type f 2>/dev/null \
        | while IFS= read -r f; do basename "$f" .jsonl; done \
        | grep -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
        | sort -u
)

if [ -z "$session_ids" ]; then
    echo "No sessions found for project: $FILTER"
    exit 0
fi

total=$(printf '%s\n' "$session_ids" | grep -c .)

# Destructive capability gate — refuse the bulk wipe without explicit
# confirmation (the /session-delete command passes --confirmed only after an
# AskUserQuestion default-cancel confirmation).
if [ "$CONFIRMED" != "1" ]; then
    echo "REFUSED: this would permanently delete all $total session(s) for project: $FILTER" >&2
    echo "  Project dir: $resolved" >&2
    echo "  Re-run through /session-delete --all (which confirms first), or pass --confirmed explicitly." >&2
    exit 2
fi

echo "Bulk-deleting $total session(s) for project: $FILTER"
echo "Project dir: $resolved"
echo "===================================="

ok=0
fail=0
while IFS= read -r sid; do
    [ -z "$sid" ] && continue
    echo ""
    if bash "$SCRIPT_DIR/delete-session.sh" "$sid" --confirmed; then
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
