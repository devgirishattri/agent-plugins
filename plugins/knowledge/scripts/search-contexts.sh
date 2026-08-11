#!/usr/bin/env bash
# search-contexts.sh — Search context snapshot CONTENTS across local projects
# Usage: search-contexts.sh <pattern> [--list]
#   pattern: case-insensitive grep pattern matched against snapshot contents
#   --list:  only list matching snapshots (no matching lines)
# Candidate project roots:
#   (a) the current git toplevel (always included)
#   (b) best-effort decoded ~/.claude/projects/* directory names
#       (lossy for paths containing hyphens; non-existent roots are skipped)
# Only roots that exist and contain .tmp/contexts/ (or legacy tmp/contexts/) are searched.
# Each candidate store is validated READ-ONLY before it is read: a store the
# lifecycle commands would reject is skipped with a warning rather than silently
# searched. Validation deliberately does not go through get_contexts_dir --
# that bootstraps and chmods, which this command must never do to another
# project. One bad store skips that store only; the sweep continues.
# Output (default): ROOT\tSNAPSHOT\tLINE\tTEXT (first 3 matching lines per file)
# Output (--list):  ROOT\tSNAPSHOT
# Supported platforms: macOS, Linux
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

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

CLAUDE_DIR="${CLAUDE_HOME:-$HOME/.claude}"
PROJECTS_DIR="$CLAUDE_DIR/projects"

decode_project_path() {
    local encoded="$1"
    # Best-effort decode: strip leading -, replace - with /
    # Note: lossy when directory names contain hyphens
    echo "$encoded" | sed 's/^-/\//' | sed 's/-/\//g'
}

# Candidate roots: current git toplevel (always) + decoded session project dirs
current_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
roots="$current_root"$'\n'
if [ -d "$PROJECTS_DIR" ]; then
    for project_dir in "$PROJECTS_DIR"/*/; do
        [ -d "$project_dir" ] || continue
        decoded=$(decode_project_path "$(basename "$project_dir")")
        roots="${roots}${decoded}"$'\n'
    done
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
        contexts_dir="$root/.tmp/contexts"
        # Legacy fallback: stores created before the .tmp/ migration.
        [ -d "$contexts_dir" ] || contexts_dir="$root/tmp/contexts"
    fi
    [ -d "$contexts_dir" ] || continue
    # Read-only integrity gate. Without this, search was the one reader that
    # ignored the safety contract every other context command enforces, happily
    # returning hits from a store /context-list refuses to open.
    if ! _context_validate_tree "$contexts_dir" 2>/dev/null; then
        printf 'WARNING: skipping unsafe context store (run /knowledge:doctor): %s\n' \
            "$contexts_dir" >&2
        continue
    fi
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
