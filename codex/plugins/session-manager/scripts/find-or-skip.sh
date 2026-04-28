#!/usr/bin/env bash
# find-or-skip.sh - Wrapper for search-sessions.sh that returns empty on no input
# Used by session-delete command to skip search when deleting current session
# Supported platforms: macOS, Linux, Windows (WSL only)
[ -z "$1" ] && exit 0
exec bash "$(dirname "$0")/search-sessions.sh" "$1"
