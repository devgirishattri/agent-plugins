#!/usr/bin/env bash
# list-contexts.sh — List context snapshots for the current project
# Usage: list-contexts.sh
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

SNAPSHOTS_DIR="$(get_contexts_dir)"

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
  printf '%s\t%s lines\t%s\n' "$name" "$size" "$modified"
done
