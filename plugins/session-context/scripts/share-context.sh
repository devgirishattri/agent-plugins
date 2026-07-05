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

validate_label "$PROJECT_NAME" || exit 1

ensure_tmux

SNAPSHOTS_DIR="$(get_contexts_dir)" || exit 1
SNAPSHOT="$SNAPSHOTS_DIR/${PROJECT_NAME}.md"

if [ ! -f "$SNAPSHOT" ]; then
  echo "ERROR: No context snapshot found for '$PROJECT_NAME'. Run /context-generate first."
  exit 1
fi

# Copy snapshot to target session's snapshots dir (file-based sharing)
# This way the target session can /context-load it directly
TARGET_PANE=$(resolve_pane "$TARGET_SESSION") || exit 1

# Notify the target session about the shared context
MY_NAME=$(get_my_name)
[ -z "$MY_NAME" ] && MY_NAME="unknown"

send_message "$TARGET_SESSION" "[context:${PROJECT_NAME}] Context snapshot shared. Load it with: /context-load ${PROJECT_NAME}"

echo "Shared '$PROJECT_NAME' context with $TARGET_SESSION."
echo "They can load it with: /context-load $PROJECT_NAME"
