#!/usr/bin/env bash
# broadcast-message.sh — Fan-out /send: one message to every named pane.
# Usage: broadcast-message.sh [--all] [--match GLOB] <message>
# Default scope: named panes in the CURRENT tmux session, excluding this pane.
#   --all          target named panes across ALL tmux sessions
#   --match GLOB   only target pane names matching the shell glob (e.g. 'worker-*')
# Per-target results are printed as TSV (<result>\t<name>); summary line last.
# Delivery semantics per target are identical to /send (durable enqueue first,
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
MY_NAME_ERR=$(pop_pane_name_err)
if [ -z "$MY_NAME" ]; then
  # Distinguish a genuinely-unnamed pane from a sandbox denial of the self-name
  # query: the former is a user error (run /whoami), the latter is an escalation
  # problem. Misreporting a denial as "no name" sends the user down the wrong path.
  if [ -n "$MY_NAME_ERR" ]; then
    echo "ERROR: could not resolve this pane's name.$(pane_name_err_detail "$MY_NAME_ERR")" >&2
  else
    echo "ERROR: This pane has no name. Run /whoami <name> first." >&2
  fi
  exit 1
fi

if [ "$SCOPE" = "all" ]; then
  LIST_ARGS=(-a)
else
  # Resolve the current session with stderr preserved: a sandbox denial here
  # yields an empty session name and is the ROOT failure, to be classified at
  # its source rather than only inferred from the follow-on list-panes probe.
  if ! tmux_capture_checked broadcast-session CURRENT_SESSION TMUX_ERR \
      display-message -p -t "${TMUX_PANE:-}" '#{session_name}'; then
    echo "ERROR: could not resolve the current tmux session.$(tmux_err_detail "$TMUX_ERR")" >&2
    exit 1
  fi
  LIST_ARGS=(-s -t "$CURRENT_SESSION")
fi

# Enumerate panes with stderr preserved and fail-checked: a sandbox denial
# returns no rows, and without this we would report "No named panes matched" (a
# benign, misleading message) instead of the real denial. Feed the loop from a
# variable via heredoc so it runs in this shell and the TARGETS array survives.
if ! tmux_capture_checked broadcast-enum PANE_LINES TMUX_ERR \
    list-panes "${LIST_ARGS[@]}" -F $'#{@name}\t#{pane_id}'; then
  echo "ERROR: could not list tmux panes.$(tmux_err_detail "$TMUX_ERR")" >&2
  exit 1
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
done <<EOF_PANES
$PANE_LINES
EOF_PANES

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "No named panes matched (scope: ${SCOPE}, pattern: ${PATTERN}). Run /panes to see targets." >&2
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
