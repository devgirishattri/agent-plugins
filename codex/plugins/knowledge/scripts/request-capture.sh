#!/usr/bin/env bash
# request-capture.sh — knowledge 0.3 autonomous-capture Stop hook (CODEX tree;
# opt-in). When the gate is ON and this is not a re-entrant Stop, it asks the
# AGENT (via Codex's blocking Stop shape) to run ONE bounded capture pass over
# its own active context and route any candidates through memory-auto-capture.sh.
# It NEVER writes to the store itself and NEVER decides what is memory-worthy.
#
# This is the capture REQUEST; the actual enforcement + write happens in the
# shared memory-auto-capture.sh wrapper (caps/secrets/dedup) which delegates to
# memory-remember.sh (.inbox only). $knowledge:consolidate stays the persist
# gate.
#
# Sequenced BEFORE nudge-consolidate.sh in hooks.json: on the first Stop this
# blocks and requests capture; on the re-entrant Stop the loop guard makes it
# silent, and the nudge then sees the freshly-pending inbox items.
#
# Output modes:
#   --stop-json  Stop-hook mode. Reads stdin JSON, exits silently when
#                stop_hook_active is true (loop guard), otherwise emits a Codex
#                blocking Stop object: {"decision":"block","reason":"..."} (no
#                hookSpecificOutput). Gate-off / re-entry / unsafe-store all emit
#                EMPTY stdout and exit 0.
#   (no flag)    Prints the capture instruction as plain text — CLI/debug only.
#
# OFF BY DEFAULT: does nothing unless KNOWLEDGE_AUTO_CAPTURE is a non-empty,
# non-"off" value (0.2.1 convention: lowercased, whitespace-trimmed; unset/0/no/
# off/false = OFF, everything else = ON). Silent (exit 0) on any error.
# Supported platforms: macOS, Linux (--stop-json requires python3).
set -uo pipefail

MODE=text
case "${1:-}" in
  --stop-json) MODE=json ;;
  *) : ;;
esac

# ---- opt-in gate (default OFF), 0.2.1 convention ---------------------------
_km_gate="$(printf '%s' "${KNOWLEDGE_AUTO_CAPTURE:-}" | tr '[:upper:]' '[:lower:]')"
_km_gate="${_km_gate#"${_km_gate%%[![:space:]]*}"}"
_km_gate="${_km_gate%"${_km_gate##*[![:space:]]}"}"
case "$_km_gate" in
  ""|0|no|off|false) exit 0 ;;
esac
unset _km_gate

# ---- Stop-hook loop guard (JSON mode): silent on a re-entrant Stop ---------
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
# shellcheck source=lib.sh
source "$DIR/lib.sh" 2>/dev/null || exit 0

store="$(km_resolve_store "" 2>/dev/null)" || exit 0
[ -n "$store" ] && [ -d "$store" ] && [ ! -L "$store" ] && [ -O "$store" ] || exit 0

WRAPPER="$DIR/memory-auto-capture.sh"

read -r -d '' REASON <<EOF || true
knowledge auto-capture: before ending, do ONE bounded pass to capture durable, forward-looking memory from THIS session — then stop.

Capture ONLY (high-confidence): a user preference or standing instruction; a repo/project invariant, architecture decision, workflow rule, or environment fact; a resolved root cause or reusable fix; feedback that changes future behavior; an external tracker/document pointer. SKIP transcripts/summaries, transient todos, speculation, secrets, and anything already in memory unless this session materially changed it. It is completely fine to capture NOTHING.

To capture: write each item as a staged candidate file (the \$knowledge:remember envelope: frontmatter with source: auto_capture, sensitivity, proposed.schema_version "1", proposed.name, proposed.description, proposed.metadata.type, optional tags; body with **Why:** and **How to apply:**) into a fresh temp directory, then run ONCE:
    bash "$WRAPPER" --store "$store" --batch-dir <that-dir>
The wrapper enforces the limits and writes only to the capture inbox; it does NOT persist. Do not call memory-remember.sh or any writer directly. After the wrapper runs (or if there is nothing to capture), stop.
EOF

if [ "$MODE" = json ]; then
  printf '%s' "$REASON" | python3 -c 'import sys, json
reason = sys.stdin.read()
print(json.dumps({"decision": "block", "reason": reason}))' 2>/dev/null || exit 0
else
  printf '%s\n' "$REASON"
fi
exit 0
