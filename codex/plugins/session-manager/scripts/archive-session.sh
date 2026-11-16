#!/usr/bin/env bash
# archive-session.sh - Archive or unarchive one Codex session by full UUID.
# Usage: archive-session.sh archive|unarchive <full-session-uuid>
# Both are reversible: the native CLI moves the session between sessions/ and
# archived_sessions/ and keeps state_5.sqlite in sync. Never pass a name or a
# partial ID; resolve it with prepare-archive.sh first.
set -euo pipefail

ACTION="${1:-}"
SESSION_ID="${2:-}"

if [ "$#" -ne 2 ] || { [ "$ACTION" != "archive" ] && [ "$ACTION" != "unarchive" ]; }; then
    echo "Usage: archive-session.sh archive|unarchive <full-session-uuid>"
    exit 2
fi

if ! printf '%s\n' "$SESSION_ID" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
    echo "ERROR: Invalid session ID format."
    echo "Must be a full UUID (e.g., 019dd49e-8bfc-7952-ac17-bc0aa9ebd8ce)."
    echo "Resolve the target with prepare-archive.sh $ACTION <name-or-id> first."
    exit 1
fi

if ! command -v codex >/dev/null 2>&1; then
    echo "ERROR: The native codex CLI is not available on PATH."
    exit 127
fi

if codex "$ACTION" "$SESSION_ID"; then
    exit 0
else
    status=$?
    if [ "$ACTION" = "archive" ]; then
        state="active"
    else
        state="archived"
    fi
    echo "ERROR: Native $ACTION failed for $SESSION_ID (exit $status). It must name an $state session." >&2
    exit "$status"
fi
