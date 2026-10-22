#!/usr/bin/env bash
# Thin dispatcher for the session-walkthrough helper.
#
#   bash ".../scripts/walkthrough.sh" validate|render|scope ...
#
# It runs walkthrough.py with python3 and passes every argument through
# unchanged. It exports nothing and derives no environment: the tunables
# SESSION_WALKTHROUGH_OUTPUT_ROOT, SESSION_WALKTHROUGH_FINGERPRINT_MAX_BYTES
# and SESSION_WALKTHROUGH_LOCK_TIMEOUT_SECS are read by the helper itself.
# Exit codes come from walkthrough.py: 0 ok, 1 invalid, 2 unusable.
set -u

if ! command -v python3 >/dev/null 2>&1; then
	echo "ERROR: python3 is required" >&2
	exit 2
fi

HERE=$(cd "$(dirname "$0")" && pwd)
exec python3 -B "$HERE/walkthrough.py" "$@"
