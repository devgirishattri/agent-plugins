#!/usr/bin/env bash
# get-my-name.sh — Print this pane's @name (empty string if unset)
[ -z "${TMUX:-}" ] && exit 0
tmux display-message -p -t "${TMUX_PANE:-}" '#{@name}' 2>/dev/null || echo ""
