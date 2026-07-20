#!/usr/bin/env bash
# diff-context.sh — Compare a context snapshot against its archived history versions
# Usage: diff-context.sh <project-name>              # diff newest history version vs current
#        diff-context.sh <project-name> --versions   # list available history timestamps
#        diff-context.sh <project-name> <timestamp>  # diff that version vs current
# New timestamps use the configured timezone's numeric offset
# (YYYYMMDD-HHMMSS+HHMM). Legacy UTC timestamps remain readable.
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

PROJECT_NAME="${1:-}"
MODE="${2:-}"

if [ -z "$PROJECT_NAME" ]; then
  echo "ERROR: Usage: diff-context.sh <project-name> [--versions | <timestamp>]"
  echo "Run /context-list to see available snapshots."
  exit 1
fi

validate_label "$PROJECT_NAME" || exit 1

SNAPSHOTS_DIR="$(get_contexts_dir)" || exit 1
SNAPSHOT="$SNAPSHOTS_DIR/${PROJECT_NAME}.md"
HISTORY_DIR="$SNAPSHOTS_DIR/.history"

if [ ! -f "$SNAPSHOT" ]; then
  echo "ERROR: No context snapshot found for '$PROJECT_NAME' in this project."
  echo "Run /context-list to see available snapshots."
  exit 1
fi

versions=$(ls -1 "$HISTORY_DIR/${PROJECT_NAME}."*.md 2>/dev/null | sort -r || true)

if [ -z "$versions" ]; then
  echo "No history versions exist for '$PROJECT_NAME' yet."
  echo "History is created the first time /context-generate overwrites an existing snapshot."
  exit 0
fi

if [ "$MODE" = "--versions" ]; then
  echo "History versions for '$PROJECT_NAME' (newest first):"
  echo "$versions" | while IFS= read -r f; do
    base=$(basename "$f" .md)
    echo "  ${base#"${PROJECT_NAME}".}"
  done
  exit 0
fi

if [ -n "$MODE" ]; then
  if ! [[ "$MODE" =~ ^[0-9]{8}-[0-9]{6}([+-][0-9]{4}|Z)$ ]]; then
    echo "ERROR: Invalid timestamp '$MODE'. Expected YYYYMMDD-HHMMSS+HHMM (or legacy UTC YYYYMMDD-HHMMSSZ)."
    echo "Run: diff-context.sh $PROJECT_NAME --versions to list available timestamps."
    exit 1
  fi
  OLD="$HISTORY_DIR/${PROJECT_NAME}.${MODE}.md"
  if [ ! -f "$OLD" ]; then
    echo "ERROR: No history version '$MODE' for '$PROJECT_NAME'."
    echo "Run: diff-context.sh $PROJECT_NAME --versions to list available timestamps."
    exit 1
  fi
else
  OLD=$(echo "$versions" | head -1)
fi

echo "Diff: $(basename "$OLD") -> ${PROJECT_NAME}.md (current)"
if diff -u "$OLD" "$SNAPSHOT"; then
  echo "(no differences)"
fi
exit 0
