#!/usr/bin/env bash
# search-sessions.sh - Search Codex sessions by title, ID prefix, or project path.
# Usage: search-sessions.sh <query> [--archived|--archived-only]
set -uo pipefail

QUERY="${1:-}"
STATE="${2:-}"
case "$STATE" in
    ""|--archived|--archived-only) ;;
    *)
        echo "ERROR: Unknown option: $STATE"
        echo "Usage: search-sessions.sh <query> [--archived|--archived-only]"
        exit 1
        ;;
esac
if [ -z "$QUERY" ]; then
    echo "ERROR: No search query provided"
    echo "Usage: \$session-manager:session-search <name-or-id-or-project>"
    exit 1
fi

QUERY=$(printf '%s' "$QUERY" | tr -d '\0-\37\177')
if [ -z "$QUERY" ]; then
    echo "ERROR: Query contains only invalid characters"
    exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
QUERY_LOWER=$(printf '%s' "$QUERY" | tr '[:upper:]' '[:lower:]')

sessions=$(bash "$SCRIPT_DIR/list-sessions.sh" all ${STATE:+"$STATE"}) || exit $?
printf '%s\n' "$sessions" | while IFS=$'\t' read -r name session_id project size last_modified; do
    haystack=$(printf '%s\n%s\n%s' "$name" "$session_id" "$project" | tr '[:upper:]' '[:lower:]')
    if printf '%s' "$haystack" | grep -qF "$QUERY_LOWER"; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$session_id" "$project" "$size" "$last_modified"
    fi
done
