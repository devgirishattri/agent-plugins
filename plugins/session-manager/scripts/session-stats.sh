#!/usr/bin/env bash
# session-stats.sh - Read-only analytics over local Claude Code session data
# Usage: session-stats.sh [project-filter]
#   project-filter: optional substring; limits output to projects whose decoded
#                   path matches (case-insensitive)
# Output:
#   tab-separated rows: PROJECT\tSESSIONS\tSIZE\tLAST-ACTIVE (sorted by last active)
#   a TOTALS line (projects, sessions, total size)
#   a TOP 5 LARGEST SESSIONS section: SIZE\tPROJECT\tNAME
# Supported platforms: macOS, Linux
set -uo pipefail

CLAUDE_DIR="${CLAUDE_HOME:-$HOME/.claude}"
PROJECTS_DIR="$CLAUDE_DIR/projects"
FILTER="${1:-}"
FILTER_LOWER=$(printf '%s' "$FILTER" | tr '[:upper:]' '[:lower:]')

if [ ! -d "$PROJECTS_DIR" ]; then
    echo "No sessions found (projects directory does not exist)"
    exit 0
fi

decode_project_path() {
    local encoded="$1"
    # Best-effort decode: strip leading -, replace - with /
    # Note: lossy when directory names contain hyphens
    echo "$encoded" | sed 's/^-/\//' | sed 's/-/\//g'
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

session_name() {
    # Extract last custom-title entry (same helper logic as list-sessions.sh)
    local jsonl_file="$1"
    local custom_title
    custom_title=$(grep -a '"type":"custom-title"' "$jsonl_file" 2>/dev/null | tail -1 | sed -n 's/.*"customTitle":"\([^"]*\)".*/\1/p') || true
    if [ -z "$custom_title" ]; then
        custom_title="(untitled)"
    fi
    printf '%s' "$custom_title"
}

NOW=$(date +%s)
total_projects=0
total_sessions=0
total_bytes=0
project_rows=""
session_index=""

for project_dir in "$PROJECTS_DIR"/*/; do
    [ -d "$project_dir" ] || continue
    encoded=$(basename "$project_dir")
    project_path=$(decode_project_path "$encoded")

    if [ -n "$FILTER_LOWER" ]; then
        project_lower=$(printf '%s' "$project_path" | tr '[:upper:]' '[:lower:]')
        echo "$project_lower" | grep -qF "$FILTER_LOWER" || continue
    fi

    session_count=0
    project_bytes=0
    newest_mtime=0
    while IFS= read -r jsonl_file; do
        [ -n "$jsonl_file" ] || continue
        size=$(file_size_bytes "$jsonl_file")
        mtime=$(file_mtime_epoch "$jsonl_file")
        session_count=$(( session_count + 1 ))
        project_bytes=$(( project_bytes + size ))
        if [ "$mtime" -gt "$newest_mtime" ]; then
            newest_mtime=$mtime
        fi
        session_index="${session_index}$(printf '%s\t%s\t%s' "$size" "$project_path" "$jsonl_file")"$'\n'
    done < <(find "$project_dir" -maxdepth 1 -name '*.jsonl' -type f 2>/dev/null)

    [ "$session_count" -gt 0 ] || continue

    total_projects=$(( total_projects + 1 ))
    total_sessions=$(( total_sessions + session_count ))
    total_bytes=$(( total_bytes + project_bytes ))
    age=$(human_age $(( NOW - newest_mtime )))
    project_rows="${project_rows}$(printf '%s\t%s\t%s\t%s\t%s' "$newest_mtime" "$project_path" "$session_count" "$(human_size "$project_bytes")" "$age")"$'\n'
done

if [ "$total_projects" -eq 0 ]; then
    if [ -n "$FILTER" ]; then
        echo "No sessions found matching filter: $FILTER"
    else
        echo "No sessions found"
    fi
    exit 0
fi

printf 'PROJECT\tSESSIONS\tSIZE\tLAST-ACTIVE\n'
printf '%s' "$project_rows" | sort -t$'\t' -k1,1nr | cut -f2-

echo ""
printf 'TOTALS\t%s projects\t%s sessions\t%s\n' "$total_projects" "$total_sessions" "$(human_size "$total_bytes")"

echo ""
echo "TOP 5 LARGEST SESSIONS"
printf 'SIZE\tPROJECT\tNAME\n'
printf '%s' "$session_index" | sort -t$'\t' -k1,1nr | head -5 | while IFS=$'\t' read -r size project jsonl_file; do
    printf '%s\t%s\t%s\n' "$(human_size "$size")" "$project" "$(session_name "$jsonl_file")"
done
