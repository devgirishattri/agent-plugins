#!/usr/bin/env bash
# scheduler-doctor.sh — Inspect session-scheduler setup
# Usage: scheduler-doctor.sh
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

require_jq || exit 1
ensure_dirs || exit 1

echo "session-scheduler plugin: $PLUGIN_ROOT"
echo "scheduler dir: $SCHEDULER_DIR"
echo "tasks dir: $TASKS_DIR"
echo "prompts dir: $PROMPTS_DIR"
echo "pane name: $(current_pane_name)"
echo "context dir: ${SESSION_CONTEXT_HOME:-(not set)}"

if CHAT_ROOT=$(session_chat_root 2>/dev/null); then
  echo "session-chat root: $CHAT_ROOT"
  echo "session-chat version: $(session_chat_version "$CHAT_ROOT")"
else
  echo "session-chat root: missing"
  session_chat_root >/dev/null || true
fi

echo "incoming mode: ${SESSION_CHAT_INCOMING_MODE:-notify}"
echo "executor panes should use SESSION_CHAT_INCOMING_MODE=auto or assist to act on assigned dispatches."

# Date arithmetic check: ETA/overdue/stale flags need ISO<->epoch round-trips.
now_iso_val=$(now_iso)
now_epoch_val=$(iso_to_epoch "$now_iso_val")
if [ "$now_epoch_val" -gt 0 ]; then
  plus5=$(epoch_to_iso $((now_epoch_val + 300)))
  if [ -n "$plus5" ]; then
    echo "date math: OK (now=$now_iso_val, +5m=$plus5)"
  else
    echo "date math: WARN epoch->ISO failed; --eta and OVERDUE flags will not work."
  fi
else
  echo "date math: WARN ISO->epoch failed; OVERDUE/STALE flags and durations will not work."
fi

if ROOT=$(workspace_root 2>/dev/null); then
  EXPECTED_SCHEDULER="$ROOT/tmp/scheduler"
  EXPECTED_CONTEXT="$ROOT/tmp/contexts"
  ACTUAL_SCHEDULER=$(absolute_existing_dir "$SCHEDULER_DIR" 2>/dev/null || printf '%s' "$SCHEDULER_DIR")
  if [ "$ACTUAL_SCHEDULER" = "$EXPECTED_SCHEDULER" ]; then
    echo "workspace scheduler home: OK ($ROOT)"
  else
    echo "workspace scheduler home: WARN expected $EXPECTED_SCHEDULER, got $ACTUAL_SCHEDULER"
    echo "This usually means a child checkout is using a private ledger instead of the workspace ledger."
  fi
  if [ -n "${SESSION_CONTEXT_HOME:-}" ]; then
    mkdir -p "$SESSION_CONTEXT_HOME"
    ACTUAL_CONTEXT=$(absolute_existing_dir "$SESSION_CONTEXT_HOME" 2>/dev/null || printf '%s' "$SESSION_CONTEXT_HOME")
    if [ "$ACTUAL_CONTEXT" = "$EXPECTED_CONTEXT" ]; then
      echo "workspace context home: OK"
    else
      echo "workspace context home: WARN expected $EXPECTED_CONTEXT, got $ACTUAL_CONTEXT"
    fi
  else
    echo "workspace context home: WARN SESSION_CONTEXT_HOME is not set; expected $EXPECTED_CONTEXT"
  fi
fi

RECORDED_HOMES=""
for file in "$TASKS_DIR"/*.json; do
  [ -f "$file" ] || continue
  home=$(jq -r '.meta.scheduler_home // .scheduler_home // empty' "$file" 2>/dev/null || true)
  [ -n "$home" ] && RECORDED_HOMES="${RECORDED_HOMES}${home}\n"
done
if [ -n "$RECORDED_HOMES" ]; then
  UNIQUE_HOMES=$(printf '%b' "$RECORDED_HOMES" | sort -u)
  HOME_COUNT=$(printf '%s\n' "$UNIQUE_HOMES" | grep -c .)
  if [ "$HOME_COUNT" -gt 1 ]; then
    echo "ledger provenance: WARN task records reference multiple scheduler homes:"
    printf '%s\n' "$UNIQUE_HOMES" | sed 's/^/  /'
  else
    echo "ledger provenance: OK ($UNIQUE_HOMES)"
  fi
fi
