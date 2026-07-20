#!/usr/bin/env bash
# chronos: emit the current date/time as Codex UserPromptSubmit context.

set -uo pipefail

# Drain the hook payload even though this hook does not need its fields.
cat >/dev/null 2>&1 || true

# Capture one epoch before rendering it in the configured timezone.
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

timezone="${AGENT_PLUGINS_TIME_ZONE:-Asia/Kolkata}"
local_part=$(TZ="$timezone" LC_ALL=C format_epoch '+%a %Y-%m-%d %H:%M:%S %Z' 2>/dev/null) || exit 0
offset=$(TZ="$timezone" LC_ALL=C format_epoch '+%z' 2>/dev/null) || exit 0
case "$offset" in
  [+-][0-9][0-9][0-9][0-9]) offset="${offset:0:3}:${offset:3:2}" ;;
  *) exit 0 ;;
esac

context="Current time: ${local_part} (UTC${offset})."

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
