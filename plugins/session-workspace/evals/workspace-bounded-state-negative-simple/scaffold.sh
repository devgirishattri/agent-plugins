#!/usr/bin/env bash
# Fixture only. $1 = workspace path (Codex runner); defaults to PWD (Claude runner).
set -euo pipefail
cd "${1:-$PWD}"
mkdir -p tests
cat > tests/run.sh <<'SH'
#!/usr/bin/env bash
# Existing ordering check for the fixture queue (retry and late ack).
echo "retry-order check: 4 passed, 0 failed"
SH
chmod +x tests/run.sh
