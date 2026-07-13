#!/usr/bin/env bash
# scheduler-doctor.sh — diagnostic for session-scheduler setup.
set -uo pipefail

source "$(dirname "$0")/lib.sh"

ensure_dirs || exit 1

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
  if ver=$(session_chat_version "$root"); then
    echo "session-chat:   $root (version $ver)"
    if version_ge "$ver" "$SESSION_CHAT_MIN_VERSION"; then
      echo "  version floor: OK (>= $SESSION_CHAT_MIN_VERSION)"
    else
      echo "  ERROR: session-chat $ver is BELOW the required >= $SESSION_CHAT_MIN_VERSION."
      echo "  Dispatch will be REFUSED (a busy-pane dispatch/ack would be lost without the durable inbox). Update session-chat."
    fi
  else
    echo "session-chat:   $root (version undetectable)"
    echo "  WARN: could not read session-chat version; dispatch proceeds only if SESSION_SCHEDULER_SKIP_VERSION_CHECK=1."
  fi
  # Packaged plugin scripts ship 0644 and are invoked via `bash`, so a readable
  # regular file — not an executable bit — is the correct contract.
  if [ -f "$root/scripts/dispatch-to-session.sh" ] && [ -r "$root/scripts/dispatch-to-session.sh" ]; then
    echo "  dispatch script: OK"
  else
    echo "  WARN: dispatch script missing or not readable"
  fi
else
  echo "session-chat:   NOT FOUND. Install session-chat>=$SESSION_CHAT_MIN_VERSION from girishattri-plugins marketplace."
fi
echo

# Ledger-home drift: SESSION_SCHEDULER_HOME is inherited at pane launch, so a
# value that does not match this pane's project root usually just means a shared
# workspace ledger — but surface it so a misconfigured launcher is caught.
# task-assign embeds the absolute home in every prompt as provenance.
gitroot=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
project_home="$(abs_dir "$gitroot")/tmp/scheduler"
active_home="$(abs_dir "$SCHEDULER_DIR")"
echo "ledger home:    $active_home"
if [ "$active_home" = "$project_home" ]; then
  echo "  OK: matches this pane's project root."
else
  echo "  NOTE: differs from this pane's project root ($project_home)."
  echo "  Expected when panes share a workspace-level ledger. If it is wrong, relaunch"
  echo "  the pane with the correct SESSION_SCHEDULER_HOME in its startup environment;"
  echo "  agents must not export it mid-session."
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
