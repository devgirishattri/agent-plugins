#!/usr/bin/env bash
# nudge-consolidate.sh — knowledge 0.2 capture-side consolidation nudge
# (CLAUDE tree; opt-in). Stop hook: when the capture inbox holds pending
# candidates, remind to run /knowledge:consolidate. This is a NUDGE only — it
# NEVER writes to the store and NEVER auto-consolidates (consolidate stays
# user-run / model-invocation-disabled per the spec; the 0.3 auto-capture flow
# is a separate roadmap item, NOT this). Zero network egress.
#
# Output modes:
#   --stop-json  Stop-hook mode. Reads the hook's stdin JSON, exits silently
#                when `stop_hook_active` is true (loop guard), and emits a
#                NON-BLOCKING reminder as `hookSpecificOutput.additionalContext`
#                (Claude Stop hooks DISCARD plain stdout — it is only debug-
#                logged, never shown to the model or user — so JSON is required
#                for the reminder to be seen; additionalContext is surfaced for
#                the next turn without forcing a continuation, so it cannot
#                loop). This is what the Stop hook invokes.
#   (no flag)    Plain-text line — for manual/CLI use only; a Claude Stop hook
#                would NOT surface it. Kept so the script is useful on the CLI.
#
# The Codex tree ships its own nudge variant (Codex Stop JSON); scripts are not
# required to be byte-identical across providers (validate-release checks name
# parity, not bytes).
#
# OFF BY DEFAULT: emits nothing unless KNOWLEDGE_CONSOLIDATE_NUDGE is set to a
# non-empty, non-zero value. Silent (exit 0) on any error or an empty inbox.
# Supported platforms: macOS, Linux (--stop-json requires python3).
set -uo pipefail

MODE=text
case "${1:-}" in
  --stop-json) MODE=json ;;
  *) : ;;   # no flag / unknown → plain-text (forward-compatible)
esac

case "${KNOWLEDGE_CONSOLIDATE_NUDGE:-}" in
  ""|0|no|off|false|FALSE|No|Off) exit 0 ;;
esac

# Stop-hook loop guard (JSON mode only): skip when already inside a stop
# continuation. Only read stdin when it is a pipe/file, never a TTY (so a
# manual `--stop-json` run does not block waiting for input).
if [ "$MODE" = json ] && [ ! -t 0 ]; then
  payload="$(cat 2>/dev/null || true)"
  if [ -n "$payload" ]; then
    active="$(printf '%s' "$payload" | python3 -c 'import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print("1" if isinstance(d, dict) and d.get("stop_hook_active") is True else "0")' 2>/dev/null || echo 0)"
    [ "$active" = "1" ] && exit 0
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

msg="knowledge: ${n} pending memory candidate(s) in the capture inbox — run /knowledge:consolidate to review and persist them. Nothing is written automatically."

if [ "$MODE" = json ]; then
  # $n is a validated integer and $msg is fixed text containing no JSON
  # metacharacters (no '\"' or '\\'), so this literal emission is safe.
  printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"%s"}}\n' "$msg"
else
  printf '%s\n' "$msg"
fi
exit 0
