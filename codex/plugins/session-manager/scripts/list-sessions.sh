#!/usr/bin/env bash
# Read-only metadata with native capability detection and legacy fallback.
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required to read Codex session metadata." >&2
    exit 127
}
exec python3 "$SCRIPT_DIR/session-metadata.py" list "$@"
