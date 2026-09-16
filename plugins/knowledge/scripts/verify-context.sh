#!/usr/bin/env bash
# Read-only verification: deliberately does not call the mutating context reader.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
if [ -n "${SESSION_CONTEXT_HOME:-}" ]; then
  _context_validate_tree "$SESSION_CONTEXT_HOME" >/dev/null || exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo 'ERROR: context-verify requires Python 3.' >&2
  exit 2
fi
exec python3 -B "$(dirname "$0")/context-verify.py" "$@"
