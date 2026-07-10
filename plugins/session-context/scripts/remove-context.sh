#!/usr/bin/env bash
# remove-context.sh — Delete a context snapshot AND its archived history for the
# current project. Destructive: requires an explicit --confirmed capability flag,
# which the /context-remove command passes only AFTER an AskUserQuestion
# default-cancel confirmation. Other names' histories are left intact.
# Usage: remove-context.sh <project-name> --confirmed
set -uo pipefail

source "$(dirname "$0")/lib.sh"

PROJECT_NAME=""
CONFIRMED=0
for arg in "$@"; do
  case "$arg" in
    --confirmed) CONFIRMED=1 ;;
    -*) echo "ERROR: unknown option '$arg'." >&2; exit 1 ;;
    *) [ -z "$PROJECT_NAME" ] && PROJECT_NAME="$arg" ;;
  esac
done

if [ -z "$PROJECT_NAME" ]; then
  echo "ERROR: Usage: remove-context.sh <project-name> --confirmed"
  echo "Run /context-list to see available snapshots."
  exit 1
fi

validate_label "$PROJECT_NAME" || exit 1

SNAPSHOTS_DIR="$(get_contexts_dir)" || exit 1
SNAPSHOT="$SNAPSHOTS_DIR/${PROJECT_NAME}.md"
HISTORY_DIR="$SNAPSHOTS_DIR/.history"

# Collect this name's archived history versions (.history/<name>.<ts>.md). The
# literal dot after the validated (dot-free) name is an unambiguous boundary, so
# other names' histories are never matched.
HIST_FILES=()
if [ -d "$HISTORY_DIR" ]; then
  for h in "$HISTORY_DIR/${PROJECT_NAME}."*.md; do
    [ -e "$h" ] || continue
    HIST_FILES+=("$h")
  done
fi

SNAP_EXISTS=0
[ -f "$SNAPSHOT" ] && SNAP_EXISTS=1

# Error only if NEITHER the snapshot nor any orphaned history exists.
if [ "$SNAP_EXISTS" -eq 0 ] && [ "${#HIST_FILES[@]}" -eq 0 ]; then
  echo "ERROR: No current or archived context snapshot found for '$PROJECT_NAME' in this project."
  echo "Available snapshots:"
  found_any=0
  for s in "$SNAPSHOTS_DIR"/*.md; do
    [ -e "$s" ] || continue
    basename "$s" .md
    found_any=1
  done
  [ "$found_any" -eq 1 ] || echo "  (none)"
  exit 1
fi

# Destructive capability gate — refuse without explicit confirmation.
if [ "$CONFIRMED" != "1" ]; then
  echo "REFUSED: removing '$PROJECT_NAME' deletes the snapshot AND its archived history and cannot be undone." >&2
  echo "  Re-run through /context-remove (which confirms first), or pass --confirmed to the script explicitly." >&2
  exit 2
fi

# Delete the current snapshot (if present) plus every archived history version —
# including ORPHANED history when the current snapshot is already gone.
removed=0
if [ "$SNAP_EXISTS" -eq 1 ] && rm -f "$SNAPSHOT"; then removed=$((removed + 1)); fi
for h in "${HIST_FILES[@]}"; do
  if rm -f "$h"; then removed=$((removed + 1)); fi
done
if [ "$SNAP_EXISTS" -eq 1 ]; then
  echo "Removed context snapshot '$PROJECT_NAME' and its history — ${removed} file(s) deleted."
else
  echo "Removed ${removed} orphaned history file(s) for '$PROJECT_NAME' (no current snapshot)."
fi
