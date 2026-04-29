#!/usr/bin/env bash
# load-context.sh — Load a context snapshot and print its contents
# Usage: load-context.sh <project-name>
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

PROJECT_NAME="${1:-}"

if [ -z "$PROJECT_NAME" ]; then
  echo "ERROR: Usage: load-context.sh <project-name>"
  echo "Run /context-list to see available snapshots."
  exit 1
fi

validate_label "$PROJECT_NAME" || exit 1

SNAPSHOTS_DIR="${CODEX_HOME:-$HOME/.codex}/context-snapshots"
SNAPSHOT="$SNAPSHOTS_DIR/${PROJECT_NAME}.md"

if [ ! -f "$SNAPSHOT" ]; then
  echo "ERROR: No context snapshot found for '$PROJECT_NAME'."
  echo "Available snapshots:"
  ls "$SNAPSHOTS_DIR/"*.md 2>/dev/null | xargs -I{} basename {} .md || echo "  (none)"
  exit 1
fi

cat "$SNAPSHOT"
