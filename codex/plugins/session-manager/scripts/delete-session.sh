#!/usr/bin/env bash
# delete-session.sh - Delete local Codex rollout data for a session UUID.
# Usage: delete-session.sh <full-session-uuid>
set -euo pipefail

SESSION_ID="${1:-}"

if ! echo "$SESSION_ID" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
    echo "ERROR: Invalid session ID format."
    echo "Must be a full UUID (e.g., 019dd49e-8bfc-7952-ac17-bc0aa9ebd8ce)."
    echo "Use /session-search or /session-list to find the full UUID."
    exit 1
fi

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
SESSIONS_DIR="$CODEX_DIR/sessions"
SNAPSHOTS_DIR="$CODEX_DIR/shell_snapshots"
deleted_count=0
failed_count=0

report_delete() {
    echo "  Deleted $1: $2"
    deleted_count=$(( deleted_count + 1 ))
}

report_fail() {
    echo "  FAILED $1: $2 (${3:-permission denied})"
    failed_count=$(( failed_count + 1 ))
}

verify_path() {
    local path="$1"
    case "$path" in
        "$CODEX_DIR"/*) return 0 ;;
        *) return 1 ;;
    esac
}

echo "Deleting Codex session: $SESSION_ID"
echo "===================================="

if [ -d "$SESSIONS_DIR" ]; then
    while read -r jsonl_file; do
        if grep -qF "\"id\":\"$SESSION_ID\"" "$jsonl_file" 2>/dev/null && verify_path "$jsonl_file"; then
            if rm "$jsonl_file" 2>/dev/null; then
                report_delete "Rollout" "$jsonl_file"
            else
                report_fail "Rollout" "$jsonl_file"
            fi
        fi
    done < <(find "$SESSIONS_DIR" -type f -name '*.jsonl' 2>/dev/null)
fi

if [ -d "$SNAPSHOTS_DIR" ]; then
    for snapshot in "$SNAPSHOTS_DIR/$SESSION_ID".*.sh; do
        if [ -f "$snapshot" ] && verify_path "$snapshot"; then
            if rm "$snapshot" 2>/dev/null; then
                report_delete "Shell snapshot" "$snapshot"
            else
                report_fail "Shell snapshot" "$snapshot"
            fi
        fi
    done
fi

echo ""
echo "===================================="
if [ "$deleted_count" -eq 0 ]; then
    echo "No file data found for session: $SESSION_ID"
elif [ "$failed_count" -gt 0 ]; then
    echo "WARNING: Partial deletion - $deleted_count deleted, $failed_count failed"
    exit 1
else
    echo "Deleted: $deleted_count items | Failed: $failed_count items"
fi
