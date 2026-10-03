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

# distill / implicit-capture fixture additions: a docs directory and a test script.
mkdir -p docs tests
printf '# Docs index\n\nNo release-tag documentation yet.\n' > docs/README.md
printf '#!/usr/bin/env bash\n# integration tests\nexit 0\n' > tests/run.sh

# Destination snapshot for the post-run zero-delta / candidate checks
# (see ../check-outcome.sh; the portable grader cannot express hash deltas).
snapshot() {
  ( cd "$WS" && find .agents/memory docs -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s  %s\n' "$(shasum -a 256 "$f" | awk '{print $1}')" "$f"; done ) > "$WS/.eval-snapshot"
}
snapshot
