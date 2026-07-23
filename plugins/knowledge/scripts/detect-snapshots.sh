#!/usr/bin/env bash
# detect-snapshots.sh — SessionStart hook for knowledge's context-store surface
# (absorbed from session-context 0.7.8).
# Surfaces a short, one-time hint when the current project already has context
# snapshots, so a resuming session knows it can /context-load instead of
# re-deriving state. Stays silent (and exit 0) when there is nothing to surface.
# Supported platforms: macOS, Linux
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh" 2>/dev/null || exit 0

SNAP_DIR="$(get_contexts_dir 2>/dev/null)" || exit 0
[ -n "$SNAP_DIR" ] && [ -d "$SNAP_DIR" ] || exit 0

shopt -s nullglob
snaps=("$SNAP_DIR"/*.md)
count=${#snaps[@]}
[ "$count" -eq 0 ] && exit 0

names=""
for f in "${snaps[@]}"; do
  names+="$(basename "$f" .md) "
done
names="${names% }"

echo "knowledge: ${count} context snapshot(s) available for this project: ${names}. Run /context-load <name> to resume prior work, or /context-list for details."
exit 0
