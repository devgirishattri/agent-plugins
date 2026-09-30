#!/usr/bin/env bash
# remove-context.sh — Preview or delete a context snapshot AND its archived history.
# Destructive runs require an explicit --confirmed capability flag after a
# default-cancel confirmation. Other names' histories are left intact.
# Usage: remove-context.sh <project-name> --dry-run
#        remove-context.sh <project-name> --confirmed
set -uo pipefail

source "$(dirname "$0")/lib.sh"

PROJECT_NAME=""
CONFIRMED=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --confirmed) CONFIRMED=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -*) echo "ERROR: unknown option '$arg'." >&2; exit 1 ;;
    *)
      # Reject extra operands at the destructive capability boundary.
      if [ -z "$PROJECT_NAME" ]; then
        PROJECT_NAME="$arg"
      else
        echo "ERROR: unexpected argument '$arg'." >&2
        exit 1
      fi
      ;;
  esac
done

if [ -z "$PROJECT_NAME" ] || { [ "$CONFIRMED" -eq 1 ] && [ "$DRY_RUN" -eq 1 ]; }; then
  echo "ERROR: Usage: remove-context.sh <project-name> (--dry-run | --confirmed)"
  echo "List available snapshots with the context-list command."
  exit 1
fi

validate_context_name "$PROJECT_NAME" || exit 1

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

# Take the writer lock for a consistent cooperative read, but skip chmod-based
# hardening in dry-run: snapshot/history content and permissions must not change.
# Bootstrap and lock bookkeeping retain the existing store coordination contract.
if [ "$DRY_RUN" -eq 1 ]; then
  _context_validate_tree "$SNAPSHOTS_DIR" || exit 1
else
  harden_existing_contexts_dir "$SNAPSHOTS_DIR" >/dev/null || exit 1
fi

# Both modes consume this one collection. The literal dot after the validated
# (dot-free) name prevents matching another name, including prefix neighbours.
collect_context_files() {
  local path rc
  HIST_FILES=()
  SNAP_EXISTS=0
  for path in "$SNAPSHOT" "$HISTORY_DIR/${PROJECT_NAME}."*.md; do
    _context_path_exists "$path" || continue
    if [ -L "$path" ]; then
      _context_store_error "symbolic-link files are not allowed: $path"
      return 1
    fi
    if [ ! -f "$path" ]; then
      _context_store_error "expected a regular file: $path"
      return 1
    fi
    _context_require_owner "$path"
    rc=$?
    [ "$rc" -eq 2 ] && continue
    [ "$rc" -eq 0 ] || return 1
    if [ "$path" = "$SNAPSHOT" ]; then
      SNAP_EXISTS=1
    else
      HIST_FILES+=("$path")
    fi
  done
}
collect_context_files || exit 1

if [ "$SNAP_EXISTS" -eq 0 ] && [ "${#HIST_FILES[@]}" -eq 0 ]; then
  echo "ERROR: No current or archived context snapshot found for '$PROJECT_NAME' in this project."
  echo "Available snapshots:"
  # The generic list_snapshot_names helper chmods files; this locked tree is
  # already validated, so enumerate names without mutating them in either mode.
  found_any=0
  for s in "$SNAPSHOTS_DIR"/*.md; do
    [ -e "$s" ] || continue
    basename "$s" .md
    found_any=1
  done
  [ "$found_any" -eq 1 ] || echo "  (none)"
  exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
  [ "$SNAP_EXISTS" -eq 0 ] || printf '%s\n' "$SNAPSHOT"
  # Bash 3.2 under set -u cannot expand a never-populated array.
  if [ "${#HIST_FILES[@]}" -gt 0 ]; then
    printf '%s\n' "${HIST_FILES[@]}"
  fi
  if [ "$SNAP_EXISTS" -eq 0 ]; then
    echo "Orphaned history for '$PROJECT_NAME' (no current snapshot)."
  fi
  echo "Would delete $((SNAP_EXISTS + ${#HIST_FILES[@]})) file(s)."
  release_context_store_lock || exit 1
  LOCK_HELD=0
  trap - EXIT HUP INT TERM
  exit 0
fi

if [ "$CONFIRMED" -ne 1 ]; then
  echo "REFUSED: removing '$PROJECT_NAME' deletes the snapshot AND its archived history and cannot be undone." >&2
  echo "  Re-run through the context-remove command (which confirms first), or pass --confirmed to the script explicitly." >&2
  exit 2
fi

removed=0
if [ "$SNAP_EXISTS" -eq 1 ]; then
  rm -f "$SNAPSHOT" || { _context_store_error "cannot remove snapshot: $SNAPSHOT"; exit 1; }
  removed=$((removed + 1))
fi
if [ "${#HIST_FILES[@]}" -gt 0 ]; then
  for h in "${HIST_FILES[@]}"; do
    rm -f "$h" || { _context_store_error "cannot remove history file: $h"; exit 1; }
    removed=$((removed + 1))
  done
fi

release_context_store_lock || exit 1
LOCK_HELD=0
trap - EXIT HUP INT TERM

if [ "$SNAP_EXISTS" -eq 1 ]; then
  echo "Removed context snapshot '$PROJECT_NAME' and its history — ${removed} file(s) deleted."
else
  echo "Removed ${removed} orphaned history file(s) for '$PROJECT_NAME' (no current snapshot)."
fi
