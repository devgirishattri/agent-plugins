#!/usr/bin/env bash
# Canonical build-time fragment for session-chat and session-scheduler.
resolve_pane_actor() {
  local panes actor pid=$$ parent pane_pid pane_id record
  local claimed=${SESSION_CHAT_PANE_NAME:-}
  if ! panes=$(tmux list-panes -a -F '#{pane_pid} #{pane_id}' 2>&1); then
    if [ "${1:-}" = --read-only ] && [[ "$claimed" =~ ^[A-Za-z0-9._-]+$ ]]; then
      printf '%s\n' "$claimed"
      return 0
    fi
    echo "ERROR: Cannot resolve the calling tmux pane: $panes" >&2
    case "$panes" in
      *'Operation not permitted'*|*'Permission denied'*)
        echo 'Re-run this command escalated/approved to access the tmux socket.' >&2 ;;
    esac
    return 1
  fi
  while [ "$pid" -gt 1 ]; do
    while read -r pane_pid pane_id; do
      [ "$pane_pid" = "$pid" ] || continue
      [[ "$pane_id" =~ ^%[0-9]+$ ]] || break
      # Read the name only for the matched pane. Recheck its PID in the
      # same response in case the pane was respawned during the walk.
      record=$(tmux display-message -p -t "$pane_id" '#{pane_pid} #{@name}') || return 1
      if [[ "$record" != "$pid "* ]]; then
        echo 'ERROR: The calling tmux pane changed while resolving its actor.' >&2
        return 1
      fi
      actor=${record#* }
      if [ -n "$claimed" ] && [ "$claimed" != "$actor" ]; then
        echo 'ERROR: SESSION_CHAT_PANE_NAME disagrees with the calling tmux pane.' >&2
        return 1
      fi
      if [ "${1:-}" = --read-only ] && [ -z "$actor" ]; then
        return 0
      fi
      if ! [[ "$actor" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo 'ERROR: The calling tmux pane has an empty or unsafe externally assigned name.' >&2
        return 1
      fi
      if [ "${1:-}" = --with-id ]; then
        printf '%s\t%s\n' "$actor" "$pane_id"
      else
        printf '%s\n' "$actor"
      fi
      return 0
    done <<< "$panes"
    if ! parent=$(/bin/ps -o ppid= -p "$pid" 2>&1); then
      echo "ERROR: Cannot read the calling process ancestry: $parent" >&2
      case "$parent" in
        *'Operation not permitted'*|*'Permission denied'*)
          echo 'Re-run this command escalated/approved to read process ancestry.' >&2 ;;
      esac
      return 1
    fi
    parent=${parent//[[:space:]]/}
    [[ "$parent" =~ ^[0-9]+$ ]] && [ "$parent" != "$pid" ] || break
    pid=$parent
  done
  echo 'ERROR: No tmux pane owns the calling process or its ancestors.' >&2
  return 1
}
