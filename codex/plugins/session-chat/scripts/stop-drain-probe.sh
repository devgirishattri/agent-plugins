#!/usr/bin/env bash
# stop-drain-probe.sh — TEMPORARY Stop-hook instrumentation, round 2.
# Round 1 proved: Stop fires at turn end with Claude-like input (incl.
# stop_hook_active), TMUX_PANE available, and hookSpecificOutput is REJECTED
# ("invalid stop hook JSON output"). Round 2 tests the Claude-style decision
# envelope: when ready queued messages exist, emit {"decision":"block",...}
# with a marker reason and observe whether the agent continues and can quote
# it. STILL NON-DESTRUCTIVE: rows are peeked, never dequeued, so a rejected
# envelope cannot lose messages.
# Diagnostics append to: $CODEX_HOME/messages/.stop-hook-capture.log
# Replace with the real drain in detect-incoming-message.sh once proven.

HOOK_INPUT=$(cat)

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CAPTURE="$CODEX_DIR/messages/.stop-hook-capture.log"
mkdir -p "$(dirname "$CAPTURE")" 2>/dev/null || exit 0

log() { printf '%s\n' "$1" >> "$CAPTURE" 2>/dev/null; }

log "--- $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) round2 ---"
log "INPUT: $HOOK_INPUT"

# Re-entry guard: never block a stop that a stop hook already continued.
if printf '%s' "$HOOK_INPUT" | grep -q '"stop_hook_active":[[:space:]]*true'; then
  log "RESULT: stop_hook_active=true, allowing stop"
  exit 0
fi

# Read-only peek at this pane's durable inbox.
READY=0
TOTAL=0
MY_NAME=""
if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
  MY_NAME=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@name}' 2>/dev/null)
fi
if [ -n "$MY_NAME" ]; then
  SAFE=$(printf '%s' "$MY_NAME" | tr -c 'a-zA-Z0-9._-' '_')
  QF="$CODEX_DIR/messages/queue/${SAFE}.tsv"
  if [ -f "$QF" ]; then
    NOW=$(( $(date +%s 2>/dev/null || echo 0) * 1000 ))
    TOTAL=$(grep -c . "$QF" 2>/dev/null) || TOTAL=0
    READY=$(awk -F'\t' -v now="$NOW" '$1 != "" { if ($4 !~ /^[0-9]+$/ || $4 <= now) r++ } END { print r + 0 }' "$QF" 2>/dev/null) || READY=0
  fi
fi
log "PEEK: name=${MY_NAME:-none} ready=$READY total=$TOTAL"

if [ "$READY" -eq 0 ] 2>/dev/null; then
  log "RESULT: inbox empty/not-ready, allowing stop (no output)"
  exit 0
fi

log "RESULT: emitting decision:block with marker"
printf '{"decision":"block","reason":"session-chat STOP-PROBE-ROUND2-9K1: %s queued message(s) are waiting in this pane'\''s inbox (probe only — rows untouched; they will surface on your next prompt). If you can read this marker after ending a turn, the Stop decision envelope works. No reply needed."}\n' "$READY"
exit 0
