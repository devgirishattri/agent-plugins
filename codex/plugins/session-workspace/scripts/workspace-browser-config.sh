#!/usr/bin/env bash
# Render or explicitly apply the Codex/Claude MCP client entries derived from
# workspace.json's first-class browser block. Dry-run by default.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/config.sh"
source "$HERE/validate-config.sh"

usage() {
  echo "Usage: workspace-browser-config.sh [--config PATH] [--provider codex|claude|all] [--apply] [--json]" >&2
}

CONFIG_OVERRIDE=""
PROVIDER="all"
APPLY=0
JSON_MODE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_OVERRIDE="${2:-}"; shift 2 ;;
    --provider) PROVIDER="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --json) JSON_MODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage; exit 1 ;;
  esac
done
case "$PROVIDER" in codex|claude|all) ;; *) echo "ERROR: --provider must be codex, claude, or all" >&2; exit 1 ;; esac
if [ "$APPLY" -eq 1 ] && [ "$JSON_MODE" -eq 1 ]; then
  echo "ERROR: --json and --apply cannot be combined; inspect JSON first, then apply separately" >&2
  exit 1
fi

ensure_jq
CONFIG_PATH="$(resolve_project_config_path "$CONFIG_OVERRIDE")" || exit 1
CONFIG_JSON="$(load_workspace_config_raw "$CONFIG_PATH")" || exit 1
if ! validate_workspace_config "$CONFIG_JSON" "$CONFIG_PATH"; then
  echo "ERROR: config failed validation: $CONFIG_PATH" >&2
  print_validation_errors
  exit 1
fi
if ! printf '%s' "$CONFIG_JSON" | jq -e 'has("browser")' >/dev/null; then
  echo "ERROR: config has no top-level browser block" >&2
  exit 1
fi

ROOT_REL="$(printf '%s' "$CONFIG_JSON" | jq -r '.project.root // "."')"
CONFIG_DIR="$(config_base_dir "$CONFIG_PATH")"
ROOT_ABS="$(canonicalize_dir "$CONFIG_DIR/$ROOT_REL")"
[ -n "$ROOT_ABS" ] || { echo "ERROR: project.root does not resolve" >&2; exit 1; }

PORT="$(printf '%s' "$CONFIG_JSON" | jq -r '.browser.port')"
PACKAGE="$(printf '%s' "$CONFIG_JSON" | jq -r '.browser.mcp_package')"
SERVER="$(printf '%s' "$CONFIG_JSON" | jq -r '.browser.mcp_server_name // "chrome-devtools"')"
URL="http://127.0.0.1:$PORT"
CODEX_PATH="$ROOT_ABS/.codex/config.toml"
CLAUDE_PATH="$ROOT_ABS/.mcp.json"
START_MARK="# session-workspace browser:start $SERVER"
END_MARK="# session-workspace browser:end $SERVER"

CODEX_BLOCK="$(printf '%s\n' "$START_MARK" "[mcp_servers.$SERVER]" 'command = "npx"' "args = [\"-y\", \"$PACKAGE\", \"--browser-url=$URL\"]" "$END_MARK")"
CLAUDE_ENTRY="$(jq -n --arg pkg "$PACKAGE" --arg url "$URL" '{type:"stdio",command:"npx",args:["-y",$pkg,("--browser-url="+$url)]}')"

if [ "$JSON_MODE" -eq 1 ]; then
  jq -n --arg mode "$([ "$APPLY" -eq 1 ] && echo apply || echo dry-run)" --arg provider "$PROVIDER" \
    --arg codex_path "$CODEX_PATH" --arg claude_path "$CLAUDE_PATH" --arg codex "$CODEX_BLOCK" \
    --arg server "$SERVER" --argjson claude "$CLAUDE_ENTRY" \
    '{mode:$mode,provider:$provider,codex:{path:$codex_path,block:$codex},claude:{path:$claude_path,server:$server,entry:$claude}}'
  [ "$APPLY" -eq 0 ] && exit 0
fi

if [ "$APPLY" -eq 0 ]; then
  echo "session-workspace browser-config — dry run"
  case "$PROVIDER" in codex|all) printf '\nCodex: %s\n%s\n' "$CODEX_PATH" "$CODEX_BLOCK" ;; esac
  case "$PROVIDER" in claude|all) printf '\nClaude: %s\n' "$CLAUDE_PATH"; jq -n --arg n "$SERVER" --argjson e "$CLAUDE_ENTRY" '{mcpServers:{($n):$e}}' ;; esac
  echo
  echo "Re-run with --apply to write these entries (existing files are backed up)."
  exit 0
fi

preflight_codex() {
  local path="$1"
  [ -L "$(dirname "$path")" ] && { echo "ERROR: refusing symlinked Codex config directory: $(dirname "$path")" >&2; return 1; }
  [ -L "$path" ] && { echo "ERROR: refusing symlinked Codex config file: $path" >&2; return 1; }
  if [ -f "$path" ] && grep -Fq "$START_MARK" "$path"; then
    grep -Fq "$END_MARK" "$path" || { echo "ERROR: incomplete managed browser block in $path" >&2; return 1; }
  elif [ -f "$path" ] && grep -Eq "^[[:space:]]*\[mcp_servers\.$SERVER\][[:space:]]*$" "$path"; then
    echo "ERROR: $path already has an unmanaged [mcp_servers.$SERVER] table; merge it manually or remove it before --apply" >&2
    return 1
  fi
}

preflight_claude() {
  local path="$1" current existing
  [ -L "$path" ] && { echo "ERROR: refusing symlinked Claude MCP config: $path" >&2; return 1; }
  if [ -f "$path" ]; then
    current="$(jq -c '.' "$path" 2>/dev/null)" || { echo "ERROR: $path is not valid JSON" >&2; return 1; }
  else
    current='{}'
  fi
  existing="$(printf '%s' "$current" | jq -c --arg n "$SERVER" '.mcpServers[$n] // null')"
  if [ "$existing" != "null" ] && [ "$existing" != "$(printf '%s' "$CLAUDE_ENTRY" | jq -c '.')" ]; then
    echo "ERROR: $path already has a different unmanaged mcpServers.$SERVER entry; merge it manually or remove it before --apply" >&2
    return 1
  fi
}

# Validate every selected destination before touching either one, so
# --provider all cannot partially update Codex and then fail on Claude (or the
# reverse).
case "$PROVIDER" in codex|all) preflight_codex "$CODEX_PATH" || exit 1 ;; esac
case "$PROVIDER" in claude|all) preflight_claude "$CLAUDE_PATH" || exit 1 ;; esac

apply_codex() {
  local path="$1" tmp
  mkdir -p "$(dirname "$path")"
  if [ -f "$path" ] && grep -Fq "$START_MARK" "$path"; then
    tmp="$(mktemp "${TMPDIR:-/tmp}/workspace-browser-codex.XXXXXX")"
    awk -v start="$START_MARK" -v end="$END_MARK" '
      $0 == start { skip=1; next }
      $0 == end { skip=0; next }
      !skip { print }
    ' "$path" >"$tmp" || { rm -f "$tmp"; return 1; }
    sed -e '${/^$/d;}' "$tmp" >"$tmp.trimmed" || { rm -f "$tmp" "$tmp.trimmed"; return 1; }
    mv "$tmp.trimmed" "$tmp"
    [ -s "$tmp" ] && printf '\n' >>"$tmp"
    printf '%s\n' "$CODEX_BLOCK" >>"$tmp"
  else
    tmp="$(mktemp "${TMPDIR:-/tmp}/workspace-browser-codex.XXXXXX")"
    [ -f "$path" ] && { sed -e '${/^$/d;}' "$path"; echo; } >"$tmp"
    printf '%s\n' "$CODEX_BLOCK" >>"$tmp"
  fi
  [ -f "$path" ] && cp "$path" "$path.bak"
  mv "$tmp" "$path"
  echo "[applied] $path"
}

apply_claude() {
  local path="$1" current tmp
  if [ -f "$path" ]; then
    current="$(jq -c '.' "$path")" || return 1
  else
    current='{}'
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/workspace-browser-claude.XXXXXX")"
  printf '%s' "$current" | jq --arg n "$SERVER" --argjson e "$CLAUDE_ENTRY" '.mcpServers = (.mcpServers // {}) | .mcpServers[$n] = $e' >"$tmp"
  [ -f "$path" ] && cp "$path" "$path.bak"
  mv "$tmp" "$path"
  echo "[applied] $path"
}

case "$PROVIDER" in codex|all) apply_codex "$CODEX_PATH" || exit 1 ;; esac
case "$PROVIDER" in claude|all) apply_claude "$CLAUDE_PATH" || exit 1 ;; esac
echo "Start the browser session before opening a new Codex or Claude session."
