#!/usr/bin/env bash
# Shared fixture: a git repository with a zero-config knowledge store
# (.agents/memory) holding three memories. Used by every knowledge eval case.
# $1 = workspace path (Codex runner); Claude's eval runner runs it inside the
# empty workspace, so default to the current directory.
set -euo pipefail
WS="${1:-$PWD}"
cd "$WS"
git init -q 2>/dev/null || true
STORE=".agents/memory"
mkdir -p "$STORE"
mem() { # slug type status description body
  printf -- '---\nschema_version: 1\nname: %s\ndescription: %s\nmetadata:\n  type: %s\ncreated: 2026-01-01\nupdated: 2026-01-02\nstatus: %s\ntags:\n  - fixture\n---\n# %s\n\n%s\n' \
    "$1" "$4" "$2" "$3" "$1" "$5" > "$STORE/$1.md"
  printf -- '- [%s](%s.md) — %s\n' "$1" "$1" "$4" >> "$STORE/MEMORY.md"
}
: > "$STORE/MEMORY.md"
mem project_release_checklist project active "Release checklist: bump the version in all three manifests, run the validator, then tag" "Before cutting a release: bump the version in every manifest, run scripts/validate.sh, then create the git tag. Never tag with a dirty tree."
mem reference_widget_colors reference active "Widget colour palette used by the dashboard" "Primary widget colour is teal; secondary is amber."
mem project_old_release_notes project stale "Old release procedure (stale, replaced by the checklist)" "Releases used to be cut by hand from the build server."

# case seed
mkdir -p tools
cat > tools/notify.sh <<'NOTIFY_EOF'
#!/usr/bin/env bash
# notify.sh: send one notification, retrying on failure. Skips weekends.
set -euo pipefail
MSG="${1:-}"
day=$(date +%u)
if [ "$day" -ge 6 ]; then
  echo "skip: weekend" >&2
  exit 0
fi
for attempt in 1 2 3; do
  if curl -fsS -X POST -d "$MSG" "${NOTIFY_URL:-http://localhost:9/notify}" >/dev/null; then
    echo "sent on attempt $attempt"
    exit 0
  fi
  sleep 1
done
echo "failed after 3 attempts" >&2
exit 1
NOTIFY_EOF
