#!/usr/bin/env bash
# delete-session.sh - Delete all data for a session UUID
# Usage: delete-session.sh <full-session-uuid> --confirmed
# SAFETY: Only accepts full UUIDs (36 chars, standard format), and requires an
#   explicit --confirmed capability flag (the /session-delete command passes it
#   only AFTER an AskUserQuestion default-cancel confirmation).
# Supported platforms: macOS, Linux, Windows (WSL only)
set -euo pipefail

SESSION_ID=""
CONFIRMED=0
for arg in "$@"; do
    case "$arg" in
        --confirmed) CONFIRMED=1 ;;
        *) [ -z "$SESSION_ID" ] && SESSION_ID="$arg" ;;
    esac
done

# Strict UUID validation
if ! echo "$SESSION_ID" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
    echo "ERROR: Invalid session ID format."
    echo "Must be a full UUID (e.g., b3591ff4-9c80-4119-b0a2-ea47524297d4)"
    echo "Use /session-search or /session-list to find the full UUID."
    exit 1
fi

# Destructive capability gate — refuse without explicit confirmation.
if [ "$CONFIRMED" != "1" ]; then
    echo "REFUSED: deleting session $SESSION_ID removes all of its data and cannot be undone." >&2
    echo "  Re-run through /session-delete (which confirms first), or pass --confirmed to the script explicitly." >&2
    exit 2
fi

CLAUDE_DIR="$HOME/.claude"
deleted_count=0
failed_count=0

# Physical (symlink-resolved) absolute path of a directory, empty if it can't be
# entered. `pwd -P` resolves EVERY symlinked path component, so a symlinked
# ancestor can never disguise an out-of-tree location as living under CLAUDE_DIR.
canonical_dir() {
    ( cd "$1" 2>/dev/null && pwd -P ) || true
}

# The real ~/.claude, resolved once. All deletions must stay within this. If the
# user symlinks ~/.claude itself to a real dir, that resolved dir is the intended
# boundary; if it can't be resolved, safe_target fails closed below.
CLAUDE_DIR_REAL="$(canonical_dir "$CLAUDE_DIR")"

# within_boundary <boundary> <path> — true only when <path> equals <boundary> or
# sits strictly beneath it. The trailing-slash form makes this a real path-
# boundary test: a sibling like "<boundary>-evil" can never be treated as inside
# (a bare string-prefix check would wrongly accept it).
within_boundary() {
    local boundary="$1" path="$2"
    [ -n "$boundary" ] && [ -n "$path" ] || return 1
    [ "$path" = "$boundary" ] && return 0
    case "$path" in
        "$boundary"/*) return 0 ;;
        *) return 1 ;;
    esac
}

# safe_target <path> — 0 only when deleting <path> stays inside the real
# CLAUDE_DIR with NO symlinked ancestor escaping the boundary. We canonicalize
# the PARENT directory (its physical location) and require it within the
# canonical CLAUDE_DIR: rm of a symlink leaf merely unlinks the leaf (harmless),
# but rm -rf reached THROUGH a symlinked parent would delete real content
# outside the tree. Returns 1 (delete nothing) on any canonicalization failure.
safe_target() {
    local path="$1" parent parent_real
    [ -n "$CLAUDE_DIR_REAL" ] || return 1
    parent="$(dirname "$path")"
    parent_real="$(canonical_dir "$parent")"
    [ -n "$parent_real" ] || return 1
    within_boundary "$CLAUDE_DIR_REAL" "$parent_real"
}

# safe_leaf <path> — 0 when <path> is ABSENT (nothing to clobber) or is a plain,
# owner-owned, single-hardlink regular file; non-zero for a symlink, a non-regular
# file (FIFO/device/dir), a file owned by another user, or one with an extra
# hardlink (a second link means an out-of-tree path shares the inode, so reading
# leaks it and a truncating/overwriting open corrupts it). Gates history.jsonl and
# its lock before any read/rewrite/lock-open. GNU stat first, BSD stat fallback.
safe_leaf() {
    local path="$1" links
    [ -L "$path" ] && return 1
    [ -e "$path" ] || return 0
    [ -f "$path" ] || return 1
    [ -O "$path" ] || return 1
    links=$(stat -c '%h' "$path" 2>/dev/null || stat -f '%l' "$path" 2>/dev/null)
    case "$links" in
        1) return 0 ;;
        *) return 1 ;;
    esac
}

report_delete() {
    local label="$1"
    local path="$2"
    echo "  Deleted $label: $path"
    deleted_count=$(( deleted_count + 1 ))
}

report_fail() {
    local label="$1"
    local path="$2"
    local reason="${3:-permission denied}"
    echo "  FAILED $label: $path ($reason)"
    failed_count=$(( failed_count + 1 ))
}

# An explicit, loud refusal: a target that resolves OUTSIDE the real ~/.claude
# (via a symlinked ancestor) is never deleted. Counts as a failure so the run
# exits non-zero and the summary can never read as a clean "nothing found".
report_refuse() {
    local label="$1"
    local path="$2"
    echo "  REFUSED $label: $path (resolves outside the real ~/.claude boundary — symlinked ancestor?)" >&2
    failed_count=$(( failed_count + 1 ))
}

echo "Deleting session: $SESSION_ID"
echo "================================"

# 1. Find and delete transcript JSONL (could be in any project directory)
for jsonl_file in "$CLAUDE_DIR/projects"/*/"${SESSION_ID}.jsonl"; do
    [ -e "$jsonl_file" ] || continue
    if ! safe_target "$jsonl_file"; then
        report_refuse "Transcript" "$jsonl_file"; continue
    fi
    if [ -f "$jsonl_file" ]; then
        if rm "$jsonl_file" 2>/dev/null; then
            report_delete "Transcript" "$jsonl_file"
        else
            report_fail "Transcript" "$jsonl_file"
        fi
    fi
done

# 2. Delete subagent data directory
for subagent_dir in "$CLAUDE_DIR/projects"/*/"${SESSION_ID}"; do
    [ -e "$subagent_dir" ] || continue
    if ! safe_target "$subagent_dir"; then
        report_refuse "Subagent data" "$subagent_dir"; continue
    fi
    if [ -d "$subagent_dir" ]; then
        if rm -rf "$subagent_dir" 2>/dev/null; then
            report_delete "Subagent data" "$subagent_dir"
        else
            report_fail "Subagent data" "$subagent_dir"
        fi
    fi
done

# 3. Delete session environment
if [ -e "$CLAUDE_DIR/session-env/$SESSION_ID" ]; then
    if ! safe_target "$CLAUDE_DIR/session-env/$SESSION_ID"; then
        report_refuse "Session env" "$CLAUDE_DIR/session-env/$SESSION_ID"
    elif [ -d "$CLAUDE_DIR/session-env/$SESSION_ID" ]; then
        if rm -rf "$CLAUDE_DIR/session-env/$SESSION_ID" 2>/dev/null; then
            report_delete "Session env" "$CLAUDE_DIR/session-env/$SESSION_ID"
        else
            report_fail "Session env" "$CLAUDE_DIR/session-env/$SESSION_ID"
        fi
    fi
fi

# 4. Delete debug log
if [ -e "$CLAUDE_DIR/debug/$SESSION_ID.txt" ]; then
    if ! safe_target "$CLAUDE_DIR/debug/$SESSION_ID.txt"; then
        report_refuse "Debug log" "$CLAUDE_DIR/debug/$SESSION_ID.txt"
    elif [ -f "$CLAUDE_DIR/debug/$SESSION_ID.txt" ]; then
        if rm "$CLAUDE_DIR/debug/$SESSION_ID.txt" 2>/dev/null; then
            report_delete "Debug log" "$CLAUDE_DIR/debug/$SESSION_ID.txt"
        else
            report_fail "Debug log" "$CLAUDE_DIR/debug/$SESSION_ID.txt"
        fi
    fi
fi

# 5. Delete file history
if [ -e "$CLAUDE_DIR/file-history/$SESSION_ID" ]; then
    if ! safe_target "$CLAUDE_DIR/file-history/$SESSION_ID"; then
        report_refuse "File history" "$CLAUDE_DIR/file-history/$SESSION_ID"
    elif [ -d "$CLAUDE_DIR/file-history/$SESSION_ID" ]; then
        if rm -rf "$CLAUDE_DIR/file-history/$SESSION_ID" 2>/dev/null; then
            report_delete "File history" "$CLAUDE_DIR/file-history/$SESSION_ID"
        else
            report_fail "File history" "$CLAUDE_DIR/file-history/$SESSION_ID"
        fi
    fi
fi

# 6. Delete todo files
for todo_file in "$CLAUDE_DIR/todos/${SESSION_ID}-agent-"*.json; do
    [ -e "$todo_file" ] || continue
    if ! safe_target "$todo_file"; then
        report_refuse "Todo" "$todo_file"; continue
    fi
    if [ -f "$todo_file" ]; then
        if rm "$todo_file" 2>/dev/null; then
            report_delete "Todo" "$todo_file"
        else
            report_fail "Todo" "$todo_file"
        fi
    fi
done

# 7. Clean history.jsonl entries (using grep -F for fixed string matching)
HISTORY_FILE="$CLAUDE_DIR/history.jsonl"
LOCK_FILE="$CLAUDE_DIR/history.jsonl.lock"
if [ -e "$HISTORY_FILE" ]; then
    # Fail closed on any unsafe history/lock leaf: a symlink, extra hardlink,
    # wrong owner, non-regular file, or a symlinked ~/.claude ancestor could leak
    # or clobber an out-of-tree file when we read/rewrite history or open the lock.
    # The lock leaf is validated too — a hardlinked lock opened with a truncating
    # redirection would truncate the file it links to (hence the non-truncating
    # `200>>` open below, plus this check).
    if ! safe_target "$HISTORY_FILE" || ! safe_leaf "$HISTORY_FILE" || ! safe_leaf "$LOCK_FILE"; then
        report_refuse "History entries" "$HISTORY_FILE"
    elif [ -f "$HISTORY_FILE" ]; then
        SEARCH_STRING="\"sessionId\":\"${SESSION_ID}\""
        match_count=$(grep -cF "$SEARCH_STRING" "$HISTORY_FILE" 2>/dev/null | head -1 || true)
        match_count="${match_count:-0}"
        if [ "$match_count" -gt 0 ]; then
            # Private rewrite temp BESIDE history (mktemp = O_EXCL 0600, same fs so
            # the mv is an atomic same-filesystem rename).
            TEMP_FILE=$(mktemp "$HISTORY_FILE.XXXXXX") || TEMP_FILE=""
            if [ -z "$TEMP_FILE" ]; then
                report_fail "History entries" "$HISTORY_FILE" "could not create temp file"
            elif command -v flock >/dev/null 2>&1; then
                # Non-truncating lock open (200>>): never truncate whatever the lock
                # path resolves to, even before flock is held. The subshell exits
                # NONZERO (3=lock, 4=mv) on failure so the parent — not the lost
                # subshell — updates the counters and reports. A lock/mv failure
                # must NOT be misreported as a successful "Removed".
                if (
                    flock -w 5 200 || exit 3
                    grep -vF "$SEARCH_STRING" "$HISTORY_FILE" > "$TEMP_FILE" 2>/dev/null || true
                    mv "$TEMP_FILE" "$HISTORY_FILE" || exit 4
                ) 200>>"$LOCK_FILE"; then
                    echo "  Removed $match_count entries from history.jsonl"
                    deleted_count=$(( deleted_count + 1 ))
                else
                    rc=$?
                    rm -f "$TEMP_FILE" 2>/dev/null
                    if [ "$rc" -eq 3 ]; then
                        report_fail "History entries" "$HISTORY_FILE" "could not acquire lock"
                    else
                        report_fail "History entries" "$HISTORY_FILE" "could not update"
                    fi
                fi
                rm -f "$LOCK_FILE" 2>/dev/null
            else
                # macOS fallback: no flock, use direct write
                grep -vF "$SEARCH_STRING" "$HISTORY_FILE" > "$TEMP_FILE" 2>/dev/null || true
                if mv "$TEMP_FILE" "$HISTORY_FILE" 2>/dev/null; then
                    echo "  Removed $match_count entries from history.jsonl"
                    deleted_count=$(( deleted_count + 1 ))
                else
                    rm -f "$TEMP_FILE" 2>/dev/null
                    report_fail "History entries" "$HISTORY_FILE" "could not update"
                fi
            fi
        fi
    fi
fi

echo ""
echo "================================"
# Check failures FIRST: a refused (unsafe) target must surface loudly even when
# nothing was deleted — otherwise a run that refused everything would read as a
# benign "No data found" and exit 0.
if [ "$failed_count" -gt 0 ]; then
    echo "WARNING: Partial deletion — $deleted_count deleted, $failed_count failed/refused"
    echo "Some session data was preserved (refused as unsafe) or could not be removed. See messages above."
    exit 1
elif [ "$deleted_count" -eq 0 ]; then
    echo "No data found for session: $SESSION_ID"
else
    echo "Deleted: $deleted_count items | Failed: $failed_count items"
fi
