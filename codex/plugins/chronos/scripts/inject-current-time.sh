#!/usr/bin/env bash
# chronos: emit the current date/time as Codex UserPromptSubmit context.

set -uo pipefail

# Drain the hook payload even though this hook does not need its fields.
cat >/dev/null 2>&1 || true

# Capture one epoch before rendering it in IST.
epoch=$(date +%s 2>/dev/null || true)
[ -n "$epoch" ] || exit 0

# BSD date (macOS) formats an epoch with -r; GNU date (Linux/WSL) uses -d @.
date_flavor=""
if date -r "$epoch" '+%s' >/dev/null 2>&1; then
  date_flavor="bsd"
elif date -d "@$epoch" '+%s' >/dev/null 2>&1; then
  date_flavor="gnu"
else
  exit 0
fi

format_epoch() {
  if [ "$date_flavor" = "bsd" ]; then
    date -r "$epoch" "$1"
  else
    date -d "@$epoch" "$1"
  fi
}

ist_part=$(TZ=Asia/Kolkata LC_ALL=C format_epoch '+%a %Y-%m-%d %H:%M:%S IST' 2>/dev/null) || exit 0

context="Current time: ${ist_part} (UTC+05:30)."

json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

context=$(json_escape "$context")
printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' "$context"
exit 0
