#!/usr/bin/env bash
# incoming-mode.sh — Show or generate export for SESSION_CHAT_INCOMING_MODE.
# Usage:
#   incoming-mode.sh                # report current mode + explain modes
#   incoming-mode.sh <auto|assist|notify|off>  # print export line for shell eval
# A child script CANNOT mutate the parent shell's env. We print an export line
# the user can `eval` (or the agent can suggest the user paste).
set -uo pipefail

MODE_ARG="${1:-}"
CURRENT="${SESSION_CHAT_INCOMING_MODE:-notify}"

print_modes() {
  cat <<'EOF'
Modes:
  auto    — recipient may read dispatch files and act without confirming.
  assist  — recipient summarizes the incoming message and asks the local user.
  notify  — (default) recipient is told a message arrived but is FORBIDDEN
            from reading the dispatch file. Orchestration silently no-ops.
  off     — incoming-message hook does nothing.
EOF
}

if [ -z "$MODE_ARG" ]; then
  echo "Current SESSION_CHAT_INCOMING_MODE: ${CURRENT}"
  echo
  print_modes
  echo
  echo "To change for the current shell:  eval \"\$(incoming-mode.sh <mode>)\""
  echo "To persist across sessions, export it from your shell rc."
  exit 0
fi

case "$MODE_ARG" in
  auto|assist|notify|off)
    # Print export line for `eval`. Also print a brief comment to stderr so
    # the agent can show context without polluting the eval'd output.
    echo "export SESSION_CHAT_INCOMING_MODE=${MODE_ARG}"
    echo "# session-chat incoming mode set to '${MODE_ARG}' (eval this line in your shell)" >&2
    exit 0
    ;;
  *)
    echo "ERROR: invalid mode '${MODE_ARG}'. Expected: auto, assist, notify, off." >&2
    print_modes >&2
    exit 1
    ;;
esac
