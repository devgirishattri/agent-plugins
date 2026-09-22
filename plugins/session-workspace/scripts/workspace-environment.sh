#!/usr/bin/env bash
# Explicit environment selector; delegates to the existing session lifecycle.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$HERE/workspace-environment.py" "$@"
