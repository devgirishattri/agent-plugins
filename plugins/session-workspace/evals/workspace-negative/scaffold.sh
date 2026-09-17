#!/usr/bin/env bash
# Fixture only. $1 = workspace path (Codex runner); defaults to PWD (Claude runner).
set -euo pipefail
cd "${1:-$PWD}"
printf '{"name":"fixture","scripts":{"dev":"echo dev-server-started"}}\n' > package.json
