#!/usr/bin/env bash
# get-my-name.sh — Print this pane's @name (empty string if unset)
set -uo pipefail

source "$(dirname "$0")/lib.sh"
ensure_tmux

tmux_capture_checked get-my-name "Cannot read the current tmux pane name" \
  display-message -p -t "${TMUX_PANE:-}" '#{@name}'
