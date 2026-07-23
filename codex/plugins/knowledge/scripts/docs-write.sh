#!/usr/bin/env bash
# docs-write.sh — reviewer-role preflight gate for the knowledge plugin's
# explicitly-invoked docs-authoring workflow (docs-create / TODO-ISSUES
# maintenance). This is the ONE deliberate behavior change from the absorbed
# knowledge docs-create surface (KNOWLEDGE_PLUGIN_SPEC.md, "Own vs validate"): the
# docs-create workflow MUST run this helper FIRST, before any doc write or
# edit, and stop immediately on any non-zero exit.
#
# Usage: docs-write.sh --repo <path>
#   Any other argv (missing flag, missing/empty value, extra tokens, unknown
#   options) is a usage error.
#
# Exit codes:
#   0  proceed — docs writes are authorized for this pane/role
#   2  usage error — argv did not match `--repo <path>` exactly
#   6  refused — either a *-reviewer role, or an unresolved fleet identity
#      inside tmux; the single stderr line names which
#
# Role detection (plugin-neutral contract; first non-empty source wins):
#   1. KNOWLEDGE_PANE_NAME
#   2. SESSION_CHAT_PANE_NAME
#   3. the current tmux pane's @name option
# A resolved name matching *-reviewer refuses:
#   stderr: "reviewer role: docs writes refused"
# No source yields a name, and this process IS inside tmux ($TMUX set): that
# is an UNRESOLVED FLEET IDENTITY, not a safe default — refuse:
#   stderr: "unresolved pane identity: set KNOWLEDGE_PANE_NAME"
# No source yields a name, and $TMUX is unset: TRUE SOLO use — proceed.
# Supported platforms: macOS, Linux
set -uo pipefail

if [ "$#" -ne 2 ] || [ "$1" != "--repo" ] || [ -z "${2:-}" ]; then
  echo "ERROR: Usage: docs-write.sh --repo <path>" >&2
  exit 2
fi

_docs_write_pane_name() {
  if [ -n "${KNOWLEDGE_PANE_NAME:-}" ]; then
    printf '%s\n' "$KNOWLEDGE_PANE_NAME"
    return 0
  fi
  if [ -n "${SESSION_CHAT_PANE_NAME:-}" ]; then
    printf '%s\n' "$SESSION_CHAT_PANE_NAME"
    return 0
  fi
  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    local tmux_name
    tmux_name=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{@name}' 2>/dev/null) || tmux_name=""
    if [ -n "$tmux_name" ]; then
      printf '%s\n' "$tmux_name"
      return 0
    fi
  fi
  return 1
}

pane_name=""
if pane_name=$(_docs_write_pane_name); then
  case "$pane_name" in
    *-reviewer)
      echo "reviewer role: docs writes refused" >&2
      exit 6
      ;;
    *)
      exit 0
      ;;
  esac
fi

# No source yielded a name. Inside tmux this is an unresolved fleet identity
# (fail closed, never default to executor authority); outside tmux it is a
# true solo invocation.
if [ -n "${TMUX:-}" ]; then
  echo "unresolved pane identity: set KNOWLEDGE_PANE_NAME" >&2
  exit 6
fi

exit 0
