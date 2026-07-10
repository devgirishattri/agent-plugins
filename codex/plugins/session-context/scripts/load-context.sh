#!/usr/bin/env bash
# load-context.sh — Load a context snapshot and print its contents
# Usage: load-context.sh <project-name>
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

PROJECT_NAME="${1:-}"

if [ -z "$PROJECT_NAME" ]; then
  echo "ERROR: Usage: load-context.sh <project-name>"
  echo "Run \$session-context:context-list to see available snapshots."
  exit 1
fi

validate_label "$PROJECT_NAME" || exit 1

SNAPSHOTS_DIR="$(get_contexts_dir)" || exit 1
SNAPSHOT="$SNAPSHOTS_DIR/${PROJECT_NAME}.md"

if ! _context_path_exists "$SNAPSHOT"; then
  echo "ERROR: No context snapshot found for '$PROJECT_NAME' in this project."
  echo "Available snapshots:"
  list_snapshot_names "$SNAPSHOTS_DIR"
  exit 1
fi

ensure_context_regular_file "$SNAPSHOT" || exit 1
cat "$SNAPSHOT"

# Staleness warning: flag snapshots older than the threshold (days).
# Override with SESSION_CONTEXT_STALE_DAYS.
STALE_DAYS="${SESSION_CONTEXT_STALE_DAYS:-7}"
mtime=$(stat -f %m "$SNAPSHOT" 2>/dev/null || stat -c %Y "$SNAPSHOT" 2>/dev/null || echo "")
if [ -n "$mtime" ]; then
  now=$(date +%s)
  age_days=$(( (now - mtime) / 86400 ))
  if [ "$age_days" -ge "$STALE_DAYS" ]; then
    echo ""
    echo "WARNING: Snapshot '$PROJECT_NAME' is ${age_days} day(s) old (stale threshold: ${STALE_DAYS} days). It may no longer reflect the project — consider regenerating it with \$session-context:context-generate ${PROJECT_NAME}."
  fi
fi
