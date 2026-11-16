#!/usr/bin/env bash
# prepare-archive.sh - Resolve a Codex archive or unarchive target. Read-only.
# Usage: prepare-archive.sh archive|unarchive [session-id-or-name]
# archive looks among active sessions and unarchive among archived ones, so a
# resolved target is always one the native command can act on.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ACTION="${1:-}"
TARGET="${2:-}"

case "$ACTION" in
    archive) STATE=""; KIND="active" ;;
    unarchive) STATE="--archived-only"; KIND="archived" ;;
    *)
        echo "Usage: prepare-archive.sh archive|unarchive [session-id-or-name]" >&2
        exit 2
        ;;
esac
if [ "$#" -gt 2 ]; then
    echo "Usage: prepare-archive.sh archive|unarchive [session-id-or-name]" >&2
    exit 2
fi

print_header() {
    printf 'THREAD\tSESSION_ID\tPROJECT\tSIZE\tLAST_MODIFIED\n'
}

count_session_rows() {
    awk -F '\t' 'NF >= 5 { count++ } END { print count + 0 }'
}

if [ -z "$TARGET" ]; then
    sessions=$(bash "$SCRIPT_DIR/list-sessions.sh" ${STATE:+"$STATE"}) || exit $?
    row_count=$(printf '%s\n' "$sessions" | count_session_rows)

    if [ "$row_count" -eq 0 ]; then
        printf 'STATUS\tNONE\n'
        printf 'MESSAGE\tNo %s sessions were found for the current project.\n' "$KIND"
        exit 0
    fi

    printf 'STATUS\tSELECT\n'
    printf 'MESSAGE\tNo target was provided. Ask the user which %s session to %s.\n' "$KIND" "$ACTION"
    print_header
    printf '%s\n' "$sessions"
    exit 0
fi

matches=$(bash "$SCRIPT_DIR/search-sessions.sh" "$TARGET" ${STATE:+"$STATE"}) || exit $?
match_count=$(printf '%s\n' "$matches" | count_session_rows)

case "$match_count" in
    0)
        printf 'STATUS\tNONE\n'
        printf 'MESSAGE\tNo %s sessions matched: %s\n' "$KIND" "$TARGET"
        ;;
    1)
        printf 'STATUS\tONE\n'
        printf 'MESSAGE\tExactly one %s session matched.\n' "$KIND"
        print_header
        printf '%s\n' "$matches"
        ;;
    *)
        printf 'STATUS\tMULTIPLE\n'
        printf 'MESSAGE\tMultiple %s sessions matched. Ask the user to provide the full UUID.\n' "$KIND"
        print_header
        printf '%s\n' "$matches"
        ;;
esac
