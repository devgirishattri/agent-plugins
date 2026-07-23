#!/usr/bin/env bash
# init.sh — memory-store bootstrap PLANNER (KNOWLEDGE_PLUGIN_SPEC.md
# "Zero-config contract"). Two-call protocol, no state carried between
# calls: without --apply, prints the resolved target and a reviewable
# .gitignore diff and writes nothing; with --apply, re-resolves the SAME
# target (deterministic), verifies the gitignore now covers it, and
# delegates the actual creation to `memory-write.sh bootstrap` — this
# script never creates the store directory itself.
#
# Usage: init.sh [--store <path>] [--apply]
# Exit codes: 0 ok; 2 usage; 3 store/gitignore-not-yet-covered resolution
#   failure; other codes propagated verbatim from `memory-write.sh
#   bootstrap` when --apply is given (see its own exit map).
# Supported platforms: macOS, Linux
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
WRITER="$HERE/memory-write.sh"

store_arg="" apply=0
while [ $# -gt 0 ]; do
  case "$1" in
    --store)
      [ $# -ge 2 ] || { echo "ERROR: --store requires a value" >&2; exit 2; }
      store_arg="$2"
      shift 2
      ;;
    --apply)
      apply=1
      shift 1
      ;;
    *)
      echo "ERROR: Usage: init.sh [--store <path>] [--apply]" >&2
      exit 2
      ;;
  esac
done

# Creation-mode target resolution (distinct from the normal read resolver,
# which requires an existing MEMORY.md): explicit argument > env >
# canonical default <repo-root>/.agents/memory. Deterministic, so both the
# plan call and the apply call derive the identical target.
_km_init_target() {
  if [ -n "$store_arg" ]; then
    printf '%s\n' "$store_arg"
    return 0
  fi
  if [ -n "${KNOWLEDGE_MEMORY_HOME:-}" ]; then
    printf '%s\n' "$KNOWLEDGE_MEMORY_HOME"
    return 0
  fi
  local repo_root
  repo_root=$(km_repo_root) || {
    echo "ERROR: not inside a git repository (no .git ancestor from $(pwd -P))" >&2
    return 3
  }
  printf '%s\n' "$repo_root/.agents/memory"
}

target=$(_km_init_target) || exit $?

if [ "$apply" -eq 0 ]; then
  echo "target: $target"

  if km_verify_gitignored "$target" 2>/dev/null; then
    echo "(already covered by .gitignore — re-run with --apply)"
    exit 0
  fi

  repo=$(km_git_ancestor "$(dirname "$target")") || {
    echo "ERROR: target is not inside a git repository: $target" >&2
    exit 3
  }
  rel="${target#"$repo"/}"
  gi="$repo/.gitignore"
  gi_rel="${gi#"$repo"/}"

  echo "--- a/$gi_rel"
  echo "+++ b/$gi_rel"
  echo "@@"
  echo "+${rel}/"
  exit 0
fi

# --apply: re-resolve (deterministic) and verify the gitignore diff was
# actually applied before delegating creation to the single writer.
if ! km_verify_gitignored "$target"; then
  echo "ERROR: $target is not yet covered by .gitignore; apply the plan's diff first (run init.sh without --apply)" >&2
  exit 3
fi

bash "$WRITER" bootstrap --store "$target"
exit $?
