#!/usr/bin/env bash
# search-contexts.sh — Search context snapshot CONTENTS across local projects
# Usage: search-contexts.sh <pattern> [--list]
#   pattern: case-insensitive grep pattern matched against snapshot contents
#   --list:  only list matching snapshots (no matching lines)
# Candidate project roots:
#   (a) the current git toplevel (always included)
#   (b) the cwd recorded in each ~/.codex/sessions/**/*.jsonl session file
#       (same derivation as the session-manager scripts; missing roots skipped)
# Only roots that exist and contain tmp/contexts/ are searched.
# Output (default): ROOT\tSNAPSHOT\tLINE\tTEXT (first 3 matching lines per file)
# Output (--list):  ROOT\tSNAPSHOT
# Supported platforms: macOS, Linux
set -uo pipefail

LIST_MODE=0
PATTERN=""
for arg in "$@"; do
    case "$arg" in
        --list) LIST_MODE=1 ;;
        *)
            if [ -z "$PATTERN" ]; then
                PATTERN="$arg"
            else
                PATTERN="$PATTERN $arg"
            fi
            ;;
    esac
done

if [ -z "$PATTERN" ]; then
    echo "ERROR: No search pattern provided"
    echo "Usage: /context-search <pattern> [--list]"
    exit 1
fi

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
SESSIONS_DIR="$CODEX_DIR/sessions"

json_field() {
    local file="$1"
    local expr="$2"
    if command -v jq >/dev/null 2>&1; then
        jq -r "$expr // empty" "$file" 2>/dev/null | head -1
    else
        case "$expr" in
            ".payload.cwd") head -1 "$file" | sed -n 's/.*"cwd":"\([^"]*\)".*/\1/p' ;;
            *) return 0 ;;
        esac
    fi
}

# Candidate roots: current git toplevel (always) + cwd of each Codex session
current_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
roots="$current_root"$'\n'
if [ -d "$SESSIONS_DIR" ]; then
    while IFS= read -r jsonl_file; do
        [ -n "$jsonl_file" ] || continue
        cwd=$(json_field "$jsonl_file" '.payload.cwd')
        [ -n "$cwd" ] || continue
        roots="${roots}${cwd}"$'\n'
    done < <(find "$SESSIONS_DIR" -type f -name '*.jsonl' 2>/dev/null)
fi

# SESSION_CONTEXT_HOME overrides the current root's snapshot dir directly
# (used for the loop below); it doesn't affect the other decoded roots since
# they represent other projects entirely.
found=0
while IFS= read -r root; do
    [ -n "$root" ] || continue
    if [ "$root" = "$current_root" ] && [ -n "${SESSION_CONTEXT_HOME:-}" ]; then
        contexts_dir="$SESSION_CONTEXT_HOME"
    else
        contexts_dir="$root/tmp/contexts"
    fi
    [ -d "$contexts_dir" ] || continue
    matches=$(grep -il -- "$PATTERN" "$contexts_dir"/*.md 2>/dev/null) || true
    [ -n "$matches" ] || continue
    while IFS= read -r snapshot_file; do
        [ -f "$snapshot_file" ] || continue
        name=$(basename "$snapshot_file" .md)
        found=1
        if [ "$LIST_MODE" -eq 1 ]; then
            printf '%s\t%s\n' "$root" "$name"
        else
            grep -in -- "$PATTERN" "$snapshot_file" 2>/dev/null | head -3 | while IFS=: read -r lineno text; do
                printf '%s\t%s\t%s\t%s\n' "$root" "$name" "$lineno" "$text"
            done
        fi
    done <<< "$matches"
done < <(printf '%s' "$roots" | sort -u)

if [ "$found" -eq 0 ]; then
    echo "No context snapshots matching '$PATTERN' found across local projects."
fi
