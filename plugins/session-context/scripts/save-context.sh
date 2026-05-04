#!/usr/bin/env bash
# save-context.sh — Save a context snapshot for the current project
# Usage: save-context.sh <project-name> <snapshot-file>
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

PROJECT_NAME="${1:-}"
SNAPSHOT_FILE="${2:-}"

if [ -z "$PROJECT_NAME" ] || [ -z "$SNAPSHOT_FILE" ]; then
  echo "ERROR: Usage: save-context.sh <project-name> <snapshot-file>"
  exit 1
fi

validate_label "$PROJECT_NAME" || exit 1

if [ ! -f "$SNAPSHOT_FILE" ]; then
  echo "ERROR: Snapshot file not found: $SNAPSHOT_FILE"
  exit 1
fi

SNAPSHOTS_DIR="$(get_contexts_dir)"
mkdir -p "$SNAPSHOTS_DIR"

cp "$SNAPSHOT_FILE" "$SNAPSHOTS_DIR/${PROJECT_NAME}.md"
echo "Saved context snapshot for '$PROJECT_NAME' at $SNAPSHOTS_DIR/${PROJECT_NAME}.md"
