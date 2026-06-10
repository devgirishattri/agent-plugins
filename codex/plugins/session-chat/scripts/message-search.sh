#!/usr/bin/env bash
# message-search.sh — Search archived inter-pane messages and dispatch bodies.
# Archive rows cover every sent message and every surfaced incoming message
# (200-char excerpts); dispatch .md files are also grepped for full bodies.
# Usage: message-search.sh <pattern> [--days N] [--peer NAME]
#   --days N     look-back window (default 7)
#   --peer NAME  only rows to/from that pane name
set -uo pipefail

source "$(dirname "$0")/lib.sh"

PATTERN=""
DAYS=7
PEER_FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --days)
      shift
      DAYS=$(normalize_positive_int "${1:-7}" 7)
      ;;
    --peer)
      shift
      PEER_FILTER="${1:-}"
      ;;
    -h|--help)
      echo "Usage: message-search.sh <pattern> [--days N] [--peer NAME]"
      exit 0
      ;;
    -*)
      echo "ERROR: Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [ -z "$PATTERN" ]; then PATTERN="$1"; else PATTERN="$PATTERN $1"; fi
      ;;
  esac
  shift
done

if [ -z "$PATTERN" ]; then
  echo "ERROR: No search pattern given." >&2
  echo "Usage: message-search.sh <pattern> [--days N] [--peer NAME]" >&2
  exit 1
fi

epoch_to_local() {
  local secs="$1"
  # BSD date uses -r <epoch>; GNU date uses -d @<epoch>.
  date -r "$secs" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$secs" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$secs"
}

ARCHIVE_DIR="$MESSAGES_DIR/archive"
FOUND=0

# 1) Archive rows (short messages + dispatch notifications)
if [ -d "$ARCHIVE_DIR" ]; then
  while IFS=$'\t' read -r ts direction peer type id excerpt; do
    [ -n "$ts" ] || continue
    is_nonnegative_int "$ts" || continue
    [ -n "$PEER_FILTER" ] && [ "$peer" != "$PEER_FILTER" ] && continue
    if [ "$FOUND" -eq 0 ]; then
      printf 'WHEN\tDIR\tPEER\tTYPE\tID\tEXCERPT\n'
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(epoch_to_local $((ts / 1000)))" "$direction" "$peer" "$type" "$id" "$excerpt"
    FOUND=$((FOUND + 1))
  done < <(find "$ARCHIVE_DIR" -name '*.tsv' -type f -mtime -"$DAYS" -print0 2>/dev/null \
            | xargs -0 grep -ih -- "$PATTERN" 2>/dev/null | sort -n)
fi

# 2) Full dispatch bodies (trusted message files)
MATCHED_FILES=$(find "$MESSAGES_DIR" -maxdepth 1 -name '*.md' -type f -mtime -"$DAYS" -print0 2>/dev/null \
                 | xargs -0 grep -il -- "$PATTERN" 2>/dev/null || true)
if [ -n "$MATCHED_FILES" ]; then
  echo "—"
  echo "Dispatch files with matching bodies:"
  printf '%s\n' "$MATCHED_FILES" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s\n' "$f"
    grep -in -- "$PATTERN" "$f" 2>/dev/null | head -3 | sed 's/^/  /'
  done
fi

if [ "$FOUND" -eq 0 ] && [ -z "$MATCHED_FILES" ]; then
  echo "No matches for \"$PATTERN\" in the last ${DAYS} day(s). The archive starts recording with the first send/receive after this upgrade."
fi
exit 0
