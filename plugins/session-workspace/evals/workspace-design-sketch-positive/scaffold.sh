#!/usr/bin/env bash
# Fixture only. $1 = workspace path (Codex runner); defaults to PWD (Claude runner).
# Deliberately creates no .agent-workspace directory: design-sketch needs no workspace config.
set -euo pipefail
cd "${1:-$PWD}"
mkdir -p tools
cat > tools/route.sh <<'SH'
#!/usr/bin/env bash
# Print the team that owns a path. Hardcoded table; the only caller today.
set -euo pipefail
case "${1:-}" in
  docs/*) echo "team-docs" ;;
  src/*) echo "team-core" ;;
  *) echo "team-unassigned" ;;
esac
SH
chmod +x tools/route.sh
printf '{"docs/":"team-docs","src/":"team-core"}\n' > owners.json
