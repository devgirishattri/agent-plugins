#!/usr/bin/env bash
# workspace-hide.sh — session-workspace 'hide' verb (schema v6 with `peers`,
# 0.17.0): moves a shown worker pane out of its orchestrator's window into a
# window of its own in the same tmux session. It is workspace-show.sh in hide
# mode; see that file for the rules.
#
# Usage: workspace-hide.sh NAME [--config PATH]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
exec bash "$HERE/workspace-show.sh" --hide "$@"
