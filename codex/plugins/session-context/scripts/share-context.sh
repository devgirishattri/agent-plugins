#!/usr/bin/env bash
# share-context.sh — Share a context snapshot with another named session
# Usage: share-context.sh <target-session> <project-name>
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

TARGET_SESSION="${1:-}"
PROJECT_NAME="${2:-}"

if [ -z "$PROJECT_NAME" ] || [ -z "$TARGET_SESSION" ]; then
  echo "ERROR: Usage: share-context.sh <target-session> <project-name>"
  exit 1
fi

validate_label "$PROJECT_NAME" || exit 1
validate_label "$TARGET_SESSION" || exit 1

ensure_tmux

SNAPSHOTS_DIR="$(get_contexts_dir)" || exit 1
SNAPSHOTS_DIR="$(cd "$SNAPSHOTS_DIR" 2>/dev/null && pwd -P)" || {
  echo "ERROR: Context snapshot store does not exist or cannot be resolved." >&2
  exit 1
}
STORE_SHELL=$(printf '%q' "$SNAPSHOTS_DIR")
SNAPSHOT="$SNAPSHOTS_DIR/${PROJECT_NAME}.md"

if ! _context_path_exists "$SNAPSHOT"; then
  echo "ERROR: No context snapshot found for '$PROJECT_NAME' in this project. Run \$session-context:context-generate first."
  exit 1
fi
ensure_context_regular_file "$SNAPSHOT" || exit 1

# Sharing is notification-only. The recipient must already resolve the same
# canonical SESSION_CONTEXT_HOME; no snapshot bytes are copied by this operation.
MESSAGE="[context:${PROJECT_NAME}] Context snapshot available. Shared store: ${SNAPSHOTS_DIR}. The file was not copied; export SESSION_CONTEXT_HOME=${STORE_SHELL}. Load with Claude: /session-context:context-load ${PROJECT_NAME}. Load with Codex: \$session-context:context-load ${PROJECT_NAME}."
TRANSPORT=$(send_context_notification "$TARGET_SESSION" "$MESSAGE") || exit 1

echo "Shared '$PROJECT_NAME' context with $TARGET_SESSION."
echo "Transport: $TRANSPORT"
echo "The snapshot was not copied. Both panes must use SESSION_CONTEXT_HOME=$SNAPSHOTS_DIR"
echo "Claude: /session-context:context-load $PROJECT_NAME"
echo "Codex: \$session-context:context-load $PROJECT_NAME"
