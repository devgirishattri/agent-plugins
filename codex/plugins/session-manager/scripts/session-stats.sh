#!/usr/bin/env bash
# session-stats.sh - Read-only analytics over local Codex session data.
# Usage: session-stats.sh [project-filter]
#   project-filter: optional substring; limits output to projects whose path
#                   (session cwd) matches (case-insensitive)
# Output:
#   tab-separated rows: PROJECT\tSESSIONS\tSIZE\tLAST-ACTIVE (sorted by last active)
#   a TOTALS line (projects, sessions, total size)
#   a TOP 5 LARGEST SESSIONS section: SIZE\tPROJECT\tNAME
set -uo pipefail

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
SESSIONS_DIR="$CODEX_DIR/sessions"
STATE_DB="$CODEX_DIR/state_5.sqlite"
FILTER="${1:-}"
FILTER_LOWER=$(printf '%s' "$FILTER" | tr '[:upper:]' '[:lower:]')

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
    if [ "$bytes" -ge 1073741824 ] 2>/dev/null; then
        echo "$(( bytes / 1073741824 )).$(( (bytes % 1073741824) * 10 / 1073741824 )) GB"
    elif [ "$bytes" -ge 1048576 ] 2>/dev/null; then
        echo "$(( bytes / 1048576 )) MB"
    elif [ "$bytes" -ge 1024 ] 2>/dev/null; then
        echo "$(( bytes / 1024 )) KB"
    else
        echo "${bytes} B"
    fi
}

human_age() {
    local seconds="$1"
    if [ "$seconds" -lt 0 ] 2>/dev/null; then
        seconds=0
    fi
    if [ "$seconds" -lt 60 ]; then
        echo "just now"
    elif [ "$seconds" -lt 3600 ]; then
        echo "$(( seconds / 60 ))m ago"
    elif [ "$seconds" -lt 86400 ]; then
        echo "$(( seconds / 3600 ))h ago"
    else
        echo "$(( seconds / 86400 ))d ago"
    fi
}

file_size_bytes() {
    if [[ "$(uname)" == "Darwin" ]]; then
        stat -f '%z' "$1" 2>/dev/null || echo "0"
    else
        stat -c '%s' "$1" 2>/dev/null || echo "0"
    fi
}

file_mtime_epoch() {
    if [[ "$(uname)" == "Darwin" ]]; then
        stat -f '%m' "$1" 2>/dev/null || echo "0"
    else
        stat -c '%Y' "$1" 2>/dev/null || echo "0"
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
    # Same convention as list-sessions.sh: thread title from state DB,
    # falling back to the first user message.
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

    printf '%s' "$title" | tr '\t\r\n' '   ' | cut -c1-80
}

NOW=$(date +%s)
session_rows=""

while IFS= read -r jsonl_file; do
    [ -n "$jsonl_file" ] || continue
    project_path=$(json_field "$jsonl_file" '.payload.cwd')
    [ -n "$project_path" ] || continue

    if [ -n "$FILTER_LOWER" ]; then
        project_lower=$(printf '%s' "$project_path" | tr '[:upper:]' '[:lower:]')
        echo "$project_lower" | grep -qF "$FILTER_LOWER" || continue
    fi

    size=$(file_size_bytes "$jsonl_file")
    mtime=$(file_mtime_epoch "$jsonl_file")
    session_rows="${session_rows}$(printf '%s\t%s\t%s\t%s' "$size" "$mtime" "$project_path" "$jsonl_file")"$'\n'
done < <(find "$SESSIONS_DIR" -type f -name '*.jsonl' 2>/dev/null)

if [ -z "$session_rows" ]; then
    if [ -n "$FILTER" ]; then
        echo "No sessions found matching filter: $FILTER"
    else
        echo "No sessions found"
    fi
    exit 0
fi

total_sessions=$(printf '%s' "$session_rows" | grep -c .)
total_bytes=$(printf '%s' "$session_rows" | awk -F'\t' '{ sum += $1 } END { printf "%d", sum }')
total_projects=$(printf '%s' "$session_rows" | cut -f3 | sort -u | grep -c .)

printf 'PROJECT\tSESSIONS\tSIZE\tLAST-ACTIVE\n'
printf '%s' "$session_rows" | awk -F'\t' '
{
    count[$3]++
    bytes[$3] += $1
    if ($2 > newest[$3]) newest[$3] = $2
}
END {
    for (p in count) printf "%s\t%s\t%s\t%s\n", newest[p], p, count[p], bytes[p]
}
' | sort -t$'\t' -k1,1nr | while IFS=$'\t' read -r newest_mtime project_path session_count project_bytes; do
    printf '%s\t%s\t%s\t%s\n' "$project_path" "$session_count" "$(human_size "$project_bytes")" "$(human_age $(( NOW - newest_mtime )))"
done

echo ""
printf 'TOTALS\t%s projects\t%s sessions\t%s\n' "$total_projects" "$total_sessions" "$(human_size "$total_bytes")"

echo ""
echo "TOP 5 LARGEST SESSIONS"
printf 'SIZE\tPROJECT\tNAME\n'
printf '%s' "$session_rows" | sort -t$'\t' -k1,1nr | head -5 | while IFS=$'\t' read -r size mtime project_path jsonl_file; do
    session_id=$(json_field "$jsonl_file" '.payload.id')
    printf '%s\t%s\t%s\n' "$(human_size "$size")" "$project_path" "$(session_title "$jsonl_file" "$session_id")"
done
