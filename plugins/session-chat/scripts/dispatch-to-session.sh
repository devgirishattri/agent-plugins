#!/usr/bin/env bash
# dispatch-to-session.sh — Send a task to an existing named session via file-based messaging
# Usage: dispatch-to-session.sh [--priority high|normal] [--ttl MINUTES] [--reply-to ID] [--task TASK_ID] <target-name> <prompt-file>
#   --priority high  queued recovery surfaces this before normal messages
#   --ttl MINUTES    if still queued after this window, drop instead of surfacing
#   --reply-to ID    prepend a single [re:ID] correlation token (8-16 hex) to the
#                    task body; also surfaced into the notification so a long
#                    (dispatched) reply correlates on the original sender's side
#   --task TASK_ID   put a [task:TASK_ID] token after it (letters, digits, _ and -);
#                    /check-replies --task TASK_ID lists everything tagged with it.
#                    Both tokens form a LEADING envelope at the very top of the body.
# Supported platforms: macOS, Linux

source "$(dirname "$0")/lib.sh"

REPLY_TO=""
TASK_ID=""
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
      ;;
    --task)
      shift
      TASK_ID="${1:-}"
      if [ -z "$TASK_ID" ]; then
        echo "ERROR: --task requires a task id." >&2
        exit 1
      fi
      ;;
    *) break ;;
  esac
  shift
done

TARGET_NAME="${1:-}"
PROMPT_FILE="${2:-}"

if [ -z "$TARGET_NAME" ] || [ -z "$PROMPT_FILE" ]; then
  echo "ERROR: Usage: dispatch-to-session.sh <target-name> <prompt-file>"
  exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: Prompt file not found: $PROMPT_FILE"
  exit 1
fi

# Fail on a malformed --reply-to id BEFORE ensure_tmux, so a bad id is reported
# as such rather than as a missing tmux (matching send-message.sh's ordering).
# apply_envelope below repeats the checks and also refuses conflicting tokens.
if [ -n "$REPLY_TO" ] && ! printf '%s' "$REPLY_TO" | grep -qE '^[a-f0-9]{8,16}$'; then
  echo "ERROR: --reply-to expects an 8-16 char lowercase hex message id (got '$REPLY_TO')." >&2
  exit 1
fi
if [ -n "$TASK_ID" ] && ! [[ "$TASK_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: --task expects a task id of letters, digits, _ and - (got '$TASK_ID')." >&2
  exit 1
fi

ensure_tmux

# A prompt file that is this pane's own strict-v1 draft is removed after a
# durable outcome (see own_draft_identity). Its identity and SHA-256 are taken
# BEFORE the body is read and re-checked right after the read and again before
# removal, so cleanup only removes a source file that is unchanged since it was
# read. This is a best-effort check, not atomic protection against a concurrent
# same-user change between those checks. SESSION_CHAT_KEEP_DRAFTS=1 opts out.
DRAFT_IDENT=""
DRAFT_SUM=""
if [ "${SESSION_CHAT_KEEP_DRAFTS:-0}" != "1" ] && DRAFT_IDENT=$(own_draft_identity "$PROMPT_FILE"); then
  DRAFT_SUM=$(file_sha256 "$PROMPT_FILE") || DRAFT_SUM=""
else
  DRAFT_IDENT=""
fi

# Read the body as data (never as shell), then compose the leading envelope
# ([re:ID] then [task:ID]) onto the in-memory text so it lands at the very top of
# the dispatched file (and is later read for correlation on the recipient).
# A failed or partial read must never be sent, and must never let cleanup
# remove the only complete copy: fail closed before dispatch.
if ! PROMPT_TEXT=$(cat "$PROMPT_FILE"); then
  echo "ERROR: could not read prompt file: $PROMPT_FILE (nothing was sent; the file is kept)" >&2
  exit 1
fi
if [ -n "$DRAFT_IDENT" ]; then
  if [ "$(own_draft_identity "$PROMPT_FILE" 2>/dev/null)" != "$DRAFT_IDENT" ] \
     || [ -z "$DRAFT_SUM" ] || [ "$(file_sha256 "$PROMPT_FILE")" != "$DRAFT_SUM" ]; then
    DRAFT_IDENT=""  # changed while being read: deliver what was read, keep the file
  fi
fi
if [ -n "$REPLY_TO" ] || [ -n "$TASK_ID" ]; then
  PROMPT_TEXT=$(apply_envelope "$REPLY_TO" "$TASK_ID" "$PROMPT_TEXT") || exit 1
fi

dispatch_message "$TARGET_NAME" "$PROMPT_TEXT"
rc=$?
case "$rc" in
  0) echo "Dispatched task to '$TARGET_NAME'" ;;
  3) echo "Queued dispatch to '$TARGET_NAME' — recipient was busy; it will arrive on their next turn." ;;
  *) exit 1 ;;
esac
# Only a durable outcome (0 delivered, 3 queued) reaches here; a hard failure
# exited above and keeps the draft for a retry with the same file.
if [ -n "$DRAFT_IDENT" ]; then
  consume_own_draft "$PROMPT_FILE" "$DRAFT_IDENT" "$DRAFT_SUM"
fi
