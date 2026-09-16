#!/usr/bin/env bash
# list-sessions.sh - List Codex sessions.
# Usage: list-sessions.sh [project-path|all]
# Output: tab-separated lines: THREAD\tSESSION_ID\tPROJECT\tSIZE\tLAST_MODIFIED
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
SESSIONS_DIR="$CODEX_DIR/sessions"
SESSION_INDEX="$CODEX_DIR/session_index.jsonl"
FILTER="${1:-$(pwd)}"
SESSION_NAMES=""

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

load_session_names() {
    [ -f "$SESSION_INDEX" ] || return 0

    if ! command -v python3 >/dev/null 2>&1; then
        echo "ERROR: python3 is required to read Codex session names." >&2
        return 127
    fi
    SESSION_NAMES=$(python3 "$SCRIPT_DIR/session-names.py" "$SESSION_INDEX")
}

session_name() {
    local session_id="$1"
    local name=""

    if [ -n "$SESSION_NAMES" ]; then
        name=$(printf '%s\n' "$SESSION_NAMES" | awk -F '\t' -v wanted="$session_id" '
            $1 == wanted { name = substr($0, length($1) + 2) }
            END { printf "%s", name }
        ')
    fi

    if [ -z "$name" ]; then
        name="(untitled)"
    fi

    printf '%s' "$name" | tr '\t\r\n' '   '
}

load_session_names || exit $?

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
        "$(session_name "$session_id")" \
        "$session_id" \
        "$project_path" \
        "$(human_size "$file_size")" \
        "$last_modified"
done | sort -t$'\t' -k5 -r
