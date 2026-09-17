#!/usr/bin/env bash
# Fixture only. $1 = workspace path (Codex runner); defaults to PWD (Claude runner).
set -euo pipefail
cd "${1:-$PWD}"
printf "temporary\n" > scratch.txt
