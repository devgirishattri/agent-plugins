#!/usr/bin/env bash
# list-panes.sh — List all named tmux panes across all sessions
# Usage: list-panes.sh
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"
ensure_tmux

# List all panes with @name set, across all tmux sessions
tmux list-panes -a -F '#{@name}\t#{pane_id}\t#{pane_current_command}\t#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null | \
  while IFS=$'\t' read -r name pane_id cmd location; do
    # Skip panes without a name
    if [ -n "$name" ]; then
      printf '%s\t%s\t%s\t%s\n' "$name" "$pane_id" "$cmd" "$location"
    fi
  done
