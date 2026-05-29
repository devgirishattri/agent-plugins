#!/usr/bin/env bash
# list-panes.sh — List named tmux panes in the current session, or all sessions
# Usage: list-panes.sh [all|--all]
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"
ensure_tmux

SCOPE="${1:-current}"

case "$SCOPE" in
  current|"")
    CURRENT_SESSION=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null)
    # -s targets a whole session (all its windows). Without -s, -t is treated as
    # a window spec and only the session's active window would be listed.
    TARGET_ARGS=(-s -t "$CURRENT_SESSION")
    ;;
  all|--all)
    TARGET_ARGS=(-a)
    ;;
  -h|--help)
    echo "Usage: list-panes.sh [all|--all]"
    exit 0
    ;;
  *)
    echo "ERROR: Usage: list-panes.sh [all|--all]" >&2
    exit 1
    ;;
esac

# List panes with @name set.
# tmux does not expand "\t" in format strings, so use a delimiter that pane names
# created by this plugin cannot contain and print real TSV output below.
tmux list-panes "${TARGET_ARGS[@]}" -F '#{@name}|#{pane_id}|#{pane_current_command}|#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null | \
  while IFS='|' read -r name pane_id cmd location; do
    # Skip panes without a name
    if [ -n "$name" ]; then
      printf '%s\t%s\t%s\t%s\n' "$name" "$pane_id" "$cmd" "$location"
    fi
  done
