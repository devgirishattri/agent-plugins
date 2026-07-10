#!/usr/bin/env bash
# delete-session.sh - Permanently delete one confirmed Codex session by UUID.
# Usage: delete-session.sh <full-session-uuid> --confirmed
set -euo pipefail

SESSION_ID="${1:-}"
CONFIRMATION="${2:-}"

if [ "$#" -ne 2 ] || [ "$CONFIRMATION" != "--confirmed" ]; then
    echo "CANCELLED: Explicit final confirmation is required before deletion."
    echo "Only run this helper with --confirmed after the user answers the final confirmation question affirmatively."
    exit 2
fi

if ! printf '%s\n' "$SESSION_ID" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
    echo "ERROR: Invalid session ID format."
    echo "Must be a full UUID (e.g., 019dd49e-8bfc-7952-ac17-bc0aa9ebd8ce)."
    echo "Use \$session-manager:session-search or \$session-manager:session-list to find the full UUID."
    exit 1
fi

if ! command -v codex >/dev/null 2>&1; then
    echo "ERROR: The native codex CLI is not available on PATH."
    exit 127
fi

# Native deletion keeps rollout files, shell snapshots, and state_5.sqlite in sync.
exec codex delete --force "$SESSION_ID"
