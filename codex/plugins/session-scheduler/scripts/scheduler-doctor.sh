#!/usr/bin/env bash
# scheduler-doctor.sh — Inspect session-scheduler setup
# Usage: scheduler-doctor.sh
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

require_jq || exit 1

echo "session-scheduler plugin: $PLUGIN_ROOT"
echo "scheduler dir: $SCHEDULER_DIR"
echo "tasks dir: $TASKS_DIR"
echo "prompts dir: $PROMPTS_DIR"
echo "handoffs dir: $HANDOFFS_DIR ($(find "$HANDOFFS_DIR" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ') file(s))"
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

if ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
  ACTUAL_SCHEDULER=$(absolute_existing_dir "$SCHEDULER_DIR" 2>/dev/null || printf '%s' "$SCHEDULER_DIR")
  echo "ledger home: $ACTUAL_SCHEDULER"
  case "$ACTUAL_SCHEDULER/" in
    "$ROOT/"*) echo "ledger inside current git root: yes" ;;
    *) echo "ledger inside current git root: no (shared external homes are allowed)" ;;
  esac
fi
if [ -n "${SESSION_CONTEXT_HOME:-}" ]; then
  for legacy in "$SESSION_CONTEXT_HOME"/auto_handoff_*.md; do
    [ -f "$legacy" ] || continue
    name=${legacy##*/}; name=${name%.md}
    echo "WARN: legacy scheduler handoff in knowledge store: $legacy"
    printf '  Inspect it, then explicitly remove with: $knowledge:context-remove %s\n' "$name"
  done
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

# Verification contracts (0.7.0, opt-in): the engine needs python3, and a
# contracted done counts only when admitted. Older installed scheduler copies
# preserve a contract but can still mark the task done; consumers then report
# it as closed-unadmitted, which this check surfaces.
contracted=0; closed_unadmitted=0; invalid=0
shopt -s nullglob
for f in "$TASKS_DIR"/*.json; do
  jq -e 'has("contract")' "$f" >/dev/null 2>&1 || continue
  contracted=$((contracted + 1))
  cid=$(jq -r '.id // ""' "$f" 2>/dev/null)
  if ! validate_task_id "$cid" >/dev/null 2>&1 || [ "$(task_file "$cid")" != "$f" ]; then
    invalid=$((invalid + 1)); continue
  fi
  state=$(contract_state "$cid")
  case "$state" in
    closed-unadmitted) closed_unadmitted=$((closed_unadmitted + 1)) ;;
    invalid) invalid=$((invalid + 1)) ;;
  esac
done
shopt -u nullglob
if [ "$contracted" -eq 0 ]; then
  echo "contracts:      none (opt-in; legacy tasks unaffected)"
else
  echo "contracts:      $contracted contracted task(s)"
  if ! command -v python3 >/dev/null 2>&1; then
    echo "  WARN: python3 missing; contracted operations fail closed until it is installed."
  fi
  if [ ! -f "$SCHEDULER_SCRIPTS_DIR/task-contract.sh" ]; then
    echo "  WARN: task-contract.sh missing from this installed copy; contracted tasks are refused."
  fi
  [ "$closed_unadmitted" -gt 0 ] && echo "  WARN: $closed_unadmitted contracted task(s) are done without admission (closed-unadmitted); a pre-0.7.0 helper or a hand edit may have closed them."
  [ "$invalid" -gt 0 ] && echo "  WARN: $invalid contracted task(s) could not be inspected (invalid/unavailable)."
  echo "  NOTE: every pane sharing this ledger needs session-scheduler >= 0.7.0; older copies can close contracted tasks without admission."
fi
