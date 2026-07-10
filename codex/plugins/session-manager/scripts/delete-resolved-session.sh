#!/usr/bin/env bash
# delete-resolved-session.sh - Backwards-compatible, read-only deletion resolver.
# Usage: delete-resolved-session.sh [session-id-or-title]
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Resolution must never delete. The caller must ask for explicit final
# confirmation before invoking delete-session.sh with --confirmed.
exec bash "$SCRIPT_DIR/prepare-delete.sh" "${1:-}"
