#!/usr/bin/env bash
# delete-session.sh - Delete all data for a session UUID
# Usage: delete-session.sh <full-session-uuid>
# SAFETY: Only accepts full UUIDs (36 chars, standard format)
# Supported platforms: macOS, Linux, Windows (WSL only)
set -euo pipefail

SESSION_ID="${1:-}"

# Strict UUID validation
if ! echo "$SESSION_ID" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
    echo "ERROR: Invalid session ID format."
    echo "Must be a full UUID (e.g., b3591ff4-9c80-4119-b0a2-ea47524297d4)"
    echo "Use /session-search or /session-list to find the full UUID."
    exit 1
fi

CLAUDE_DIR="$HOME/.claude"
deleted_count=0
failed_count=0

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

echo "Deleting session: $SESSION_ID"
echo "================================"

# Verify paths resolve within CLAUDE_DIR (defense-in-depth)
verify_path() {
    local path="$1"
    case "$path" in
        "$CLAUDE_DIR"/*) return 0 ;;
        *) return 1 ;;
    esac
}

# 1. Find and delete transcript JSONL (could be in any project directory)
for jsonl_file in "$CLAUDE_DIR/projects"/*/"${SESSION_ID}.jsonl"; do
    if [ -f "$jsonl_file" ] && verify_path "$jsonl_file"; then
        if rm "$jsonl_file" 2>/dev/null; then
            report_delete "Transcript" "$jsonl_file"
        else
            report_fail "Transcript" "$jsonl_file"
        fi
    fi
done

# 2. Delete subagent data directory
for subagent_dir in "$CLAUDE_DIR/projects"/*/"${SESSION_ID}"; do
    if [ -d "$subagent_dir" ] && verify_path "$subagent_dir"; then
        if rm -rf "$subagent_dir" 2>/dev/null; then
            report_delete "Subagent data" "$subagent_dir"
        else
            report_fail "Subagent data" "$subagent_dir"
        fi
    fi
done

# 3. Delete session environment
if [ -d "$CLAUDE_DIR/session-env/$SESSION_ID" ]; then
    if rm -rf "$CLAUDE_DIR/session-env/$SESSION_ID" 2>/dev/null; then
        report_delete "Session env" "$CLAUDE_DIR/session-env/$SESSION_ID"
    else
        report_fail "Session env" "$CLAUDE_DIR/session-env/$SESSION_ID"
    fi
fi

# 4. Delete debug log
if [ -f "$CLAUDE_DIR/debug/$SESSION_ID.txt" ]; then
    if rm "$CLAUDE_DIR/debug/$SESSION_ID.txt" 2>/dev/null; then
        report_delete "Debug log" "$CLAUDE_DIR/debug/$SESSION_ID.txt"
    else
        report_fail "Debug log" "$CLAUDE_DIR/debug/$SESSION_ID.txt"
    fi
fi

# 5. Delete file history
if [ -d "$CLAUDE_DIR/file-history/$SESSION_ID" ]; then
    if rm -rf "$CLAUDE_DIR/file-history/$SESSION_ID" 2>/dev/null; then
        report_delete "File history" "$CLAUDE_DIR/file-history/$SESSION_ID"
    else
        report_fail "File history" "$CLAUDE_DIR/file-history/$SESSION_ID"
    fi
fi

# 6. Delete todo files
for todo_file in "$CLAUDE_DIR/todos/${SESSION_ID}-agent-"*.json; do
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
if [ -f "$HISTORY_FILE" ]; then
    SEARCH_STRING="\"sessionId\":\"${SESSION_ID}\""
    match_count=$(grep -cF "$SEARCH_STRING" "$HISTORY_FILE" 2>/dev/null | head -1 || true)
    match_count="${match_count:-0}"
    if [ "$match_count" -gt 0 ]; then
        TEMP_FILE=$(mktemp)
        # Use flock for atomic update if available, fallback to direct write
        if command -v flock >/dev/null 2>&1; then
            (
                flock -w 5 200 || { rm -f "$TEMP_FILE"; report_fail "History entries" "$HISTORY_FILE" "could not acquire lock"; exit 0; }
                grep -vF "$SEARCH_STRING" "$HISTORY_FILE" > "$TEMP_FILE" 2>/dev/null || true
                mv "$TEMP_FILE" "$HISTORY_FILE"
            ) 200>"$LOCK_FILE"
            if [ $? -eq 0 ]; then
                echo "  Removed $match_count entries from history.jsonl"
                deleted_count=$(( deleted_count + 1 ))
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

echo ""
echo "================================"
if [ "$deleted_count" -eq 0 ]; then
    echo "No data found for session: $SESSION_ID"
elif [ "$failed_count" -gt 0 ]; then
    echo "WARNING: Partial deletion — $deleted_count deleted, $failed_count failed"
    echo "Some session data may remain. Check permissions and retry."
    exit 1
else
    echo "Deleted: $deleted_count items | Failed: $failed_count items"
fi
