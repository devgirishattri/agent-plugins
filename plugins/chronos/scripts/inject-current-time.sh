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
  event=$(printf '%s' "$input" | jq -r '.hook_event_name // "UserPromptSubmit"' 2>/dev/null) || event="UserPromptSubmit"
  session_id=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null) || session_id=""
fi

epoch=$(date +%s)

interval_min="${CHRONOS_INTERVAL_MIN:-5}"
case "$interval_min" in (*[!0-9]*|'') interval_min=5;; esac
state_dir="${TMPDIR:-/tmp}/chronos-${USER:-$(id -u)}"
state_file="${state_dir}/last-${session_id:-default}"

if [ "$event" = "PreToolUse" ]; then
  last=$(cat "$state_file" 2>/dev/null || echo 0)
  case "$last" in (*[!0-9]*|'') last=0;; esac
  if [ $((epoch - last)) -lt $((interval_min * 60)) ]; then
    exit 0
  fi
fi

mkdir -p "$state_dir" 2>/dev/null || true
printf '%s' "$epoch" > "$state_file" 2>/dev/null || true

# Format the captured epoch in the configured timezone. BSD date (macOS) uses
# -r; GNU date (Linux/WSL) uses -d.
if date -r 0 +%s >/dev/null 2>&1; then
  fmt() { date -r "$epoch" "$1"; }
else
  fmt() { date -d "@$epoch" "$1"; }
fi

timezone="${AGENT_PLUGINS_TIME_ZONE:-Asia/Kolkata}"
local_part=$(TZ="$timezone" LC_ALL=C fmt '+%a %Y-%m-%d %H:%M:%S %Z')
offset=$(TZ="$timezone" fmt '+%z')
offset="${offset:0:3}:${offset:3:2}"

context="Current time: ${local_part} (UTC${offset})."

if command -v jq >/dev/null 2>&1; then
  jq -cn --arg ev "$event" --arg ctx "$context" \
    '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}'
else
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "$event" "$context"
fi
exit 0
