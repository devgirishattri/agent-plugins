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
timezone=$(agent_plugins_timezone) || exit 1

if [ -L "$SNAPSHOT_FILE" ] || [ ! -f "$SNAPSHOT_FILE" ]; then
  echo "ERROR: Snapshot input must be a regular non-symlink file: $SNAPSHOT_FILE"
  exit 1
fi

SNAPSHOTS_DIR="$(bootstrap_contexts_dir)" || exit 1
DEST="$SNAPSHOTS_DIR/${PROJECT_NAME}.md"
HISTORY_DIR="$SNAPSHOTS_DIR/.history"
MAX_HISTORY=10
LOCK_HELD=0

cleanup_lock() {
  if [ "$LOCK_HELD" -eq 1 ] || [ -n "${CONTEXT_STORE_LOCK_DIR:-}" ]; then
    release_context_store_lock >/dev/null 2>&1 || true
    LOCK_HELD=0
  fi
}
handle_signal() {
  cleanup_lock
  trap - EXIT HUP INT TERM
  exit 1
}
trap cleanup_lock EXIT
trap handle_signal HUP INT TERM

acquire_context_store_lock "$SNAPSHOTS_DIR" || exit 1
LOCK_HELD=1

# Harden the whole store UNDER the writer lock. This sweep moved here from the old
# pre-lock get_contexts_dir call: run unlocked, it raced concurrent saves'
# temp/rename and spuriously failed one of several parallel first-time saves.
harden_existing_contexts_dir "$SNAPSHOTS_DIR" >/dev/null || exit 1

# Version history: archive the previous snapshot before overwriting it.
# Brand-new names create no history entry.
if _context_path_exists "$DEST"; then
  ensure_context_regular_file "$DEST" || exit 1
  if [ -L "$HISTORY_DIR" ]; then
    _context_store_error "history directory cannot be a symbolic link: $HISTORY_DIR"
    exit 1
  fi
  if [ ! -d "$HISTORY_DIR" ]; then
    mkdir -m 700 "$HISTORY_DIR" || {
      _context_store_error "cannot create history directory: $HISTORY_DIR"
      exit 1
    }
  fi
  _context_harden_directory "$HISTORY_DIR" || exit 1
  ts=$(TZ="$timezone" date +%Y%m%d-%H%M%S%z)
  while _context_path_exists "$HISTORY_DIR/${PROJECT_NAME}.${ts}.md"; do
    sleep 1
    ts=$(TZ="$timezone" date +%Y%m%d-%H%M%S%z)
  done
  archive_mode=$(context_safe_file_mode "$DEST") || exit 1
  atomic_copy_context_file "$DEST" "$HISTORY_DIR/${PROJECT_NAME}.${ts}.md" "$archive_mode" || exit 1
  echo "Archived previous version to $HISTORY_DIR/${PROJECT_NAME}.${ts}.md"
  # Cap history at MAX_HISTORY versions per name (delete oldest beyond that)
  excess=$(context_history_versions "$PROJECT_NAME" "$HISTORY_DIR" | tail -n +$((MAX_HISTORY + 1)) || true)
  if [ -n "$excess" ]; then
    echo "$excess" | while IFS= read -r old; do
      ensure_context_regular_file "$old" || exit 1
      rm -f "$old" || exit 1
    done || exit 1
  fi
fi

atomic_copy_context_file "$SNAPSHOT_FILE" "$DEST" 600 || exit 1
ensure_context_regular_file "$DEST" || exit 1
release_context_store_lock || exit 1
LOCK_HELD=0
trap - EXIT HUP INT TERM
echo "Saved context snapshot for '$PROJECT_NAME' at $DEST"
