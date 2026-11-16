#!/usr/bin/env bash
# nudge-consolidate.sh — knowledge capture-side consolidation nudge (opt-in,
# provider-neutral, byte-identical in both trees). Stop hook: when the capture
# inbox holds pending candidates, show the USER one reminder to run
# /knowledge:consolidate (Claude) or $knowledge:consolidate (Codex). This is a
# NUDGE only — it NEVER writes to the store and NEVER auto-consolidates
# (consolidate stays user-run and model-invocation-disabled). Zero network
# egress.
#
# Output modes:
#   --stop-json  Stop-hook mode. Reads the hook's stdin JSON, exits silently
#                when `stop_hook_active` is true, and prints
#                {"systemMessage": "..."}. Both providers show a Stop hook's
#                systemMessage to the user only (Claude Code as a message,
#                Codex as a warning line) and let the turn end. The reminder is
#                for the user, since only the user runs consolidate. Claude
#                Code's Stop additionalContext and Codex's decision "block"
#                both continue the turn with the text as model input, so
#                neither is used.
#   (no flag)    Plain-text line, for manual or CLI use.
#
# OFF BY DEFAULT: emits nothing unless KNOWLEDGE_CONSOLIDATE_NUDGE is set to a
# non-empty, non-zero value. Silent (exit 0) on any error or an empty inbox.
# Supported platforms: macOS, Linux.
set -uo pipefail

STOP_JSON=0
case "${1:-}" in
  "") ;;
  --stop-json) STOP_JSON=1 ;;
  *) exit 0 ;;
esac

case "${KNOWLEDGE_CONSOLIDATE_NUDGE:-}" in
  ""|0|no|off|false|FALSE|No|Off) exit 0 ;;
esac

# Stop-hook loop guard: skip inside a stop continuation. Read stdin only when
# it is not a TTY, so a manual --stop-json run does not wait for input.
if [ "$STOP_JSON" -eq 1 ] && [ ! -t 0 ]; then
  hook_input="$(cat 2>/dev/null || true)"
  if printf '%s' "$hook_input" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
    exit 0
  fi
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/lib.sh" 2>/dev/null || exit 0

store="$(km_resolve_store "" 2>/dev/null)" || exit 0
[ -n "$store" ] && [ -d "$store" ] && [ ! -L "$store" ] || exit 0

# Count pending inbox candidates via the read-only lister (never mutates).
n="$(bash "$DIR/memory-remember.sh" --store "$store" --list 2>/dev/null | grep -c . || true)"
case "$n" in ''|*[!0-9]*) exit 0 ;; esac
[ "$n" -gt 0 ] || exit 0

msg="knowledge: ${n} pending memory candidate(s) in the capture inbox — run /knowledge:consolidate (Claude) or \$knowledge:consolidate (Codex) to review them for promotion or dismissal. Nothing is written automatically."
if [ "$STOP_JSON" -eq 1 ]; then
  msg=${msg//\\/\\\\}
  msg=${msg//\"/\\\"}
  msg=${msg//$'\n'/\\n}
  msg=${msg//$'\r'/\\r}
  msg=${msg//$'\t'/\\t}
  printf '{"systemMessage":"%s"}\n' "$msg"
else
  printf '%s\n' "$msg"
fi
exit 0
