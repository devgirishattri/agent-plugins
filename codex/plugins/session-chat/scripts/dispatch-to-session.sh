#!/usr/bin/env bash
# dispatch-to-session.sh — Send a task to an existing named session via file-based messaging
# Usage: dispatch-to-session.sh [--priority high|normal] [--ttl MINUTES] [--reply-to ID] <target-name> <prompt-file>
#   --priority high  queued recovery surfaces this before normal messages
#   --ttl MINUTES    if still queued after this window, drop instead of surfacing
# Supported platforms: macOS, Linux

source "$(dirname "$0")/lib.sh"

REPLY_TO=""
REPLY_TO_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --priority)
      shift
      export SESSION_CHAT_PRIORITY="${1:-normal}"
      ;;
    --ttl)
      shift
      _ttl_min=$(normalize_positive_int "${1:-0}" 0)
      export SESSION_CHAT_TTL_MS=$((_ttl_min * 60000))
      ;;
    --reply-to)
      shift
      REPLY_TO="${1:-}"
      REPLY_TO_SET=1
      ;;
    *) break ;;
  esac
  shift
done

TARGET_NAME="${1:-}"
PROMPT_FILE="${2:-}"

if [ -z "$TARGET_NAME" ] || [ -z "$PROMPT_FILE" ]; then
  echo "ERROR: Usage: dispatch-to-session.sh [--reply-to ID] <target-name> <prompt-file>"
  exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: Prompt file not found: $PROMPT_FILE"
  exit 1
fi

# Validate correlation before tmux so malformed IDs keep their existing error.
if [ "$REPLY_TO_SET" = "1" ]; then
  validate_reply_id "$REPLY_TO" || exit 1
fi

ensure_tmux

# Remember an eligible source before reading it. Cleanup checks the identity
# and exact file digest again after reading and after durable delivery. This
# is not atomic protection against concurrent changes by the same user.
DRAFT_IDENT=""
DRAFT_SUM=""
if [ "${SESSION_CHAT_KEEP_DRAFTS:-0}" != "1" ] && DRAFT_IDENT=$(own_draft_identity "$PROMPT_FILE"); then
  DRAFT_SUM=$(file_sha256 "$PROMPT_FILE") || DRAFT_SUM=""
else
  DRAFT_IDENT=""
fi

# Never dispatch partial output from a failed read or delete its complete source.
if ! PROMPT_TEXT=$(cat "$PROMPT_FILE"); then
  echo "ERROR: could not read prompt file: $PROMPT_FILE (nothing was sent; the file is kept)" >&2
  exit 1
fi
if [ -n "$DRAFT_IDENT" ]; then
  if [ "$(own_draft_identity "$PROMPT_FILE" 2>/dev/null)" != "$DRAFT_IDENT" ] \
     || [ -z "$DRAFT_SUM" ] || [ "$(file_sha256 "$PROMPT_FILE")" != "$DRAFT_SUM" ]; then
    DRAFT_IDENT=""
  fi
fi
if [ "$REPLY_TO_SET" = "1" ]; then
  PROMPT_TEXT=$(correlate_reply "$REPLY_TO" "$PROMPT_TEXT") || exit 1
fi

dispatch_message "$TARGET_NAME" "$PROMPT_TEXT"
rc=$?
case "$rc" in
  0) echo "Dispatched task to '$TARGET_NAME'" ;;
  3) echo "Queued dispatch to '$TARGET_NAME' — recipient was busy; it will arrive on their next turn." ;;
  *) exit 1 ;;
esac

# Delivered and queued outcomes own a separate durable payload. Cleanup cannot
# change the successful transport result; failure/uncertainty keeps the source.
if [ -n "$DRAFT_IDENT" ]; then
  consume_own_draft "$PROMPT_FILE" "$DRAFT_IDENT" "$DRAFT_SUM"
fi
