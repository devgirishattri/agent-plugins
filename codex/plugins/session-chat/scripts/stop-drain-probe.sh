#!/usr/bin/env bash
# stop-drain-probe.sh — TEMPORARY Stop-hook instrumentation (round 1 of the
# Codex Stop-drain port). Answers three questions before any real drain ships:
#   (a) does Codex fire Stop hooks at turn end?
#   (b) what is the Stop hook's input schema (loop guards? thread fields?)
#   (c) does hookSpecificOutput/additionalContext emitted on Stop reach the
#       agent, or is Stop output discarded?
# STRICTLY NON-DESTRUCTIVE: peeks at the durable inbox read-only; never
# dequeues or marks anything, so a discarded envelope cannot lose messages.
# Diagnostics append to: $CODEX_HOME/messages/.stop-hook-capture.log
# Remove this script and its Stop registration once the real drain ships.

HOOK_INPUT=$(cat)

CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
CAPTURE="$CODEX_DIR/messages/.stop-hook-capture.log"
mkdir -p "$(dirname "$CAPTURE")" 2>/dev/null || exit 0

{
  printf -- '--- %s ---\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  printf 'ENV: TMUX=%s TMUX_PANE=%s CODEX_PLUGIN_ROOT=%s PWD=%s\n' \
    "${TMUX:-unset}" "${TMUX_PANE:-unset}" "${CODEX_PLUGIN_ROOT:-unset}" "$PWD"
  printf 'INPUT: %s\n' "$HOOK_INPUT"
} >> "$CAPTURE" 2>/dev/null

# Read-only peek at this pane's durable inbox (same name/queue layout lib.sh
# uses; intentionally not sourcing lib.sh so the probe cannot mutate state).
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
printf 'PEEK: name=%s ready=%s total=%s\n' "${MY_NAME:-none}" "$READY" "$TOTAL" >> "$CAPTURE" 2>/dev/null

# Marked envelope: if the agent can quote STOP-PROBE-MARKER-7Q4 after a turn
# ends, Stop output is surfaced and the real drain can ship.
printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"session-chat STOP-PROBE-MARKER-7Q4 — Stop-hook output test; no action needed. Inbox peek: %s ready / %s total queued message(s)."}}\n' "$READY" "$TOTAL"
exit 0
