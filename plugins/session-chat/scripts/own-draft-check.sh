#!/usr/bin/env bash
# own-draft-check.sh — internal helper for other plugins (the scheduler runs it
# as a SUBPROCESS; it is not an agent-callable command and has no skill).
# It reuses own_draft_identity / consume_own_draft so the "own private draft"
# decision stays in one place.
#
# Usage:
#   own-draft-check.sh [--max-bytes N] <file>
#       Prints exactly one line, OK<TAB><dev:inode><TAB><sha256><TAB><size>, and
#       exits 0 only when <file> is this pane's own eligible strict-v1 draft
#       (regular, owner-owned, single-link, non-symlink, inside the own drafts
#       directory, valid draft name). Otherwise prints a reason on stderr and
#       exits non-zero with nothing on stdout. With --max-bytes N the size is
#       checked BEFORE any content is read or hashed: a larger file exits 3
#       and is never hashed, and the digest reads at most N+1 bytes. A file
#       whose size changes while it is being hashed is refused with exit 4: it
#       WAS read, so callers must not report it as unread.
#   own-draft-check.sh --consume <file> <dev:inode> <sha256>
#       Removes <file> only when it is still that same eligible own draft with
#       the same SHA-256 (see consume_own_draft). Prints one status line and
#       exits 0 in every case: a kept draft never fails the caller.
#       SESSION_CHAT_KEEP_DRAFTS=1 keeps the draft.
# The checks are sequential, not atomic (same limit as dispatch-to-session.sh).
set -uo pipefail

source "$(dirname "$0")/lib.sh"

if [ "${1:-}" = "--consume" ]; then
  f="${2:-}"; ident="${3:-}"; sum="${4:-}"
  [ "$#" -eq 4 ] && [ -n "$f" ] || { echo "ERROR: usage: own-draft-check.sh --consume <file> <dev:inode> <sha256>" >&2; exit 2; }
  if [ "${SESSION_CHAT_KEEP_DRAFTS:-0}" = "1" ]; then
    echo "NOTE: kept draft (SESSION_CHAT_KEEP_DRAFTS=1): $f"
    exit 0
  fi
  [[ "$ident" =~ ^[0-9]+:[0-9]+$ ]] && [[ "$sum" =~ ^[a-f0-9]{64}$ ]] \
    || { echo "NOTE: kept draft (no valid identity recorded): $f"; exit 0; }
  consume_own_draft "$f" "$ident" "$sum"
  exit 0
fi

max=""
if [ "${1:-}" = "--max-bytes" ]; then
  max="${2:-}"
  [[ "$max" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --max-bytes requires a positive integer." >&2; exit 2; }
  shift 2
fi
if [ "$#" -ne 1 ] || [ -z "${1:-}" ]; then
  echo "ERROR: usage: own-draft-check.sh [--max-bytes N] <file>" >&2
  exit 2
fi
f="$1"
if ! ident=$(own_draft_identity "$f"); then
  echo "ERROR: not an eligible own draft of this pane (must be a private regular, single-link, non-symlink file with a valid draft name inside this pane's own drafts directory): $f" >&2
  exit 1
fi
_sha256_stdin() {
  local out
  if command -v shasum >/dev/null 2>&1; then
    out=$(shasum -a 256) || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum) || return 1
  else
    return 1
  fi
  printf '%s\n' "${out%% *}"
}
_draft_size() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null; }
size=$(_draft_size "$f")
if ! [[ "$size" =~ ^[0-9]+$ ]]; then
  echo "ERROR: could not read the draft size: $f" >&2
  exit 1
fi
if [ -n "$max" ] && [ "$size" -gt "$max" ]; then
  echo "ERROR: the draft is $size bytes; the limit is $max. It was not hashed or read: $f" >&2
  exit 3
fi
if [ -n "$max" ]; then
  # Bounded digest: never reads more than max+1 bytes even if the file grows.
  sum=$(head -c "$((max + 1))" < "$f" 2>/dev/null | _sha256_stdin) || sum=""
else
  sum=$(file_sha256 "$f") || sum=""
fi
if ! [[ "$sum" =~ ^[a-f0-9]{64}$ ]]; then
  echo "ERROR: could not hash the draft: $f" >&2
  exit 1
fi
if [ -n "$max" ] && [ "$(_draft_size "$f")" != "$size" ]; then
  echo "ERROR: the draft changed size while it was checked (was $size bytes); not accepted: $f" >&2
  exit 4
fi
printf 'OK\t%s\t%s\t%s\n' "$ident" "$sum" "$size"
