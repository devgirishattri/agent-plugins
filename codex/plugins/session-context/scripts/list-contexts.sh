#!/usr/bin/env bash
# list-contexts.sh — List available context snapshots for the current project
# Usage: list-contexts.sh
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

SNAPSHOTS_DIR="$(get_contexts_dir)"
HISTORY_DIR="$SNAPSHOTS_DIR/.history"

if [ ! -d "$SNAPSHOTS_DIR" ] || [ -z "$(ls "$SNAPSHOTS_DIR"/*.md 2>/dev/null)" ]; then
  echo "No context snapshots found for this project. Use /context-generate to create one."
  exit 0
fi

for snapshot in "$SNAPSHOTS_DIR"/*.md; do
  [ -f "$snapshot" ] || continue
  name=$(basename "$snapshot" .md)
  size=$(wc -l < "$snapshot" | tr -d ' ')
  if [ "$(uname)" = "Darwin" ]; then
    modified=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$snapshot" 2>/dev/null)
  else
    modified=$(stat -c '%y' "$snapshot" 2>/dev/null | cut -d'.' -f1)
  fi
  versions=$(ls -1 "$HISTORY_DIR/${name}."*.md 2>/dev/null | wc -l | tr -d ' ')
  printf '%s\t%s lines\t%s\t%s versions\n' "$name" "$size" "$modified" "$versions"
done
