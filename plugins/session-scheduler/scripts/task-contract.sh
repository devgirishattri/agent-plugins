#!/usr/bin/env bash
# Opt-in scheduler contracts; caller stores and identity remain inherited.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -z "${SESSION_SCHEDULER_HOME:-}" ]; then
  echo '{"state":"invalid","error":"SESSION_SCHEDULER_HOME must be inherited"}'
  exit 2
fi
source "$HERE/lib.sh"
command -v python3 >/dev/null 2>&1 || { echo '{"state":"invalid","error":"python3 unavailable"}'; exit 2; }
require_jq || { echo '{"state":"invalid","error":"jq unavailable"}'; exit 2; }
ensure_dirs || { echo '{"state":"invalid","error":"scheduler store unavailable"}'; exit 2; }
TASK_CONTRACT_ACTOR=$(current_pane_name)
TASK_CONTRACT_CHAT_ROOT=$(session_chat_root 2>/dev/null || true)
export TASK_CONTRACT_ACTOR TASK_CONTRACT_CHAT_ROOT
if [ "${1:-}" = route ]; then
  shift
  operation=${1:-}; shift || true
  case "$operation" in
    assign) exec python3 "$HERE/task-contract.py" assign "$@" ;;
    review|done|block)
      if [ "$#" -ne 4 ] || [ "${2:-}" != --generation ]; then
        echo '{"state":"invalid","error":"requires id --generation N literal-note"}'; exit 2
      fi
      exec python3 "$HERE/task-contract.py" "$operation" "$1" --generation "$3" --note "$4"
      ;;
    *) echo '{"state":"invalid","error":"unknown transition"}'; exit 2 ;;
  esac
fi
exec python3 "$HERE/task-contract.py" "$@"
