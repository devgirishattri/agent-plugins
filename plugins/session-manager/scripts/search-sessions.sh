#!/usr/bin/env bash
# search-sessions.sh - Search sessions by name, ID prefix, or project path
# Usage: search-sessions.sh <query>
# Output: tab-separated lines matching the query
# Supported platforms: macOS, Linux, Windows (WSL only)
set -uo pipefail

QUERY="${1:-}"
if [ -z "$QUERY" ]; then
    echo "ERROR: No search query provided"
    echo "Usage: /session-search <name-or-id-or-project>"
    exit 1
fi

# Sanitize input: strip shell metacharacters and control characters
QUERY=$(printf '%s' "$QUERY" | tr -d '\0-\37\177' | sed 's/[;&|`$(){}\\!]//g')
if [ -z "$QUERY" ]; then
    echo "ERROR: Query contains only invalid characters"
    exit 1
fi

CLAUDE_DIR="$HOME/.claude"
PROJECTS_DIR="$CLAUDE_DIR/projects"

if [ ! -d "$PROJECTS_DIR" ]; then
    echo "No sessions found"
    exit 0
fi

QUERY_LOWER=$(printf '%s' "$QUERY" | tr '[:upper:]' '[:lower:]')

decode_project_path() {
    local encoded="$1"
    echo "$encoded" | sed 's/^-/\//' | sed 's/-/\//g'
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

found=0

find "$PROJECTS_DIR" -maxdepth 2 -name '*.jsonl' -type f 2>/dev/null | while read -r jsonl_file; do
    filename=$(basename "$jsonl_file" .jsonl)
    session_id="$filename"

    if ! echo "$session_id" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
        continue
    fi

    project_dir=$(basename "$(dirname "$jsonl_file")")
    project_path=$(decode_project_path "$project_dir")

    custom_title=$(grep -a '"type":"custom-title"' "$jsonl_file" 2>/dev/null | tail -1 | sed -n 's/.*"customTitle":"\([^"]*\)".*/\1/p') || true
    if [ -z "$custom_title" ]; then
        custom_title="(untitled)"
    fi

    # Case-insensitive matching against name, ID, and project
    title_lower=$(echo "$custom_title" | tr '[:upper:]' '[:lower:]')
    project_lower=$(echo "$project_path" | tr '[:upper:]' '[:lower:]')
    match=0

    # Match by name substring
    if echo "$title_lower" | grep -qF "$QUERY_LOWER" 2>/dev/null; then
        match=1
    fi

    # Match by session ID prefix (use grep -F for fixed string matching)
    if [ "${session_id#"$QUERY_LOWER"}" != "$session_id" ] 2>/dev/null; then
        match=1
    fi

    # Match by project path substring
    if echo "$project_lower" | grep -qF "$QUERY_LOWER" 2>/dev/null; then
        match=1
    fi

    if [ "$match" -eq 1 ]; then
        if [[ "$(uname)" == "Darwin" ]]; then
            file_size=$(stat -f '%z' "$jsonl_file" 2>/dev/null || echo "0")
            last_modified=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$jsonl_file" 2>/dev/null || echo "unknown")
        else
            file_size=$(stat -c '%s' "$jsonl_file" 2>/dev/null || echo "0")
            last_modified=$(stat -c '%y' "$jsonl_file" 2>/dev/null | cut -d'.' -f1 || echo "unknown")
        fi

        size_human=$(human_size "$file_size")
        printf '%s\t%s\t%s\t%s\t%s\n' "$custom_title" "$session_id" "$project_path" "$size_human" "$last_modified"
    fi
done | sort -t$'\t' -k5 -r
