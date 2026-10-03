#!/usr/bin/env bash
# Read-only PR observation; does not merge, comment, retry CI, or change refs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo '{"schema_version":1,"result":"unavailable","error":"python3 unavailable"}'; exit 2; }
exec python3 "$SCRIPT_DIR/pr-status.py" "$@"
