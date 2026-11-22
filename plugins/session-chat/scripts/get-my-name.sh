#!/usr/bin/env bash
# get-my-name.sh — Print this pane's @name (empty string if unset). Read-only.
# The name comes from the tmux pane that owns this process (see
# resolve_pane_actor in lib.sh). A genuinely-unnamed pane prints nothing and
# exits 0. A pane that cannot be verified, or a SESSION_CHAT_PANE_NAME that
# disagrees with the owning pane, prints a diagnostic to stderr and exits
# nonzero. Never collapse a failure into a silent empty-name success — the
# caller (/whoami) would otherwise report "No name set" for a pane that is named.
# Only when tmux itself cannot be reached (e.g. a sandboxed exec blocking the
# socket) is a valid SESSION_CHAT_PANE_NAME printed instead; this display-only
# fallback is never used by a helper that writes.
# A standalone caller that claims no pane identity (no tmux, no inherited
# name) has nothing to print.
[ -z "${TMUX:-}${SESSION_CHAT_PANE_NAME:-}" ] && exit 0

source "$(dirname "$0")/lib.sh"

name=$(resolve_pane_actor --read-only) || exit 1
printf '%s' "$name"
