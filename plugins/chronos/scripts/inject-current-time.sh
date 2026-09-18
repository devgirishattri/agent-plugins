#!/usr/bin/env bash
# chronos: emit the current date/time as additionalContext for Claude Code hooks.
#
# UserPromptSubmit: always emits (every prompt gets a fresh timestamp).
# PreToolUse: emits only when CHRONOS_INTERVAL_MIN (default 5) minutes have
# elapsed since the last emission for this session, so long autonomous turns
# stay time-aware without injecting a line per tool call.
set -uo pipefail

input=$(cat 2>/dev/null || true)

event="UserPromptSubmit"
session_id=""
if command -v jq >/dev/null 2>&1 && [ -n "$input" ]; then
  fields=$(printf '%s' "$input" | jq -r '[.hook_event_name // "UserPromptSubmit", .session_id // ""] | @tsv' 2>/dev/null) || fields=""
  if [ -n "$fields" ]; then
    IFS=$'\t' read -r event session_id <<<"$fields"
  fi
fi

epoch=$(date +%s)

interval_min="${CHRONOS_INTERVAL_MIN:-5}"
case "$interval_min" in (*[!0-9]*|'') interval_min=5;; esac

# Throttle state lives under a per-user, owner-only directory — never the
# shared temp root. A predictable path under /tmp let another local user
# pre-create the directory and plant a symlink where the state file goes, so
# the truncating write below would clobber any file the victim can write.
# Precedence: XDG_RUNTIME_DIR (per-user 0700 tmpfs on Linux) > XDG_CACHE_HOME >
# $HOME/.cache. Every access re-checks ownership and refuses symlinks; on any
# doubt the hook skips the state (emitting is harmless) and never writes.
state_root="${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-${HOME:-/nonexistent}/.cache}}"
state_dir="${state_root}/chronos"
state_file="${state_dir}/last-${session_id:-default}"

state_dir_ok() {
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] && [ -O "$state_dir" ]
}
state_read() {
  state_dir_ok || return 1
  [ -f "$state_file" ] && [ ! -L "$state_file" ] && [ -O "$state_file" ] || return 1
  cat "$state_file" 2>/dev/null
}
state_write() {
  if [ ! -e "$state_dir" ] && [ ! -L "$state_dir" ]; then
    ( umask 077; mkdir -p "$state_dir" ) 2>/dev/null || return 0
  fi
  state_dir_ok || return 0
  chmod 0700 "$state_dir" 2>/dev/null || true
  [ ! -L "$state_file" ] || return 0
  local tmp
  tmp=$(mktemp "$state_dir/.last.XXXXXX" 2>/dev/null) || return 0
  if printf '%s' "$epoch" > "$tmp" 2>/dev/null && [ ! -L "$state_file" ]; then
    mv -f "$tmp" "$state_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

if [ "$event" = "PreToolUse" ]; then
  last=$(state_read) || last=0
  case "$last" in (*[!0-9]*|'') last=0;; esac
  if [ $((epoch - last)) -lt $((interval_min * 60)) ]; then
    exit 0
  fi
fi

state_write

# Format the captured epoch in the configured timezone. BSD date (macOS) uses
# -r; GNU date (Linux/WSL) uses -d.
if date -r 0 +%s >/dev/null 2>&1; then
  fmt() { date -r "$epoch" "$1"; }
else
  fmt() { date -d "@$epoch" "$1"; }
fi

resolve_timezone() {
  local timezone="${AGENT_PLUGINS_TIME_ZONE:-Asia/Kolkata}" root
  case "$timezone" in
    ""|/*|*..*|*[!A-Za-z0-9_+./-]*) return 1 ;;
  esac
  for root in /usr/share/zoneinfo /usr/share/lib/zoneinfo /usr/lib/zoneinfo; do
    [ -f "$root/$timezone" ] && { printf '%s\n' "$timezone"; return 0; }
  done
  return 1
}

timezone=$(resolve_timezone) || {
  echo "chronos: invalid AGENT_PLUGINS_TIME_ZONE '${AGENT_PLUGINS_TIME_ZONE:-}'" >&2
  exit 0
}
local_part=$(TZ="$timezone" LC_ALL=C fmt '+%a %Y-%m-%d %H:%M:%S %Z')
offset=$(TZ="$timezone" LC_ALL=C fmt '+%z')
case "$offset" in
  [+-][0-9][0-9][0-9][0-9]) offset="${offset:0:3}:${offset:3:2}" ;;
  *) exit 0 ;;
esac

context="Current time: ${local_part} (UTC${offset})."

if command -v jq >/dev/null 2>&1; then
  jq -cn --arg ev "$event" --arg ctx "$context" \
    '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}'
else
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$event" "$context"
fi
exit 0
