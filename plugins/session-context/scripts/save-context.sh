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

DEST="$SNAPSHOTS_DIR/${PROJECT_NAME}.md"
HISTORY_DIR="$SNAPSHOTS_DIR/.history"
MAX_HISTORY=10

# Version history: archive the previous snapshot before overwriting it.
# Brand-new names create no history entry.
if [ -f "$DEST" ]; then
  mkdir -p "$HISTORY_DIR"
  ts=$(date -u +%Y%m%d-%H%M%SZ)
  cp "$DEST" "$HISTORY_DIR/${PROJECT_NAME}.${ts}.md"
  echo "Archived previous version to $HISTORY_DIR/${PROJECT_NAME}.${ts}.md"
  # Cap history at MAX_HISTORY versions per name (delete oldest beyond that)
  excess=$(ls -1 "$HISTORY_DIR/${PROJECT_NAME}."*.md 2>/dev/null | sort -r | tail -n +$((MAX_HISTORY + 1)) || true)
  if [ -n "$excess" ]; then
    echo "$excess" | while IFS= read -r old; do
      rm -f "$old"
    done
  fi
fi

cp "$SNAPSHOT_FILE" "$DEST"
echo "Saved context snapshot for '$PROJECT_NAME' at $DEST"
