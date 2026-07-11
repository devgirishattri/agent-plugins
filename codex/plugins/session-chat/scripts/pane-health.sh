#!/usr/bin/env bash
# pane-health.sh — Liveness and backlog report for named panes, so a dead or
# misnamed worker is caught before a send times out against it.
# Usage: pane-health.sh [name] [--all]
#   name    check a single pane name (searched across all sessions)
#   --all   check named panes in ALL sessions (default: current session)
# Output: TSV rows  <name> <pane> <status> <command> <location> <backlog> <send-lock>
#   status:   ok | DEAD (pane_dead) | DUPLICATE (name resolves to >1 pane)
#   location: pane's current working directory
#   backlog:  ready/total rows waiting in that pane's durable inbox
#   send-lock: - | held(pid) | STALE(pid) (stale = holder process is gone)
set -uo pipefail

source "$(dirname "$0")/lib.sh"
ensure_tmux

TARGET=""
SCOPE="session"
for arg in "$@"; do
  case "$arg" in
    --all|all) SCOPE="all" ;;
    -h|--help)
      echo "Usage: pane-health.sh [name] [--all]"
      exit 0
      ;;
    -*)
      echo "ERROR: Unknown option: $arg" >&2
      exit 1
      ;;
    *) TARGET="$arg" ;;
  esac
done

if [ -n "$TARGET" ] || [ "$SCOPE" = "all" ]; then
  LIST_ARGS=(-a)
else
  CURRENT_SESSION=$(tmux_capture_checked pane-health-session \
    "Cannot determine the current tmux session" \
    display-message -p -t "${TMUX_PANE:-}" '#{session_name}') || exit $?
  LIST_ARGS=(-s -t "$CURRENT_SESSION")
fi

RAW_PANE_ROWS=$(tmux_capture_checked pane-health-rows "Cannot inspect tmux pane health" \
  list-panes "${LIST_ARGS[@]}" \
  -F $'#{@name}\t#{pane_id}\t#{pane_dead}\t#{pane_current_command}\t#{pane_current_path}') || exit $?
PANE_ROWS=$(printf '%s\n' "$RAW_PANE_ROWS" | awk -F'\t' '$1 != ""')

if [ -n "$TARGET" ]; then
  PANE_ROWS=$(printf '%s\n' "$PANE_ROWS" | awk -F'\t' -v want="$TARGET" '$1 == want')
  if [ -z "$PANE_ROWS" ]; then
    echo "ERROR: No pane named '$TARGET'. Run \$session-chat:panes all to see all available named panes." >&2
    exit 1
  fi
fi

if [ -z "$PANE_ROWS" ]; then
  echo "No named panes found (scope: ${SCOPE}). Use \$session-chat:whoami <name> to name panes."
  exit 0
fi

NOW=$(now_ms)
NAME_LIST=$(printf '%s\n' "$PANE_ROWS" | awk -F'\t' '{ print $1 }')

queue_backlog() {
  # queue_backlog <name> <pane_id> -> "ready/total" for that pane's runtime dir
  local name="$1" pane_id="$2"
  local dir qf
  dir=$(target_messages_dir_for_pane "$pane_id")
  qf=$(queue_file_for "$name" "$dir")
  if [ ! -f "$qf" ]; then
    printf '0/0'
    return 0
  fi
  awk -F'\t' -v now="$NOW" '
    $1 != "" {
      total++
      if ($4 !~ /^[0-9]+$/ || $4 <= now) ready++
    }
    END { printf "%d/%d", ready + 0, total + 0 }
  ' "$qf" 2>/dev/null || printf '0/0'
}

lock_state() {
  # lock_state <pane_id> -> - | held(pid) | STALE(pid)
  local pane_id="$1"
  local lock pid
  if ! lock=$(send_lock_path "$pane_id"); then
    printf 'UNSAFE'
    return 0
  fi
  if [ ! -d "$lock" ]; then
    printf -- '-'
    return 0
  fi
  pid=$(tr -d '[:space:]' < "$lock/pid" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    printf 'held(%s)' "$pid"
  else
    printf 'STALE(%s)' "${pid:-?}"
  fi
}

OK=0
PROBLEMS=0
printf 'NAME\tPANE\tSTATUS\tCOMMAND\tLOCATION\tBACKLOG\tSEND-LOCK\n'
while IFS=$'\t' read -r name pane_id dead cmd path; do
  [ -n "$name" ] || continue
  status="ok"
  if [ "$dead" = "1" ]; then
    status="DEAD"
  elif [ "$(printf '%s\n' "$NAME_LIST" | grep -Fxc "$name")" -gt 1 ]; then
    status="DUPLICATE"
  fi
  backlog=$(queue_backlog "$name" "$pane_id")
  lock=$(lock_state "$pane_id")
  case "$backlog" in
    0/*) ;;
    *) [ "$status" = "ok" ] && status="ok(backlog)" ;;
  esac
  if [ "$status" = "ok" ]; then
    OK=$((OK + 1))
  else
    PROBLEMS=$((PROBLEMS + 1))
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$pane_id" "$status" "$cmd" "${path:--}" "$backlog" "$lock"
done <<EOF_ROWS
$PANE_ROWS
EOF_ROWS

echo "—"
echo "${OK} healthy, ${PROBLEMS} needing attention. DEAD = pane process exited; DUPLICATE = rename one via \$session-chat:whoami; ready>0 backlog = messages waiting for that pane's next turn; STALE lock = clear with: rm -rf <lock-path>."
exit 0
