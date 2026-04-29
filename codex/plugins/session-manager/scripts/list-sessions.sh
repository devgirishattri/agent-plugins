#!/usr/bin/env bash
# list-sessions.sh - List Codex sessions.
# Usage: list-sessions.sh [project-path|all]
# Output: tab-separated lines: THREAD\tSESSION_ID\tPROJECT\tSIZE\tLAST_MODIFIED
set -uo pipefail

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
SESSIONS_DIR="$CODEX_DIR/sessions"
STATE_DB="$CODEX_DIR/state_5.sqlite"
FILTER="${1:-$(pwd)}"

if [ ! -d "$SESSIONS_DIR" ]; then
    echo "No sessions found (sessions directory does not exist)"
    exit 0
fi

json_field() {
    local file="$1"
    local expr="$2"
    if command -v jq >/dev/null 2>&1; then
        jq -r "$expr // empty" "$file" 2>/dev/null | head -1
    else
        case "$expr" in
            ".payload.id") head -1 "$file" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' ;;
            ".payload.cwd") head -1 "$file" | sed -n 's/.*"cwd":"\([^"]*\)".*/\1/p' ;;
            *) return 0 ;;
        esac
    fi
}

human_size() {
    local bytes="$1"
    if [ "$bytes" -ge 1048576 ] 2>/dev/null; then
        echo "$(( bytes / 1048576 )) MB"
    elif [ "$bytes" -ge 1024 ] 2>/dev/null; then
        echo "$(( bytes / 1024 )) KB"
    else
        echo "${bytes} B"
    fi
}

thread_title() {
    local session_id="$1"
    local title=""

    if command -v sqlite3 >/dev/null 2>&1 && [ -f "$STATE_DB" ]; then
        title=$(sqlite3 "$STATE_DB" "select title from threads where id = '$session_id' limit 1;" 2>/dev/null | head -1)
    fi

    printf '%s' "$title"
}

session_title() {
    local file="$1"
    local session_id="$2"
    local title=""

    title=$(thread_title "$session_id")

    if command -v jq >/dev/null 2>&1; then
        [ -z "$title" ] && title=$(jq -r '
            select(.type == "event_msg" and .payload.type == "user_message")
            | .payload.message // .payload.text // empty
        ' "$file" 2>/dev/null | head -1)
    fi

    if [ -z "$title" ]; then
        title=$(grep -a '"type":"user_message"' "$file" 2>/dev/null | head -1 | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')
    fi

    if [ -z "$title" ]; then
        title="(untitled)"
    fi

    printf '%s' "$title" | tr '\t\r\n' '   '
}

find "$SESSIONS_DIR" -type f -name '*.jsonl' 2>/dev/null | while read -r jsonl_file; do
    session_id=$(json_field "$jsonl_file" '.payload.id')
    project_path=$(json_field "$jsonl_file" '.payload.cwd')

    if [ -z "$session_id" ] || [ -z "$project_path" ]; then
        continue
    fi

    if ! echo "$session_id" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
        continue
    fi

    if [ "$FILTER" != "all" ] && [ "$project_path" != "$FILTER" ]; then
        continue
    fi

    if [[ "$(uname)" == "Darwin" ]]; then
        file_size=$(stat -f '%z' "$jsonl_file" 2>/dev/null || echo "0")
        last_modified=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$jsonl_file" 2>/dev/null || echo "unknown")
    else
        file_size=$(stat -c '%s' "$jsonl_file" 2>/dev/null || echo "0")
        last_modified=$(stat -c '%y' "$jsonl_file" 2>/dev/null | cut -d'.' -f1 || echo "unknown")
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(session_title "$jsonl_file" "$session_id")" \
        "$session_id" \
        "$project_path" \
        "$(human_size "$file_size")" \
        "$last_modified"
done | sort -t$'\t' -k5 -r
