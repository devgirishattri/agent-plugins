#!/usr/bin/env bash
# Optional diagnostic advice. Never invoked by hooks or core lifecycle.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ ! -f "$HERE/jev-adapter.py" ]; then
  printf '%s\n' '{"status":"unavailable","reason_code":"adapter_removed","guide":null}'
  exit 0
fi
exec python3 "$HERE/jev-adapter.py" "$@"
