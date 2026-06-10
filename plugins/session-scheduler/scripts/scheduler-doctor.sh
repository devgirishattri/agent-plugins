#!/usr/bin/env bash
# scheduler-doctor.sh — diagnostic for session-scheduler setup.
set -uo pipefail

source "$(dirname "$0")/lib.sh"

ensure_dirs

echo "=== session-scheduler doctor ==="
echo "scheduler dir:  $SCHEDULER_DIR"
echo "tasks dir:      $TASKS_DIR ($(ls -1 "$TASKS_DIR" 2>/dev/null | wc -l | tr -d ' ') task(s))"
echo "prompts dir:    $PROMPTS_DIR ($(ls -1 "$PROMPTS_DIR" 2>/dev/null | wc -l | tr -d ' ') prompt(s))"
echo

echo "current pane:   $(current_pane_name)"
echo "TMUX_PANE:      ${TMUX_PANE:-(not in tmux)}"
echo

echo "incoming-mode:  ${SESSION_CHAT_INCOMING_MODE:-notify (default)}"
case "${SESSION_CHAT_INCOMING_MODE:-notify}" in
  notify)
    echo "  WARN: executor panes in 'notify' mode will NOT act on dispatched tasks."
    echo "  Set SESSION_CHAT_INCOMING_MODE=auto (or assist) in executor shells."
    echo "  See: /session-chat:incoming-mode"
    ;;
  auto|assist)
    echo "  OK: executor will act on incoming tasks."
    ;;
  off)
    echo "  WARN: incoming hook disabled; executors won't even see dispatches."
    ;;
esac
echo

if root=$(session_chat_root); then
  ver=$(basename "$root")
  echo "session-chat:   $root (version $ver)"
  if [ -x "$root/scripts/dispatch-to-session.sh" ]; then
    echo "  dispatch script: OK"
  else
    echo "  WARN: dispatch script missing or not executable"
  fi
else
  echo "session-chat:   NOT FOUND. Install session-chat>=0.11.0 from girishattri-plugins marketplace."
fi
echo

if command -v jq >/dev/null 2>&1; then
  echo "jq:             $(jq --version)"
else
  echo "jq:             MISSING. Install with: brew install jq"
fi

if command -v tmux >/dev/null 2>&1; then
  echo "tmux:           $(tmux -V)"
else
  echo "tmux:           MISSING."
fi

# Date arithmetic check: ETA/overdue/stale flags need ISO<->epoch round-trips.
now_iso=$(iso_now)
now_epoch=$(iso_to_epoch "$now_iso")
if [ "$now_epoch" -gt 0 ]; then
  plus5=$(epoch_to_iso $((now_epoch + 300)))
  if [ -n "$plus5" ]; then
    echo "date math:      OK (now=$now_iso, +5m=$plus5)"
  else
    echo "date math:      WARN: epoch->ISO failed; --eta and OVERDUE flags will not work."
  fi
else
  echo "date math:      WARN: ISO->epoch failed; OVERDUE/STALE flags and durations will not work."
fi
