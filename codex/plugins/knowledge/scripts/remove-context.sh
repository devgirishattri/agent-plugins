#!/usr/bin/env bash
# remove-context.sh — Delete a context snapshot for the current project
# Usage: remove-context.sh <project-name> --confirmed
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

PROJECT_NAME="${1:-}"
CONFIRMATION="${2:-}"

if [ -z "$PROJECT_NAME" ] || [ "$CONFIRMATION" != "--confirmed" ] || [ "$#" -ne 2 ]; then
  echo "ERROR: Usage: remove-context.sh <project-name> --confirmed"
  echo "Refusing to remove context without an explicit confirmation gate."
  echo "Run \$knowledge:context-list to see available snapshots."
  exit 1
fi

validate_label "$PROJECT_NAME" || exit 1

SNAPSHOTS_DIR="$(bootstrap_contexts_dir)" || exit 1
SNAPSHOT="$SNAPSHOTS_DIR/${PROJECT_NAME}.md"
HISTORY_DIR="$SNAPSHOTS_DIR/.history"
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

# Harden the whole store UNDER the writer lock (moved here from the old pre-lock
# get_contexts_dir sweep, which raced concurrent writers' temp/rename).
harden_existing_contexts_dir "$SNAPSHOTS_DIR" >/dev/null || exit 1

current_removed=0
history_removed=0
history_files=()
if _context_path_exists "$SNAPSHOT"; then
  ensure_context_regular_file "$SNAPSHOT" || exit 1
  current_removed=1
fi
if [ -d "$HISTORY_DIR" ]; then
  _context_harden_directory "$HISTORY_DIR" || exit 1
  for history_file in "$HISTORY_DIR/${PROJECT_NAME}."*.md; do
    _context_path_exists "$history_file" || continue
    ensure_context_regular_file "$history_file" || exit 1
    history_files+=("$history_file")
  done
fi

if [ "$current_removed" -eq 0 ] && [ "${#history_files[@]}" -eq 0 ]; then
  echo "ERROR: No current or archived context snapshot found for '$PROJECT_NAME' in this project."
  echo "Available snapshots:"
  list_snapshot_names "$SNAPSHOTS_DIR"
  exit 1
fi

if [ "${#history_files[@]}" -gt 0 ]; then
  # Bash 3.2 treats an empty `"${array[@]}"` expansion as unbound under
  # `set -u`; count-guard the loop so fresh snapshots with no history remain
  # removable.
  for history_file in "${history_files[@]}"; do
    rm -f "$history_file" || {
        _context_store_error "cannot remove history file: $history_file"
        exit 1
    }
    history_removed=$((history_removed + 1))
  done
fi
if [ "$current_removed" -eq 1 ]; then
  rm -f "$SNAPSHOT" || {
    _context_store_error "cannot remove snapshot: $SNAPSHOT"
    exit 1
  }
fi
release_context_store_lock || exit 1
LOCK_HELD=0
trap - EXIT HUP INT TERM
echo "Removed context data for '$PROJECT_NAME': $current_removed current snapshot and $history_removed history file(s)."
