#!/usr/bin/env bash
# nudge-consolidate.sh — knowledge 0.2 capture-side consolidation nudge
# (opt-in, provider-neutral, byte-identical in both trees). Stop hook: if the
# capture inbox holds pending candidates, emit ONE reminder to run
# /knowledge:consolidate. Default output is the existing plain text path; pass
# --stop-json for Codex Stop hooks, where stdout must be JSON. This is a NUDGE
# only — it NEVER writes to the store and NEVER auto-consolidates (consolidate
# stays user-run / model-invocation-disabled per the spec; the 0.3 auto-capture
# flow is a separate roadmap item, NOT this). Zero network egress.
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

if [ "$STOP_JSON" -eq 1 ]; then
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

msg="knowledge: ${n} pending memory candidate(s) in the capture inbox — run /knowledge:consolidate (Claude) or \$knowledge:consolidate (Codex) to review and persist them. Nothing is written automatically."
if [ "$STOP_JSON" -eq 1 ]; then
  msg=${msg//\\/\\\\}
  msg=${msg//\"/\\\"}
  msg=${msg//$'\n'/\\n}
  msg=${msg//$'\r'/\\r}
  msg=${msg//$'\t'/\\t}
  printf '{"decision":"block","reason":"%s"}\n' "$msg"
else
  echo "$msg"
fi
exit 0
