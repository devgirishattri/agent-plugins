#!/usr/bin/env bash
# broadcast-message.sh — Fan out one session-chat send to named panes.
# Usage: broadcast-message.sh [--all] [--match GLOB] <message>
# Default scope: named panes in the CURRENT tmux session, excluding this pane.
#   --all          target named panes across ALL tmux sessions
#   --match GLOB   only target pane names matching the shell glob (e.g. 'worker-*')
# Per-target results are printed as TSV (<result>\t<name>); summary line last.
# Delivery semantics per target are identical to session-chat send (durable enqueue first,
# live paste, queued fallback on busy recipients).
set -uo pipefail

source "$(dirname "$0")/lib.sh"

SCOPE="session"
PATTERN="*"
while [ $# -gt 0 ]; do
  case "$1" in
    --all) SCOPE="all" ;;
    --match)
      shift
      PATTERN="${1:-}"
      if [ -z "$PATTERN" ]; then
        echo "ERROR: --match requires a glob pattern (e.g. --match 'worker-*')." >&2
        exit 1
      fi
      ;;
    --priority)
      shift
      export SESSION_CHAT_PRIORITY="${1:-normal}"
      ;;
    --ttl)
      shift
      _ttl_min=$(normalize_positive_int "${1:-0}" 0)
      export SESSION_CHAT_TTL_MS=$((_ttl_min * 60000))
      ;;
    -h|--help)
      echo "Usage: broadcast-message.sh [--all] [--match GLOB] [--priority high|normal] [--ttl MINUTES] <message>"
      exit 0
      ;;
    --) shift; break ;;
    -*)
      echo "ERROR: Unknown option: $1" >&2
      exit 1
      ;;
    *) break ;;
  esac
  shift
done

MESSAGE="$*"
if [ -z "$MESSAGE" ]; then
  echo "ERROR: No message specified." >&2
  echo "Usage: broadcast-message.sh [--all] [--match GLOB] <message>" >&2
  exit 1
fi

ensure_tmux

MY_NAME=$(get_my_name)
if [ -z "$MY_NAME" ]; then
  echo "ERROR: This pane has no name. Run \$session-chat:whoami <name> first." >&2
  exit 1
fi

if [ "$SCOPE" = "all" ]; then
  LIST_ARGS=(-a)
else
  CURRENT_SESSION=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null)
  LIST_ARGS=(-s -t "$CURRENT_SESSION")
fi

# Collect unique target names: named panes only, never self (by pane id or by
# name — a broadcast that loops back to its sender is always a bug).
TARGETS=()
SEEN=""
while IFS=$'\t' read -r name pane_id; do
  [ -n "$name" ] || continue
  [ "$pane_id" = "${TMUX_PANE:-}" ] && continue
  [ "$name" = "$MY_NAME" ] && continue
  # shellcheck disable=SC2254
  case "$name" in
    $PATTERN) ;;
    *) continue ;;
  esac
  case " $SEEN " in *" $name "*) continue ;; esac
  SEEN="$SEEN $name"
  TARGETS+=("$name")
done < <(tmux list-panes "${LIST_ARGS[@]}" -F $'#{@name}\t#{pane_id}' 2>/dev/null)

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "No named panes matched (scope: ${SCOPE}, pattern: ${PATTERN}). Run \$session-chat:panes to see targets." >&2
  exit 1
fi

DELIVERED=0
QUEUED=0
FAILED=0
for name in "${TARGETS[@]}"; do
  send_message "$name" "$MESSAGE"
  rc=$?
  case "$rc" in
    0) printf 'sent\t%s\n' "$name"; DELIVERED=$((DELIVERED + 1)) ;;
    3) printf 'queued\t%s\n' "$name"; QUEUED=$((QUEUED + 1)) ;;
    *) printf 'failed\t%s\n' "$name"; FAILED=$((FAILED + 1)) ;;
  esac
done

echo "Broadcast to ${#TARGETS[@]} pane(s): ${DELIVERED} sent, ${QUEUED} queued, ${FAILED} failed."
[ "$FAILED" -eq "${#TARGETS[@]}" ] && exit 1
exit 0
