#!/usr/bin/env bash
# get-my-name.sh — Print this pane's @name (empty string if unset).
# A genuinely-unnamed pane and a DENIED self-name query (e.g. a sandboxed exec
# blocking the tmux socket, "Operation not permitted") are different states: the
# former prints nothing and exits 0, the latter prints a diagnostic to stderr and
# exits nonzero. Never collapse a denial into a silent empty-name success — the
# caller (/whoami) would otherwise report "No name set" for a pane that is named.
[ -z "${TMUX:-}" ] && exit 0

source "$(dirname "$0")/lib.sh"

name=$(get_my_name)
rc=$?
err=$(pop_pane_name_err)
if [ "$rc" -ne 0 ] || [ -n "$err" ]; then
  echo "ERROR: could not resolve this pane's name.$(pane_name_err_detail "$err")" >&2
  exit 1
fi
printf '%s' "$name"
