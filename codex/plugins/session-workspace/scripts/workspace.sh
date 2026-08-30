#!/usr/bin/env bash
# workspace.sh — session-workspace CLI dispatcher.
# Verbs: plan | start | status | stop | doctor | reconcile | restart | install | browser-config
#        harness-status | harness-doctor  (read-only views of the opt-in harness)
#
# `install` is the odd one out: it takes no config and touches no tmux. It
# installs this plugin's machine-wide `workspace` dispatcher onto PATH, and is
# the sanctioned refresh for that copy (see workspace-install.sh).
#
# This is the entrypoint the project-local bootstrap shim
# (templates/workspace.sh) execs into: `exec bash "$root/scripts/workspace.sh" "$@"`.
#
# `--contract` is the handshake the shim uses to confirm engine compatibility
# before delegating; it is answered before any dependency check so the probe
# works even on a machine without jq/tmux. Every verb below is implemented and
# dispatched to its own script.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"

# Contract check comes first and unconditionally, ahead of dependency checks
# below — the bootstrap shim must be able to probe compatibility even on a
# machine that doesn't yet have jq/tmux installed.
if [ "${1:-}" = "--contract" ]; then
  echo "$SESSION_WORKSPACE_CLI_CONTRACT"
  exit 0
fi

usage() {
  echo "Usage: workspace.sh <plan|start|status|stop|doctor|reconcile|restart|install|browser-config|harness-status|harness-doctor> [args...]" >&2
  echo "       workspace.sh --contract" >&2
}

VERB="${1:-}"
if [ -z "$VERB" ]; then
  usage
  exit 1
fi
shift || true

case "$VERB" in
  plan)
    exec bash "$HERE/workspace-plan.sh" "$@"
    ;;
  start)
    exec bash "$HERE/workspace-start.sh" "$@"
    ;;
  status)
    exec bash "$HERE/workspace-status.sh" "$@"
    ;;
  stop)
    exec bash "$HERE/workspace-stop.sh" "$@"
    ;;
  reconcile)
    exec bash "$HERE/workspace-reconcile.sh" "$@"
    ;;
  restart)
    exec bash "$HERE/workspace-restart.sh" "$@"
    ;;
  doctor)
    exec bash "$HERE/workspace-doctor.sh" "$@"
    ;;
  install)
    exec bash "$HERE/workspace-install.sh" "$@"
    ;;
  browser-config)
    exec bash "$HERE/workspace-browser-config.sh" "$@"
    ;;
  harness-status)
    exec bash "$HERE/harness-status.sh" "$@"
    ;;
  harness-doctor)
    exec bash "$HERE/harness-doctor.sh" "$@"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "ERROR: unknown verb '$VERB'." >&2
    usage
    exit 1
    ;;
esac
