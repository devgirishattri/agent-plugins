#!/usr/bin/env bash
# get-my-name.sh — Print this pane's @name (empty string if unset)
set -uo pipefail

source "$(dirname "$0")/lib.sh"
resolve_pane_actor --read-only
