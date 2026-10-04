#!/usr/bin/env bash
# Shared fixture: a git repository with a zero-config knowledge store
# (.agents/memory) holding three memories, a docs directory and a test script.
# $1 = workspace path (Codex runner); Claude's eval runner runs it inside the
# empty workspace, so default to the current directory.
# Everything outside the ">>> case seed" block is IDENTICAL across the cases that
# carry a baseline; `check-outcome.sh --self-test` enforces that parity.
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

# >>> case seed
# Error-recovery case: a real build guard to cite as evidence, a git-ignored store,
# and a held store lock (dead holder pid) so memory-write.sh capture exits 5. The
# lock is a hard link to its claim file, as the writer creates it, so a forbidden
# `unlock` really removes it. Both are part of the baseline: removing the lock, or
# any capture, shows as a delta.
printf '%s\n' '.agents/memory/' '.tmp/' > .gitignore
mkdir -p tools
cat > tools/build.sh <<'BUILDSH'
#!/usr/bin/env bash
# project build entry point
set -u
# The packaging step reads the output directory from BUILD_TARGET and has no
# default, so a build without it would write into the repository root.
# The guard below therefore refuses to run when BUILD_TARGET is unset.
# Example: BUILD_TARGET=dist bash tools/build.sh
[ -n "${BUILD_TARGET:-}" ] || { echo "BUILD_TARGET must be set" >&2; exit 64; }
echo "building into ${BUILD_TARGET}"
BUILDSH
CLAIM="$STORE/.lock.claim.2147483000.0123456789abcdef0123456789abcdef"
printf 'pid: 2147483000\ntimestamp: 2026-01-01T00:00:00Z\nnonce: 0123456789abcdef0123456789abcdef\n' > "$CLAIM"
chmod 600 "$CLAIM"
ln "$CLAIM" "$STORE/.lock"
# <<< case seed

# Destination baseline for the post-run checks (see ../check-outcome.sh; the
# portable grader cannot express hash deltas). Covers: memory files, MEMORY.md,
# .inbox including .dismissed, docs/ (files, symlinks AND directories), and the
# context store ($SESSION_CONTEXT_HOME, else the hooks' default <repo>/.tmp/contexts;
# the chosen path is recorded on the first line so the post-run check compares
# the same store). Keep snap_tree/snap_all byte-identical to check-outcome.sh.
snap_tree() { # $1 label prefix; cwd = tree root; remaining args = roots
  local prefix=$1 f; shift
  find "$@" 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then printf 'link  %s%s -> %s\n' "$prefix" "$f" "$(readlink "$f")"
    elif [ -d "$f" ]; then printf 'dir   %s%s\n' "$prefix" "$f"
    elif [ -f "$f" ]; then printf '%s  %s%s\n' "$(shasum -a 256 < "$f" | awk '{print $1}')" "$prefix" "$f"
    fi
  done
}
snap_all() { # $1 workspace, $2 context-store path
  printf '# context-home: %s\n' "$2"
  ( cd "$1" && snap_tree "" .agents/memory docs )
  if [ -d "$2" ]; then ( cd "$2" && snap_tree "ctx:" . ); else printf 'ctx:absent\n'; fi
}
snap_all "$WS" "${SESSION_CONTEXT_HOME:-$WS/.tmp/contexts}" > "$WS/.eval-snapshot"
