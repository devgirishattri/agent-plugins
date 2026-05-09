#!/usr/bin/env bash
# incoming-mode.sh — Show or explain SESSION_CHAT_INCOMING_MODE
# Usage: incoming-mode.sh [notify|assist|auto|off]
# Supported platforms: macOS, Linux
set -uo pipefail

MODE="${1:-}"
CURRENT="${SESSION_CHAT_INCOMING_MODE:-notify}"

print_modes() {
  cat <<'EOF'
Modes:
  notify - Default. Report incoming messages but do not read dispatch files or act automatically.
  assist - Report incoming dispatches and ask the local user before reading files or acting.
  auto   - Treat trusted dispatch files as user-provided content and allow normal task handling.
  off    - Ignore session-chat incoming hooks.
EOF
}

if [ -z "$MODE" ]; then
  echo "SESSION_CHAT_INCOMING_MODE=${CURRENT}"
  print_modes
  exit 0
fi

case "$MODE" in
  notify|assist|auto|off)
    echo "export SESSION_CHAT_INCOMING_MODE=${MODE}"
    echo "Run that in the shell that starts Codex, then restart or reload the session. This script cannot mutate the parent Codex environment."
    ;;
  *)
    echo "ERROR: Usage: incoming-mode.sh [notify|assist|auto|off]" >&2
    exit 1
    ;;
esac
