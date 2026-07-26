#!/usr/bin/env bash
# list-sessions.sh - List Claude Code sessions
# Usage: list-sessions.sh [project-path|all]
#   No args or project path: list sessions for that project only
#   "all": list sessions across all projects
# Output: tab-separated lines: NAME\tSESSION_ID\tPROJECT\tSIZE\tLAST_MODIFIED
# Supported platforms: macOS, Linux, Windows (WSL only)
set -uo pipefail

CLAUDE_DIR="$HOME/.claude"
PROJECTS_DIR="$CLAUDE_DIR/projects"
# Default to current working directory if no argument given
FILTER="${1:-$(pwd)}"

if [ ! -d "$PROJECTS_DIR" ]; then
    echo "No sessions found (projects directory does not exist)"
    exit 0
fi

# If a project path is given (not "all"), encode it and restrict to that project dir
SCAN_DIR="$PROJECTS_DIR"
if [ "$FILTER" != "all" ]; then
    # Reject path traversal sequences
    if echo "$FILTER" | grep -qE '(^|/)\.\.(/|$)'; then
        echo "ERROR: Invalid path (path traversal not allowed)"
        exit 1
    fi
    # Encode: /Users/foo/Code/bar -> -Users-foo-Code-bar
    encoded=$(printf '%s' "$FILTER" | sed 's|/|-|g')
    # Verify resolved path stays within PROJECTS_DIR
    target="$PROJECTS_DIR/$encoded"
    resolved=$(cd "$target" 2>/dev/null && pwd) || resolved=""
    if [ -z "$resolved" ] || [ "${resolved#"$PROJECTS_DIR"}" = "$resolved" ]; then
        echo "No sessions found for project: $FILTER"
        exit 0
    fi
    SCAN_DIR="$resolved"
fi

decode_project_path() {
    local encoded="$1"
    # Best-effort decode: strip leading -, replace - with /
    # Note: LOSSY when directory names contain hyphens — the encoding uses "-"
    # as the separator, so "agent-plugins" decodes to "agent/plugins". Only
    # used as a fallback; prefer project_path_from_transcript below.
    echo "$encoded" | sed 's/^-/\//' | sed 's/-/\//g'
}

# The transcript records the real working directory on every line, so read it
# instead of reverse-engineering the directory name. Fixes hyphenated repo
# names displaying as bogus paths (observed 2026-07-27: a repo named
# "agent-plugins" listed as "/Users/.../Code/agent/plugins"). Falls back to the
# lossy decode when a transcript is unreadable or carries no cwd.
project_path_from_transcript() {
    local jsonl_file="$1" encoded="$2" cwd=""
    cwd=$(grep -ao '"cwd":"[^"]*"' "$jsonl_file" 2>/dev/null | head -1 | sed 's/^"cwd":"//; s/"$//')
    if [ -n "$cwd" ]; then
        printf '%s' "$cwd"
    else
        decode_project_path "$encoded"
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

find "$SCAN_DIR" -maxdepth 2 -name '*.jsonl' -type f 2>/dev/null | while read -r jsonl_file; do
    filename=$(basename "$jsonl_file" .jsonl)
    session_id="$filename"

    # Validate UUID format
    if ! echo "$session_id" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
        continue
    fi

    project_dir=$(basename "$(dirname "$jsonl_file")")
    project_path=$(project_path_from_transcript "$jsonl_file" "$project_dir")

    # Extract last custom-title entry (session can be renamed multiple times)
    custom_title=$(grep -a '"type":"custom-title"' "$jsonl_file" 2>/dev/null | tail -1 | sed -n 's/.*"customTitle":"\([^"]*\)".*/\1/p') || true
    if [ -z "$custom_title" ]; then
        custom_title="(untitled)"
    fi

    # Get file size and modification date
    if [[ "$(uname)" == "Darwin" ]]; then
        file_size=$(stat -f '%z' "$jsonl_file" 2>/dev/null || echo "0")
        last_modified=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$jsonl_file" 2>/dev/null || echo "unknown")
    else
        file_size=$(stat -c '%s' "$jsonl_file" 2>/dev/null || echo "0")
        last_modified=$(stat -c '%y' "$jsonl_file" 2>/dev/null | cut -d'.' -f1 || echo "unknown")
    fi

    size_human=$(human_size "$file_size")

    printf '%s\t%s\t%s\t%s\t%s\n' "$custom_title" "$session_id" "$project_path" "$size_human" "$last_modified"
done | sort -t$'\t' -k5 -r
