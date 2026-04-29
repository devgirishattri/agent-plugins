#!/usr/bin/env bash
# prepare-delete.sh - Resolve a Codex session deletion target into a clear state.
# Usage: prepare-delete.sh [session-id-or-name]
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TARGET="${1:-}"

print_header() {
    printf 'THREAD\tSESSION_ID\tPROJECT\tSIZE\tLAST_MODIFIED\n'
}

count_session_rows() {
    awk -F '\t' 'NF >= 5 { count++ } END { print count + 0 }'
}

if [ -z "$TARGET" ]; then
    sessions=$(bash "$SCRIPT_DIR/list-sessions.sh")
    row_count=$(printf '%s\n' "$sessions" | count_session_rows)

    if [ "$row_count" -eq 0 ]; then
        printf 'STATUS\tNONE\n'
        printf 'MESSAGE\tNo sessions were found for the current project.\n'
        exit 0
    fi

    printf 'STATUS\tSELECT\n'
    printf 'MESSAGE\tNo target was provided. Ask the user which session to delete.\n'
    print_header
    printf '%s\n' "$sessions"
    exit 0
fi

matches=$(bash "$SCRIPT_DIR/search-sessions.sh" "$TARGET")
match_count=$(printf '%s\n' "$matches" | count_session_rows)

case "$match_count" in
    0)
        printf 'STATUS\tNONE\n'
        printf 'MESSAGE\tNo sessions matched: %s\n' "$TARGET"
        ;;
    1)
        printf 'STATUS\tONE\n'
        printf 'MESSAGE\tExactly one session matched. Ask for explicit confirmation before deleting.\n'
        print_header
        printf '%s\n' "$matches"
        ;;
    *)
        printf 'STATUS\tMULTIPLE\n'
        printf 'MESSAGE\tMultiple sessions matched. Ask the user to provide the full UUID.\n'
        print_header
        printf '%s\n' "$matches"
        ;;
esac
