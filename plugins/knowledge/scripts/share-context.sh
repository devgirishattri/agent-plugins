#!/usr/bin/env bash
# share-context.sh — Share a context snapshot with another named session
# Usage: share-context.sh <target-session> <project-name>
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

TARGET_SESSION="${1:-}"
PROJECT_NAME="${2:-}"

if [ -z "$TARGET_SESSION" ] || [ -z "$PROJECT_NAME" ]; then
  echo "ERROR: Usage: share-context.sh <target-session> <project-name>"
  exit 1
fi

validate_context_name "$PROJECT_NAME" || exit 1
# The target session name enters the notification and is used to resolve the
# recipient pane; reject an unsafe label up front (both transports validate too).
if ! validate_label "$TARGET_SESSION" 2>/dev/null; then
  echo "ERROR: invalid target session name '$TARGET_SESSION' (letters, digits, _, - only)." >&2
  exit 1
fi

ensure_tmux

SNAPSHOTS_DIR="$(get_contexts_dir)" || exit 1
SNAPSHOT="$SNAPSHOTS_DIR/${PROJECT_NAME}.md"

if [ ! -f "$SNAPSHOT" ]; then
  echo "ERROR: No context snapshot found for '$PROJECT_NAME'. Run /context-generate first."
  exit 1
fi

# Sharing does NOT copy the snapshot file — it notifies the peer to run
# /context-load, which resolves the name against the PEER's own contexts store.
# So this only works when the recipient shares the same store (same repo /
# SESSION_CONTEXT_HOME). Embed the canonical store path as PROVENANCE so a peer
# can confirm their inherited SESSION_CONTEXT_HOME matches before loading — the
# notification never instructs an executable export; a mismatched recipient
# must request a relaunch with the correct environment instead.
STORE_ABS=$(cd "$SNAPSHOTS_DIR" 2>/dev/null && pwd -P) || STORE_ABS="$SNAPSHOTS_DIR"
# List BOTH provider invocations so a Claude or Codex recipient can act.
SHARE_MSG="[context:${PROJECT_NAME}] Context snapshot shared from store (provenance): ${STORE_ABS} — your inherited SESSION_CONTEXT_HOME must already match; if it is absent or differs, request a relaunch instead of exporting. Load it — Claude: /knowledge:context-load ${PROJECT_NAME} | Codex: \$knowledge:context-load ${PROJECT_NAME}"

# Prefer session-chat's hardened transport (durable inbox: a busy recipient
# still gets the notice next turn). Fall back to this plugin's basic send only
# when session-chat isn't installed.
TRANSPORT=""
# Packaged plugin scripts ship mode 0644 (not +x) and are invoked via `bash`,
# so require a READABLE regular file, not an executable one.
if root=$(session_chat_root) && [ -f "$root/scripts/send-message.sh" ] && [ -r "$root/scripts/send-message.sh" ]; then
  # The send-message.sh wrapper exits 0 for BOTH a live delivery AND a queued
  # (busy-recipient) send — the distinction lives only in its printed output,
  # not the exit status — so parse the output, not the rc. A non-zero rc is a
  # genuine hard failure (no name / unknown or ambiguous target); the wrapper
  # already printed the specific error.
  sc_out=$(bash "$root/scripts/send-message.sh" "$TARGET_SESSION" "$SHARE_MSG" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ERROR: session-chat could not notify '$TARGET_SESSION'; snapshot not shared." >&2
    [ -n "$sc_out" ] && printf '  %s\n' "$sc_out" >&2
    exit 1
  fi
  case "$sc_out" in
    *Queued*) TRANSPORT="session-chat (queued to recipient's durable inbox)" ;;
    *Sent*)   TRANSPORT="session-chat (delivered live)" ;;
    *)        TRANSPORT="session-chat" ;;
  esac
else
  # Fallback transport: knowledge context's own basic send (no durable inbox).
  if ! send_message "$TARGET_SESSION" "$SHARE_MSG"; then
    echo "ERROR: failed to notify '$TARGET_SESSION' (fallback transport)." >&2
    exit 1
  fi
  TRANSPORT="knowledge context builtin (session-chat not installed)"
fi

echo "Shared '$PROJECT_NAME' context with $TARGET_SESSION."
echo "  store:     $STORE_ABS"
echo "  transport: $TRANSPORT"
echo "  They can load it with: /knowledge:context-load $PROJECT_NAME (Codex: \$knowledge:context-load $PROJECT_NAME) — only if they share this store / repo."
