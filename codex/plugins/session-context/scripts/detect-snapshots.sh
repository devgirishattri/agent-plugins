#!/usr/bin/env bash
# detect-snapshots.sh — SessionStart hook for session-context (Codex).
# Surfaces a short, one-time hint when the current project already has context
# snapshots, so a resuming session knows it can load one instead of
# re-deriving state. Stays silent (and exit 0) when there is nothing to surface.
# Output follows the Codex hook convention: a single hookSpecificOutput JSON
# object with additionalContext (see session-chat's detect-incoming-message.sh).
# Supported platforms: macOS, Linux

# Drain hook input from stdin (unused, but keeps the writer side happy)
cat >/dev/null 2>&1 || true

PLUGIN_ROOT="${PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# shellcheck source=/dev/null
source "$PLUGIN_ROOT/scripts/lib.sh" 2>/dev/null || exit 0

SNAP_DIR="$(get_contexts_dir 2>/dev/null)" || exit 0
[ -n "$SNAP_DIR" ] && [ -d "$SNAP_DIR" ] || exit 0

shopt -s nullglob
snaps=("$SNAP_DIR"/*.md)
count=${#snaps[@]}
[ "$count" -eq 0 ] && exit 0

names=""
for f in "${snaps[@]}"; do
  ensure_context_regular_file "$f" >/dev/null 2>&1 || exit 0
  names+="$(basename "$f" .md) "
done
names="${names% }"

json_escape() {
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read(), ensure_ascii=False)[1:-1])'
  else
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | tr '\n\r' '  '
  fi
}

emit_system_message() {
  local message="$1"
  local suffix=" [truncated by session-context to fit Codex additionalContext limit]"
  local max_len=10000
  if [ "${#message}" -gt "$max_len" ]; then
    message="${message:0:$((max_len - ${#suffix}))}${suffix}"
  fi
  message=$(json_escape "$message")
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$message"
}

emit_system_message "session-context: ${count} context snapshot(s) available for this project: ${names}. Run \$session-context:context-load <name> to resume prior work, or \$session-context:context-list for details."
exit 0
