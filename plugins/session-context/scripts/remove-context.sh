#!/usr/bin/env bash
# remove-context.sh — Delete a context snapshot for the current project
# Usage: remove-context.sh <project-name>
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

PROJECT_NAME="${1:-}"

if [ -z "$PROJECT_NAME" ]; then
  echo "ERROR: Usage: remove-context.sh <project-name>"
  echo "Run /context-list to see available snapshots."
  exit 1
fi

validate_label "$PROJECT_NAME" || exit 1

SNAPSHOTS_DIR="$(get_contexts_dir)"
SNAPSHOT="$SNAPSHOTS_DIR/${PROJECT_NAME}.md"

if [ ! -f "$SNAPSHOT" ]; then
  echo "ERROR: No context snapshot found for '$PROJECT_NAME' in this project."
  echo "Available snapshots:"
  ls "$SNAPSHOTS_DIR/"*.md 2>/dev/null | xargs -I{} basename {} .md || echo "  (none)"
  exit 1
fi

rm -f "$SNAPSHOT"
echo "Removed context snapshot '$PROJECT_NAME' ($SNAPSHOT)"
