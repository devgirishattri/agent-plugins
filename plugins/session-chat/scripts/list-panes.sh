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
    # Resolve the current session with stderr preserved: a sandbox denial here
    # (which yields an empty session name) is the ROOT failure and must be
    # classified at its source, not silently discarded and only later inferred
    # from the follow-on list-panes probe.
    if ! tmux_capture_checked list-panes-session CURRENT_SESSION TMUX_ERR \
        display-message -p -t "${TMUX_PANE:-}" '#{session_name}'; then
      echo "ERROR: could not resolve the current tmux session.$(tmux_err_detail "$TMUX_ERR")" >&2
      exit 1
    fi
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
# stderr is preserved and fail-checked: under a sandboxed exec the socket
# connect() is denied ("Operation not permitted") and tmux prints nothing to
# stdout — without this we would emit an empty list and the caller would falsely
# report "no named panes". Surface the denial as a loud error + nonzero exit.
if ! tmux_capture_checked list-panes-enum PANE_LINES TMUX_ERR \
    list-panes "${TARGET_ARGS[@]}" -F '#{@name}|#{pane_id}|#{pane_current_command}|#{session_name}:#{window_index}.#{pane_index}'; then
  echo "ERROR: could not list tmux panes.$(tmux_err_detail "$TMUX_ERR")" >&2
  exit 1
fi

printf '%s\n' "$PANE_LINES" | \
  while IFS='|' read -r name pane_id cmd location; do
    # Skip panes without a name
    if [ -n "$name" ]; then
      printf '%s\t%s\t%s\t%s\n' "$name" "$pane_id" "$cmd" "$location"
    fi
  done
