#!/usr/bin/env bash
# Current-project, read-only search across knowledge stores.
set -uo pipefail
if ! command -v python3 >/dev/null 2>&1; then
  echo 'ERROR: knowledge find requires Python 3.' >&2
  exit 2
fi
exec python3 -B "$(dirname "$0")/knowledge-find.py" "$@"
