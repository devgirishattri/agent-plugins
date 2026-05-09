#!/usr/bin/env bash
# scheduler-doctor.sh — Inspect session-scheduler setup
# Usage: scheduler-doctor.sh
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

ensure_dirs

echo "session-scheduler plugin: $PLUGIN_ROOT"
echo "scheduler dir: $SCHEDULER_DIR"
echo "tasks dir: $TASKS_DIR"
echo "prompts dir: $PROMPTS_DIR"
echo "pane name: $(current_pane_name)"

if CHAT_ROOT=$(session_chat_root 2>/dev/null); then
  echo "session-chat root: $CHAT_ROOT"
  echo "session-chat version: $(session_chat_version "$CHAT_ROOT")"
else
  echo "session-chat root: missing"
fi

echo "incoming mode: ${SESSION_CHAT_INCOMING_MODE:-notify}"
echo "executor panes should use SESSION_CHAT_INCOMING_MODE=auto or assist to act on assigned dispatches."
